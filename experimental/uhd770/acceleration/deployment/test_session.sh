#!/bin/bash
# Real session helper fault tests against a fresh temporary directory. No Mac
# commands, EFI, kext installation, launchd registration or GPU API are invoked.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/session-lib.sh"
TASK_PARENT=$(cd "${TMPDIR:-/tmp}" && pwd)
TASK_TMP=$(mktemp -d "$TASK_PARENT/uhd770-session-fixture.XXXXXX")
case "$TASK_TMP" in "$TASK_PARENT"/uhd770-session-fixture.*) ;; *) exit 1 ;; esac
cleanup() {
    local code=$?
    if [ "$code" -eq 0 ]; then rm -rf -- "$TASK_TMP"; else printf 'Evidence retained: %s\n' "$TASK_TMP" >&2; fi
}
trap cleanup EXIT
mkdir "$TASK_TMP/journal"
printf old > "$TASK_TMP/target"
printf new > "$TASK_TMP/prepared"
session_replace "$TASK_TMP/journal" first "$TASK_TMP/target" "$TASK_TMP/prepared"
[ "$(cat "$TASK_TMP/target")" = new ]
[ "$(cat "$TASK_TMP/journal/first.backup")" = old ]
session_restore_one "$TASK_TMP/journal" first "$TASK_TMP/target"
[ "$(cat "$TASK_TMP/target")" = old ]
session_restore_one "$TASK_TMP/journal" first "$TASK_TMP/target"
[ "$(cat "$TASK_TMP/target")" = old ]

# Brand-new destinations are removed by retaining the candidate in the journal.
printf candidate > "$TASK_TMP/prepared"
session_replace "$TASK_TMP/journal" absent "$TASK_TMP/new-target" "$TASK_TMP/prepared"
session_restore_one "$TASK_TMP/journal" absent "$TASK_TMP/new-target"
[ ! -e "$TASK_TMP/new-target" ]
[ "$(cat "$TASK_TMP/journal/absent.replaced")" = candidate ]

# Simulate failure AFTER saving the original, BEFORE moving the new payload.
printf original > "$TASK_TMP/fault-target"
printf replacement > "$TASK_TMP/fault-prepared"
mv() { if [ "$1" = -f ] && [ "$2" = "$TASK_TMP/fault-prepared" ]; then return 73; fi; command mv "$@"; }
if session_replace "$TASK_TMP/journal" fault "$TASK_TMP/fault-target" "$TASK_TMP/fault-prepared"; then exit 1; fi
unset -f mv
[ "$(cat "$TASK_TMP/fault-target")" = original ]
session_restore_one "$TASK_TMP/journal" fault "$TASK_TMP/fault-target"
[ "$(cat "$TASK_TMP/fault-target")" = original ]

# A partial original-file backup is never replayed over the intact destination.
printf intact > "$TASK_TMP/copy-target"
printf replacement > "$TASK_TMP/copy-prepared"
cp() { local destination; for destination in "$@"; do :; done; printf partial > "$destination"; return 28; }
if session_replace "$TASK_TMP/journal" copyfault "$TASK_TMP/copy-target" "$TASK_TMP/copy-prepared"; then exit 1; fi
unset -f cp
session_restore_one "$TASK_TMP/journal" copyfault "$TASK_TMP/copy-target"
[ "$(cat "$TASK_TMP/copy-target")" = intact ]

# Interruptions before saving the original and after a restore rename are inert.
printf '%s\n' "$TASK_TMP/not-moved" > "$TASK_TMP/journal/notmoved.target"
printf 'present\n' > "$TASK_TMP/journal/notmoved.original"
printf untouched > "$TASK_TMP/not-moved"
session_restore_one "$TASK_TMP/journal" notmoved "$TASK_TMP/not-moved"
[ "$(cat "$TASK_TMP/not-moved")" = untouched ]
printf '%s\n' "$TASK_TMP/restore-interrupted" > "$TASK_TMP/journal/interrupted.target"
printf 'present\n' > "$TASK_TMP/journal/interrupted.original"
printf candidate > "$TASK_TMP/journal/interrupted.replaced"
printf original > "$TASK_TMP/restore-interrupted"
session_restore_one "$TASK_TMP/journal" interrupted "$TASK_TMP/restore-interrupted"
[ "$(cat "$TASK_TMP/restore-interrupted")" = original ]

# A tampered journal cannot redirect a recovery write to another target.
printf '%s\n' "$TASK_TMP/other" > "$TASK_TMP/journal/tampered.target"
printf 'absent\n' > "$TASK_TMP/journal/tampered.original"
printf preserve > "$TASK_TMP/other"
if session_restore_one "$TASK_TMP/journal" tampered "$TASK_TMP/target"; then exit 1; fi
[ "$(cat "$TASK_TMP/other")" = preserve ]
if session_restore_one "$TASK_TMP/journal" ../escape "$TASK_TMP/target"; then exit 1; fi

mkdir "$TASK_TMP/report"
printf 'kern.bootsessionuuid: CURRENT\n' > "$TASK_TMP/report/boot-identity.txt"
printf '%s\n' 'elapsed_s=1 heartbeat stream_alive=1' 'elapsed_s=275 heartbeat stream_alive=1' \
    'elapsed_s=300 collector_end reason=duration_complete' > "$TASK_TMP/report/stages.txt"
for name in dmesg-0 ioreg-NMXGPU-0 ioreg-NMXAccel-0; do
    printf 'collector_command_exit=0\n' > "$TASK_TMP/report/$name.txt"
done
session_recorder_valid "$TASK_TMP/report" CURRENT
if session_recorder_valid "$TASK_TMP/report" OLD; then exit 1; fi
printf 'stage=kernel-stream startup_failed status=42\n' >> "$TASK_TMP/report/stages.txt"
if session_recorder_valid "$TASK_TMP/report" CURRENT; then exit 1; fi

printf 'class NMXGPUFB\n"nmxdiag-stage" = "attach.complete ret=0"\n' > "$TASK_TMP/registry"
session_registry_ready "$TASK_TMP/registry"
printf 'class NMXGPUFB\n"nmxdiag-stage" = "pm.callback.after ret=0"\n' > "$TASK_TMP/registry"
session_registry_ready "$TASK_TMP/registry"
printf '"nullmoth-gpu-state" = "failed: port attach; guard retained"\n' >> "$TASK_TMP/registry"
if session_registry_ready "$TASK_TMP/registry"; then exit 1; fi
printf '"nmxdiag-stage" = "attach.complete ret=0"\n' > "$TASK_TMP/registry"
if session_registry_ready "$TASK_TMP/registry"; then exit 1; fi
sed '/startup_failed/d' "$TASK_TMP/report/stages.txt" > "$TASK_TMP/stages"
command mv "$TASK_TMP/stages" "$TASK_TMP/report/stages.txt"
printf 'collector_command_exit=124\n' > "$TASK_TMP/report/dmesg-0.txt"
if session_recorder_valid "$TASK_TMP/report" CURRENT; then exit 1; fi

mkdir "$TASK_TMP/output"
cat > "$TASK_TMP/runner" <<'RUNNER'
#!/bin/bash
printf '%s\n' "$1" >> "$TASK_TMP/calls"
case "$1:$TASK_RUN" in vulkan:fail-vulkan) exit 31 ;; metal:fail-metal) exit 32 ;; esac
RUNNER
chmod 700 "$TASK_TMP/runner"
export TASK_TMP TASK_RUN
TASK_RUN=fail-vulkan
if session_compute_sequence "$TASK_TMP/runner" "$TASK_TMP/output"; then exit 1; fi
[ "$(cat "$TASK_TMP/calls")" = vulkan ]
grep -q metal_started=false "$TASK_TMP/output/sequence.txt"
: > "$TASK_TMP/calls"; TASK_RUN=fail-metal
if session_compute_sequence "$TASK_TMP/runner" "$TASK_TMP/output"; then exit 1; fi
[ "$(wc -l < "$TASK_TMP/calls" | tr -d ' ')" = 2 ]
grep -q exit=32 "$TASK_TMP/output/sequence.txt"
: > "$TASK_TMP/calls"; TASK_RUN=success
session_compute_sequence "$TASK_TMP/runner" "$TASK_TMP/output"
grep -q exit=0 "$TASK_TMP/output/sequence.txt"

session_bounded 2 "$TASK_TMP/command.txt" /bin/bash -c 'exit 27' && exit 1
grep -q command_exit_status=27 "$TASK_TMP/command.txt"
if session_bounded 1 "$TASK_TMP/timeout.txt" /bin/bash -c 'trap "" TERM; exec sleep 8'; then exit 1; fi
grep -q command_timeout_seconds=1 "$TASK_TMP/timeout.txt"
printf 'Session transaction, interrupted recovery, recorder and sequential failure gates passed; no GPU accessed.\n'
