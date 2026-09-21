#!/usr/bin/env bash
#
# fileset-uninstall.sh
#
# Removes a set of files previously installed with fileset-install.sh,
# using its receipt file to know exactly what to remove -- so uninstall
# works correctly even if the original source files are long gone.
# Can also remove an explicit list of files directly, bypassing the
# receipt, for a simple, safe `rm` with consistent exit codes.
#
# Exit codes (same convention as fileset-install.sh):
#   0  every target file was removed (or was already absent)
#   1  usage error
#   2  one or more files could not be removed -- see stderr
#
# Usage:
#   fileset-uninstall.sh [options]              # uses the receipt
#   fileset-uninstall.sh [options] FILE...       # removes exactly these
#
# Options:
#   -p, --prefix DIR      Directory the receipt lives in (default:
#                         /usr/local/bin) -- only used to locate the
#                         default receipt path; ignored if -r is given
#   -r, --receipt FILE    Explicit receipt file path (default:
#                         PREFIX/.fileset-install.receipt)
#   -k, --keep-receipt    Don't delete the receipt file afterward (default:
#                         remove it once every file it lists is gone)
#   -d, --dry-run         Print each path that would be removed to stdout;
#                         make no changes
#   -v, --verbose         Print each file as it's removed, to stderr
#   -q, --quiet           Suppress warnings about already-missing files
#   -h, --help            Show this help and exit 0
#
# If FILE arguments are given, exactly those files are removed and the
# receipt (if any) is left untouched. Otherwise every file listed in the
# receipt is removed.
#
# Examples:
#   fileset-uninstall.sh -p /usr/local/bin
#   fileset-uninstall.sh -p /opt/mytool -d          # preview only
#   fileset-uninstall.sh /usr/local/bin/one-off.sh  # remove just this one
#
set -u -o pipefail

PREFIX="/usr/local/bin"
RECEIPT=""
KEEP_RECEIPT=0
DRY_RUN=0
VERBOSE=0
QUIET=0
FILES=()

usage() { sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; }

warn() { (( QUIET )) || printf 'fileset-uninstall: %s\n' "$*" >&2; }
err()  { printf 'fileset-uninstall: %s\n' "$*" >&2; }
log()  { (( VERBOSE )) && printf 'fileset-uninstall: %s\n' "$*" >&2; return 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--prefix)       PREFIX="$2"; shift 2;;
        -r|--receipt)      RECEIPT="$2"; shift 2;;
        -k|--keep-receipt) KEEP_RECEIPT=1; shift;;
        -d|--dry-run)      DRY_RUN=1; shift;;
        -v|--verbose)      VERBOSE=1; shift;;
        -q|--quiet)        QUIET=1; shift;;
        -h|--help)         usage; exit 0;;
        --) shift; while [[ $# -gt 0 ]]; do FILES+=("$1"); shift; done;;
        -*) err "unknown option: $1"; usage >&2; exit 1;;
        *)  FILES+=("$1"); shift;;
    esac
done

[[ -z "$RECEIPT" ]] && RECEIPT="${PREFIX%/}/.fileset-install.receipt"

USING_RECEIPT=0
if [[ ${#FILES[@]} -eq 0 ]]; then
    USING_RECEIPT=1
    if [[ ! -r "$RECEIPT" ]]; then
        err "no FILE arguments given and receipt not found/readable: $RECEIPT"
        exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        FILES+=("$line")
    done < "$RECEIPT"
    if [[ ${#FILES[@]} -eq 0 ]]; then
        log "receipt is empty, nothing to do: $RECEIPT"
    fi
fi

FAIL_COUNT=0
REMOVED_ANY=0

for f in "${FILES[@]}"; do
    if (( DRY_RUN )); then
        printf 'remove %s\n' "$f"
        continue
    fi

    if [[ ! -e "$f" && ! -L "$f" ]]; then
        log "already absent: $f"
        continue
    fi

    if ! rm -f -- "$f" 2>/dev/null; then
        err "failed to remove: $f"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        continue
    fi

    log "removed $f"
    REMOVED_ANY=1
done

if (( DRY_RUN == 0 && USING_RECEIPT == 1 && FAIL_COUNT == 0 && KEEP_RECEIPT == 0 )); then
    if ! rm -f -- "$RECEIPT" 2>/dev/null; then
        warn "could not remove receipt file: $RECEIPT"
    else
        log "receipt removed: $RECEIPT"
    fi
fi

if (( FAIL_COUNT > 0 )); then
    err "$FAIL_COUNT file(s) failed to remove"
    exit 2
fi

exit 0
