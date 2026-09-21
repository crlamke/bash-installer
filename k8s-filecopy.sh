#!/usr/bin/env bash
#
# k8s-filecopy.sh
#
# Copies files between the local filesystem and a container running in a
# Kubernetes pod -- a thin, scriptable wrapper around `kubectl cp` with
# predictable exit codes, quiet-by-default output, and support for
# copying a whole directory OR a specific list of named files in one call.
#
# Follows the same exit-code convention as fileset-install.sh /
# fileset-uninstall.sh, so all three compose together:
#   0  the copy (every file, if more than one) succeeded
#   1  usage error (bad/missing arguments, kubectl not found, etc.)
#   2  the target pod/container wasn't reachable, or one or more files
#      failed to copy -- see stderr
#
# Usage:
#   k8s-filecopy.sh --in  -p POD[:CONTAINER] -r REMOTE_DIR -l LOCAL_DIR [FILE...]
#   k8s-filecopy.sh --out -p POD[:CONTAINER] -r REMOTE_DIR -l LOCAL_DIR [FILE...]
#
# Exactly one of --in / --out is required:
#   --in    copy from the local filesystem INTO the container
#   --out   copy from the container OUT to the local filesystem
#
# With no FILE arguments, REMOTE_DIR and LOCAL_DIR are copied to each
# other directly as a single recursive directory copy.
#
# With one or more FILE arguments, each is copied individually as
# REMOTE_DIR/FILE <-> LOCAL_DIR/FILE (FILE may include a relative
# subpath, e.g. "sub/dir/file.txt"); local subdirectories are created
# as needed. All named files are attempted even if one fails.
#
# Required:
#   -p, --pod POD[:CONTAINER]  Pod name, optionally with :CONTAINER
#   -r, --remote PATH          Directory/path inside the container
#   -l, --local PATH           Directory/path on the local filesystem
#
# Options:
#   -c, --container NAME    Container name (overrides any :CONTAINER
#                            suffix given on --pod)
#   -N, --namespace NS      Kubernetes namespace
#   -k, --kubeconfig FILE   Path to a kubeconfig file
#       --context NAME      kubectl context to use
#   -n, --no-clobber        Skip a file if it already exists at the
#                            destination (local file for --out, remote
#                            file for --in) instead of overwriting it
#   -s, --skip-check        Skip the pre-flight `kubectl get pod` check
#                            (faster; useful when you already know the
#                            pod is up, e.g. in a tight retry loop)
#   -d, --dry-run           Print each planned action to stdout; make no
#                            changes and don't touch the cluster at all
#   -v, --verbose            Print each kubectl command before running it,
#                            and progress, to stderr
#   -q, --quiet               Suppress warnings
#   -h, --help                 Show this help and exit 0
#
# Examples:
#   k8s-filecopy.sh --out -p web-7d9:app -r /var/log/app -l ./logs
#   k8s-filecopy.sh --in  -p db-0 -N data -r /backups -l ./dump  backup.sql
#   k8s-filecopy.sh --in  -p worker -r /etc/app -l ./config app.yaml secrets/db.yaml
#
set -u -o pipefail

DIRECTION=""
POD=""
CONTAINER=""
NAMESPACE=""
KUBECONFIG_FILE=""
CONTEXT=""
REMOTE=""
LOCAL=""
NO_CLOBBER=0
SKIP_CHECK=0
DRY_RUN=0
VERBOSE=0
QUIET=0
FILES=()

usage() { sed -n '2,56p' "$0" | sed 's/^# \{0,1\}//'; }

warn() { (( QUIET )) || printf 'k8s-filecopy: %s\n' "$*" >&2; }
err()  { printf 'k8s-filecopy: %s\n' "$*" >&2; }
log()  { (( VERBOSE )) && printf 'k8s-filecopy: %s\n' "$*" >&2; return 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --in)             DIRECTION="in"; shift;;
        --out)            DIRECTION="out"; shift;;
        -p|--pod)         POD="$2"; shift 2;;
        -c|--container)   CONTAINER="$2"; shift 2;;
        -N|--namespace)   NAMESPACE="$2"; shift 2;;
        -k|--kubeconfig)  KUBECONFIG_FILE="$2"; shift 2;;
        --context)        CONTEXT="$2"; shift 2;;
        -r|--remote)      REMOTE="$2"; shift 2;;
        -l|--local)       LOCAL="$2"; shift 2;;
        -n|--no-clobber)  NO_CLOBBER=1; shift;;
        -s|--skip-check)  SKIP_CHECK=1; shift;;
        -d|--dry-run)     DRY_RUN=1; shift;;
        -v|--verbose)     VERBOSE=1; shift;;
        -q|--quiet)       QUIET=1; shift;;
        -h|--help)        usage; exit 0;;
        --) shift; while [[ $# -gt 0 ]]; do FILES+=("$1"); shift; done;;
        -*) err "unknown option: $1"; usage >&2; exit 1;;
        *)  FILES+=("$1"); shift;;
    esac
done

# -- Validate usage ---------------------------------------------------
[[ -z "$DIRECTION" ]] && { err "exactly one of --in or --out is required"; exit 1; }
[[ -z "$POD" ]]       && { err "-p/--pod is required"; exit 1; }
[[ -z "$REMOTE" ]]    && { err "-r/--remote is required"; exit 1; }
[[ -z "$LOCAL" ]]     && { err "-l/--local is required"; exit 1; }

if [[ "$POD" == *:* ]]; then
    POD_NAME="${POD%%:*}"
    POD_CONTAINER="${POD#*:}"
else
    POD_NAME="$POD"
    POD_CONTAINER=""
fi
[[ -n "$CONTAINER" ]] && POD_CONTAINER="$CONTAINER"

if ! command -v kubectl >/dev/null 2>&1; then
    err "kubectl not found on PATH"
    exit 1
fi

# -- Build the shared kubectl global-flag prefix -----------------------
KCOMMON=()
[[ -n "$NAMESPACE" ]]       && KCOMMON+=(-n "$NAMESPACE")
[[ -n "$KUBECONFIG_FILE" ]] && KCOMMON+=(--kubeconfig "$KUBECONFIG_FILE")
[[ -n "$CONTEXT" ]]         && KCOMMON+=(--context "$CONTEXT")

run_kubectl() {
    log "+ kubectl ${KCOMMON[*]+${KCOMMON[*]} }$*"
    kubectl "${KCOMMON[@]}" "$@"
}

# -- Pre-flight: confirm the pod exists and is reachable ----------------
if (( DRY_RUN == 0 && SKIP_CHECK == 0 )); then
    if ! run_kubectl get pod "$POD_NAME" -o name >/dev/null 2>&1; then
        err "pod not found or not reachable: $POD_NAME${NAMESPACE:+ (namespace $NAMESPACE)}"
        exit 2
    fi
    log "pod check OK: $POD_NAME"
fi

remote_exists() {
    # Checks for a path inside the container via `kubectl exec ... test -e`.
    # Uses `sh -c '...' sh "$1"` so the path is passed as a positional
    # parameter rather than interpolated into the shell command string.
    local path="$1"
    local cargs=()
    [[ -n "$POD_CONTAINER" ]] && cargs+=(-c "$POD_CONTAINER")
    run_kubectl exec "${cargs[@]}" "$POD_NAME" -- sh -c 'test -e "$1"' sh "$path" >/dev/null 2>&1
}

do_cp() {
    # do_cp SRC DEST -- runs kubectl cp with the container flag applied,
    # returns kubectl's own exit status.
    local src="$1" dest="$2"
    local cpargs=()
    [[ -n "$POD_CONTAINER" ]] && cpargs+=(-c "$POD_CONTAINER")
    run_kubectl cp "${cpargs[@]}" "$src" "$dest"
}

FAIL_COUNT=0

copy_one() {
    # copy_one REMOTE_PATH LOCAL_PATH -- handles one file/dir in the
    # configured direction, including pre-checks, dry-run, and no-clobber.
    local remote_path="$1" local_path="$2"

    if [[ "$DIRECTION" == "out" ]]; then
        local src="${POD_NAME}:${remote_path}"
        [[ -n "$NAMESPACE" ]] && src="${NAMESPACE}/${POD_NAME}:${remote_path}"
        local dest="$local_path"

        if (( DRY_RUN )); then
            printf 'copy %s:%s -> %s\n' "$POD_NAME" "$remote_path" "$local_path"
            return 0
        fi
        if [[ "$NO_CLOBBER" -eq 1 && -e "$local_path" ]]; then
            log "skipping (already exists locally, --no-clobber): $local_path"
            return 0
        fi
        if ! mkdir -p -- "$(dirname -- "$local_path")" 2>/dev/null; then
            err "could not create local directory: $(dirname -- "$local_path")"
            return 1
        fi
        if ! do_cp "$src" "$dest"; then
            err "copy failed: $POD_NAME:$remote_path -> $local_path"
            return 1
        fi
        log "copied $POD_NAME:$remote_path -> $local_path"
        return 0
    else
        # direction == in
        if [[ ! -e "$local_path" ]]; then
            err "local source not found: $local_path"
            return 1
        fi
        local dest="${POD_NAME}:${remote_path}"
        [[ -n "$NAMESPACE" ]] && dest="${NAMESPACE}/${POD_NAME}:${remote_path}"

        if (( DRY_RUN )); then
            printf 'copy %s -> %s:%s\n' "$local_path" "$POD_NAME" "$remote_path"
            return 0
        fi
        if [[ "$NO_CLOBBER" -eq 1 ]] && remote_exists "$remote_path"; then
            log "skipping (already exists in container, --no-clobber): $remote_path"
            return 0
        fi
        if ! do_cp "$local_path" "$dest"; then
            err "copy failed: $local_path -> $POD_NAME:$remote_path"
            return 1
        fi
        log "copied $local_path -> $POD_NAME:$remote_path"
        return 0
    fi
}

if [[ ${#FILES[@]} -eq 0 ]]; then
    copy_one "$REMOTE" "$LOCAL" || FAIL_COUNT=$((FAIL_COUNT + 1))
else
    for f in "${FILES[@]}"; do
        remote_path="${REMOTE%/}/$f"
        local_path="${LOCAL%/}/$f"
        copy_one "$remote_path" "$local_path" || FAIL_COUNT=$((FAIL_COUNT + 1))
    done
fi

if (( FAIL_COUNT > 0 )); then
    err "$FAIL_COUNT item(s) failed to copy"
    exit 2
fi

exit 0
