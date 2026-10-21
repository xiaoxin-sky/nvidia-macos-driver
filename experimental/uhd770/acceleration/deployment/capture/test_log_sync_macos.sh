#!/bin/bash
# Exercise the production per-file flush on native macOS, without launchd/GPU.
set -eu
[ "$(uname -s)" = Darwin ] || { printf 'Native macOS required.\n' >&2; exit 64; }
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/collector.sh"
capture_configure
REPORT=$(mktemp -d /private/tmp/uhd770-log-sync.XXXXXX)
case "$REPORT" in /private/tmp/uhd770-log-sync.*) ;; *) exit 1 ;; esac
cleanup() {
    local code=$?
    if [ "$code" -eq 0 ]; then rm -rf -- "$REPORT"
    else
        printf 'Log flush evidence retained: %s\n' "$REPORT"
        cat "$REPORT/stages.txt" "$REPORT/sync-status.txt" 2>/dev/null || :
    fi
}
trap cleanup EXIT
printf 'captured data\n' > "$REPORT/snapshot.txt"
capture_marker 'fixture_file_flush' "$REPORT/snapshot.txt"
! grep -q 'sync_failed' "$REPORT/stages.txt"
[ "$(cat "$REPORT/snapshot.txt")" = 'captured data' ]
ln -s snapshot.txt "$REPORT/alias.txt"
capture_marker 'fixture_symlink_rejected' "$REPORT/alias.txt"
grep -q 'sync_failed status=' "$REPORT/stages.txt"
grep -q 'open log:' "$REPORT/sync-status.txt"
[ "$(cat "$REPORT/snapshot.txt")" = 'captured data' ]
printf 'Native per-file log fsync and no-follow failure reporting passed; no global sync or GPU executed.\n'
