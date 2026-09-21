#!/usr/bin/env bash
#
# fileset-install.sh
#
# Installs a set of files onto the system by copying them into a prefix
# directory, and records exactly what was installed (a "receipt") so
# fileset-uninstall.sh can cleanly remove them later, regardless of
# whether the original source files still exist by then.
#
# Follows the classic Unix convention for exit codes so it composes with
# && / || / if and other tools:
#   0  every requested file was installed successfully
#   1  usage error (bad/missing arguments, no such option, etc.)
#   2  one or more files failed to install -- see stderr. Whatever DID
#      succeed is still recorded in the receipt.
#
# Usage:
#   fileset-install.sh [options] FILE...
#   fileset-install.sh [options] -M MANIFEST
#
# FILE... a list of files to install. Each is copied into --prefix by its
#          basename (directory structure is not preserved).
#
# Options:
#   -p, --prefix DIR      Destination directory (default: /usr/local/bin)
#   -M, --manifest FILE   Read source file paths from FILE, one per line.
#                         Blank lines and lines starting with '#' are
#                         ignored. May be combined with positional FILE
#                         arguments -- both lists are installed.
#   -r, --receipt FILE    Where to record installed files, one absolute
#                         destination path per line (default:
#                         PREFIX/.fileset-install.receipt)
#   -m, --mode MODE       chmod mode to apply to each installed file
#                         (default: 0755)
#   -o, --owner OWNER     chown owner[:group] to apply (needs privileges
#                         for anything other than your own user/group)
#   -n, --no-clobber      Skip files that already exist at the destination
#                         instead of overwriting them (default: overwrite)
#   -d, --dry-run         Print each planned action to stdout as
#                         "install SRC -> DST"; make no changes
#   -v, --verbose         Print each file as it's installed, to stderr
#   -q, --quiet           Suppress warnings (errors are still reported)
#   -h, --help            Show this help and exit 0
#
# Examples:
#   fileset-install.sh -p /usr/local/bin ./bin/*.sh
#   fileset-install.sh -p /opt/mytool -M files.manifest -m 0644
#
set -u -o pipefail

PREFIX="/usr/local/bin"
MANIFEST=""
RECEIPT=""
MODE="0755"
OWNER=""
NO_CLOBBER=0
DRY_RUN=0
VERBOSE=0
QUIET=0
FILES=()

usage() { sed -n '2,44p' "$0" | sed 's/^# \{0,1\}//'; }

warn() { (( QUIET )) || printf 'fileset-install: %s\n' "$*" >&2; }
err()  { printf 'fileset-install: %s\n' "$*" >&2; }
log()  { (( VERBOSE )) && printf 'fileset-install: %s\n' "$*" >&2; return 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prefix)      PREFIX="$2"; shift 2;;
        -M|--manifest)    MANIFEST="$2"; shift 2;;
        -r|--receipt)     RECEIPT="$2"; shift 2;;
        -m|--mode)        MODE="$2"; shift 2;;
        -o|--owner)       OWNER="$2"; shift 2;;
        -n|--no-clobber)  NO_CLOBBER=1; shift;;
        -d|--dry-run)     DRY_RUN=1; shift;;
        -v|--verbose)     VERBOSE=1; shift;;
        -q|--quiet)       QUIET=1; shift;;
        -h|--help)        usage; exit 0;;
        --) shift; while [[ $# -gt 0 ]]; do FILES+=("$1"); shift; done;;
        -*) err "unknown option: $1"; usage >&2; exit 1;;
        *)  FILES+=("$1"); shift;;
    esac
done

[[ -z "$RECEIPT" ]] && RECEIPT="${PREFIX%/}/.fileset-install.receipt"

if [[ -n "$MANIFEST" ]]; then
    [[ -r "$MANIFEST" ]] || { err "manifest not readable: $MANIFEST"; exit 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="$(echo "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [[ -z "$line" ]] && continue
        FILES+=("$line")
    done < "$MANIFEST"
fi

if [[ ${#FILES[@]} -eq 0 ]]; then
    err "no files given (positional arguments and/or -M MANIFEST)"
    usage >&2
    exit 1
fi

if (( DRY_RUN == 0 )); then
    if [[ ! -d "$PREFIX" ]]; then
        if ! mkdir -p "$PREFIX" 2>/dev/null; then
            err "cannot create prefix directory: $PREFIX"
            exit 1
        fi
        log "created prefix directory $PREFIX"
    fi
fi

FAIL_COUNT=0
INSTALLED=()

for src in "${FILES[@]}"; do
    if [[ ! -e "$src" ]]; then
        err "source not found, skipping: $src"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    if [[ ! -f "$src" ]]; then
        err "not a regular file, skipping: $src"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi
    if [[ ! -r "$src" ]]; then
        err "not readable, skipping: $src"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    dest="${PREFIX%/}/$(basename -- "$src")"

    if (( DRY_RUN )); then
        printf 'install %s -> %s\n' "$src" "$dest"
        INSTALLED+=("$dest")
        continue
    fi

    if [[ -e "$dest" && "$NO_CLOBBER" -eq 1 ]]; then
        log "skipping (already exists, --no-clobber): $dest"
        continue
    fi

    if ! cp -f -- "$src" "$dest" 2>/dev/null; then
        err "failed to copy $src -> $dest"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    if ! chmod "$MODE" -- "$dest" 2>/dev/null; then
        err "copied but failed to chmod $MODE: $dest"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    if [[ -n "$OWNER" ]]; then
        if ! chown "$OWNER" -- "$dest" 2>/dev/null; then
            err "copied but failed to chown $OWNER: $dest (do you have permission?)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue
        fi
    fi

    log "installed $dest"
    INSTALLED+=("$dest")
done

if (( DRY_RUN == 0 && ${#INSTALLED[@]} > 0 )); then
    declare -A seen=()
    existing=()
    if [[ -r "$RECEIPT" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" || "$line" == \#* ]] && continue
            if [[ -z "${seen[$line]:-}" ]]; then
                seen["$line"]=1
                existing+=("$line")
            fi
        done < "$RECEIPT"
    fi
    for d in "${INSTALLED[@]}"; do
        if [[ -z "${seen[$d]:-}" ]]; then
            seen["$d"]=1
            existing+=("$d")
        fi
    done
    {
        printf '# fileset-install receipt -- last updated %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '# prefix: %s\n' "$PREFIX"
        for d in "${existing[@]}"; do printf '%s\n' "$d"; done
    } > "${RECEIPT}.tmp.$$" 2>/dev/null && mv -f "${RECEIPT}.tmp.$$" "$RECEIPT" 2>/dev/null \
        || warn "could not write receipt file: $RECEIPT"
    log "receipt updated: $RECEIPT (${#existing[@]} file(s) tracked)"
fi

if (( FAIL_COUNT > 0 )); then
    err "$FAIL_COUNT file(s) failed to install"
    exit 2
fi

exit 0
