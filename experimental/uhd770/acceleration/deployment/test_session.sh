#!/bin/bash
# Real session helper fault tests against a fresh temporary directory. No Mac
# commands, EFI, kext installation, launchd registration or GPU API are invoked.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/session-lib.sh"
# Exercise the production post-compute wait with a short budget. No collector
# or GPU is launched by this helper, and an already-ended capture stays distinct
# from a completed observation interval.
(
    tmp_observation=$(mktemp -d "${TMPDIR:-/tmp}/uhd770-observation.XXXXXX")
    mkdir "$tmp_observation/capture"
    printf 'kern.bootsessionuuid: fixture\n' > "$tmp_observation/capture/boot-identity.txt"
    : > "$tmp_observation/capture/stages.txt"
    session_observe_capture "$tmp_observation/capture" fixture 2 "$tmp_observation/active.txt"
    grep -Fxq 'observation_elapsed_s=2' "$tmp_observation/active.txt"
    grep -Fxq 'observation_end=duration_complete' "$tmp_observation/active.txt"
    printf 'collector_end reason=duration_complete\n' > "$tmp_observation/capture/stages.txt"
    session_observe_capture "$tmp_observation/capture" fixture 2 "$tmp_observation/ended.txt"
    grep -Fxq 'observation_elapsed_s=0' "$tmp_observation/ended.txt"
    grep -Fxq 'observation_end=recorder_not_running' "$tmp_observation/ended.txt"
    # These five fixture files are the only cleanup targets; no recursive delete.
    rm "$tmp_observation/capture/boot-identity.txt" "$tmp_observation/capture/stages.txt" "$tmp_observation/active.txt" "$tmp_observation/ended.txt"
    rmdir "$tmp_observation/capture" "$tmp_observation"
)
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
printf '%s\n' 'elapsed_s=1 heartbeat stream_alive=1' 'elapsed_s=60 heartbeat stream_alive=1' \
    'elapsed_s=60 collector_end reason=duration_complete' > "$TASK_TMP/report/stages.txt"
for name in dmesg-0 ioreg-NMXGPU-0 ioreg-NMXAccel-0; do
    printf 'collector_command_exit=0\n' > "$TASK_TMP/report/$name.txt"
done
# The 120-second validation recorder needs at least 100 seconds of heartbeats.
if session_recorder_valid "$TASK_TMP/report" CURRENT; then exit 1; fi
printf '%s\n' 'elapsed_s=1 heartbeat stream_alive=1' 'elapsed_s=115 heartbeat stream_alive=1' \
    'elapsed_s=120 collector_end reason=duration_complete' > "$TASK_TMP/report/stages.txt"
for name in dmesg-0 ioreg-NMXGPU-0 ioreg-NMXAccel-0; do
    printf 'collector_command_exit=0\n' > "$TASK_TMP/report/$name.txt"
done
session_recorder_valid "$TASK_TMP/report" CURRENT
if session_recorder_valid "$TASK_TMP/report" OLD; then exit 1; fi
# A flush that timed out before the stream was alive (r36) does not fail the recorder; one after it does.
printf '%s\n' 'elapsed_s=6 sync_failed status=124' 'elapsed_s=12 heartbeat stream_alive=1' \
    'elapsed_s=120 heartbeat stream_alive=1' 'elapsed_s=121 collector_end reason=deadline_or_termination' \
    > "$TASK_TMP/report/stages.txt"
session_recorder_valid "$TASK_TMP/report" CURRENT
printf 'elapsed_s=121 sync_failed status=124\n' >> "$TASK_TMP/report/stages.txt"
if session_recorder_valid "$TASK_TMP/report" CURRENT; then exit 1; fi
printf '%s\n' 'elapsed_s=1 heartbeat stream_alive=1' 'elapsed_s=115 heartbeat stream_alive=1' \
    'elapsed_s=120 collector_end reason=duration_complete' > "$TASK_TMP/report/stages.txt"
printf 'stage=kernel-stream startup_failed status=42\n' >> "$TASK_TMP/report/stages.txt"
if session_recorder_valid "$TASK_TMP/report" CURRENT; then exit 1; fi

printf 'class NMXGPUFB\n"nmxdiag-stage" = "attach.complete ret=0"\n' > "$TASK_TMP/registry"
session_registry_ready "$TASK_TMP/registry"
printf 'class NMXGPUFB\n"nmxdiag-stage" = "pm.callback.after ret=0"\n' > "$TASK_TMP/registry"
session_registry_ready "$TASK_TMP/registry"
printf 'class NMXGPUFB\n"nmxdiag-attach-complete" = Yes\n"nmxdiag-stage" = "fb.commit.after ret=0"\n' > "$TASK_TMP/registry"
session_registry_ready "$TASK_TMP/registry"
# Plan step E: NMIntelFB owns the screen and NMXGPU publishes no framebuffer of its own.
printf '"nmxdiag-display-state" = "owned-by-NMIntelFB"\n"nmxdiag-attach-complete" = Yes\n' > "$TASK_TMP/registry"
session_registry_ready "$TASK_TMP/registry"
printf '"nmxdiag-display-state" = "awaiting-native-open"\n"nmxdiag-attach-complete" = Yes\n' > "$TASK_TMP/registry"
if session_registry_ready "$TASK_TMP/registry"; then exit 1; fi
printf 'class NMXGPUFB\n"nmxdiag-attach-complete" = No\n"nmxdiag-stage" = "pm.callback.after ret=0"\n' > "$TASK_TMP/registry"
if session_registry_ready "$TASK_TMP/registry"; then exit 1; fi
printf '"nullmoth-gpu-state" = "failed: port attach; guard retained"\n' >> "$TASK_TMP/registry"
if session_registry_ready "$TASK_TMP/registry"; then exit 1; fi
printf '"nmxdiag-stage" = "attach.complete ret=0"\n' > "$TASK_TMP/registry"
if session_registry_ready "$TASK_TMP/registry"; then exit 1; fi
sed '/startup_failed/d' "$TASK_TMP/report/stages.txt" > "$TASK_TMP/stages"
command mv "$TASK_TMP/stages" "$TASK_TMP/report/stages.txt"
printf 'collector_command_exit=124\n' > "$TASK_TMP/report/dmesg-0.txt"
if session_recorder_valid "$TASK_TMP/report" CURRENT; then exit 1; fi

# Recorder completion is a narrow stop/export gate, independent of the
# five-minute normal-desktop validation and of any GPU success claim.
session_recorder_ended "$TASK_TMP/report" CURRENT
if session_recorder_ended "$TASK_TMP/report" OLD; then exit 1; fi
mkdir "$TASK_TMP/partial-report"
printf 'kern.bootsessionuuid: CURRENT\n' > "$TASK_TMP/partial-report/boot-identity.txt"
printf 'elapsed_s=1 heartbeat stream_alive=1\n' > "$TASK_TMP/partial-report/stages.txt"
if session_recorder_ended "$TASK_TMP/partial-report" CURRENT; then exit 1; fi
printf 'elapsed_s=2 collector_end reason=deadline_or_termination\n' >> "$TASK_TMP/partial-report/stages.txt"
session_recorder_ended "$TASK_TMP/partial-report" CURRENT

# A user EXIT marker is published atomically and parsed only as fixed data.
# Nonzero coordinator exits also end the root wait; they never imply success.
mkdir "$TASK_TMP/terminal-session"
session_write_terminal "$TASK_TMP/terminal-session" CURRENT 501 0
session_terminal_content_valid "$TASK_TMP/terminal-session/terminal.txt" CURRENT 501
grep -qx 'coordinator_exit=0' "$TASK_TMP/terminal-session/terminal.txt"
session_write_terminal "$TASK_TMP/terminal-session" CURRENT 501 31
session_terminal_content_valid "$TASK_TMP/terminal-session/terminal.txt" CURRENT 501
grep -qx 'coordinator_exit=31' "$TASK_TMP/terminal-session/terminal.txt"
if session_terminal_content_valid "$TASK_TMP/terminal-session/terminal.txt" OLD 501; then exit 1; fi
if session_terminal_content_valid "$TASK_TMP/terminal-session/terminal.txt" CURRENT 502; then exit 1; fi
for invalid in missing duplicate extra exit-too-large exit-negative wrong-version; do
    case "$invalid" in
        missing) printf 'terminal_version=1\nboot=CURRENT\nuid=501\n' ;;
        duplicate) printf 'terminal_version=1\nboot=CURRENT\nuid=501\nuid=501\ncoordinator_exit=0\n' ;;
        extra) printf 'terminal_version=1\nboot=CURRENT\nuid=501\ncoordinator_exit=0\ncommand=do-not-evaluate\n' ;;
        exit-too-large) printf 'terminal_version=1\nboot=CURRENT\nuid=501\ncoordinator_exit=256\n' ;;
        exit-negative) printf 'terminal_version=1\nboot=CURRENT\nuid=501\ncoordinator_exit=-1\n' ;;
        wrong-version) printf 'terminal_version=2\nboot=CURRENT\nuid=501\ncoordinator_exit=0\n' ;;
    esac > "$TASK_TMP/invalid-terminal.txt"
    if session_terminal_content_valid "$TASK_TMP/invalid-terminal.txt" CURRENT 501; then exit 1; fi
done

terminal_ready() { [ "$1:$2" = CURRENT:501 ]; }
session_wait_terminal 5 "$TASK_TMP/ready-trigger.txt" terminal_ready CURRENT 501
grep -qx 'trigger=coordinator-ended' "$TASK_TMP/ready-trigger.txt"
terminal_pending() { return 1; }
wait_code=0
session_wait_terminal 0 "$TASK_TMP/deadline-trigger.txt" terminal_pending || wait_code=$?
[ "$wait_code" -eq 124 ]
grep -qx 'trigger=deadline' "$TASK_TMP/deadline-trigger.txt"

mkdir "$TASK_TMP/output"
cat > "$TASK_TMP/runner" <<'RUNNER'
#!/bin/bash
printf '%s\n' "$1" >> "$TASK_TMP/calls"
case "$1:$TASK_RUN" in
    vulkan:fail-vulkan) exit 31 ;;
    metal:fail-metal) exit 32 ;;
    metal-render:fail-render) exit 33 ;;
    metal-suite:fail-suite) exit 34 ;;
    vulkan:stop-after-vulkan) : > "$TASK_TMP/stop-probes" ;;
esac
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
: > "$TASK_TMP/calls"; : > "$TASK_TMP/stop-probes"
sequence_code=0
session_compute_sequence "$TASK_TMP/runner" "$TASK_TMP/output" "$TASK_TMP/stop-probes" || sequence_code=$?
[ "$sequence_code" -eq 124 ] && [ ! -s "$TASK_TMP/calls" ]
rm -- "$TASK_TMP/stop-probes"
: > "$TASK_TMP/calls"; TASK_RUN=stop-after-vulkan; sequence_code=0
session_compute_sequence "$TASK_TMP/runner" "$TASK_TMP/output" "$TASK_TMP/stop-probes" || sequence_code=$?
[ "$sequence_code" -eq 124 ] && [ "$(cat "$TASK_TMP/calls")" = vulkan ]
grep -q metal_started=false "$TASK_TMP/output/sequence.txt"

# Manual terminal streaming must preserve the runner's status through tee.
# A visible failed Vulkan phase still prevents every Metal submission.
rm -- "$TASK_TMP/stop-probes"
: > "$TASK_TMP/calls"; TASK_RUN=fail-vulkan; sequence_code=0
session_compute_sequence "$TASK_TMP/runner" "$TASK_TMP/output" '' live > "$TASK_TMP/live-terminal.txt" || sequence_code=$?
[ "$sequence_code" -eq 31 ] && [ "$(cat "$TASK_TMP/calls")" = vulkan ]
grep -q metal_started=false "$TASK_TMP/output/sequence.txt"
: > "$TASK_TMP/calls"; TASK_RUN=success
session_compute_sequence "$TASK_TMP/runner" "$TASK_TMP/output" '' live > "$TASK_TMP/live-terminal.txt"
[ "$(tr '\n' ' ' < "$TASK_TMP/calls")" = 'vulkan metal metal-render metal-suite ' ]
grep -q exit=0 "$TASK_TMP/output/sequence.txt"
grep -q phase=metal-suite "$TASK_TMP/output/sequence.txt"
# A failed render keeps the passed Metal compute phase and reports its own exit.
: > "$TASK_TMP/calls"; TASK_RUN=fail-render; sequence_code=0
session_compute_sequence "$TASK_TMP/runner" "$TASK_TMP/output" || sequence_code=$?
[ "$sequence_code" -eq 33 ] && grep -q render_started=true "$TASK_TMP/output/sequence.txt"
grep -q suite_started=false "$TASK_TMP/output/sequence.txt"
# A failed suite still records that every earlier phase ran.
: > "$TASK_TMP/calls"; TASK_RUN=fail-suite; sequence_code=0
session_compute_sequence "$TASK_TMP/runner" "$TASK_TMP/output" || sequence_code=$?
[ "$sequence_code" -eq 34 ] && grep -q suite_started=true "$TASK_TMP/output/sequence.txt"

# A successful runner with failed persistent logging is not accepted as a
# successful phase, even though its terminal pipeline reached completion.
: > "$TASK_TMP/calls"; sequence_code=0
tee() { return 28; }
session_compute_sequence "$TASK_TMP/runner" "$TASK_TMP/output" '' live > "$TASK_TMP/live-terminal.txt" || sequence_code=$?
unset -f tee
[ "$sequence_code" -eq 74 ] && [ "$(cat "$TASK_TMP/calls")" = vulkan ]
grep -q metal_started=false "$TASK_TMP/output/sequence.txt"

session_bounded 2 "$TASK_TMP/command.txt" /bin/bash -c 'exit 27' && exit 1
grep -q command_exit_status=27 "$TASK_TMP/command.txt"
if session_bounded 1 "$TASK_TMP/timeout.txt" /bin/bash -c 'trap "" TERM; exec sleep 8'; then exit 1; fi
grep -q command_timeout_seconds=1 "$TASK_TMP/timeout.txt"

# Real inert process trees exercise the manual watchdog. The leader, its shell
# child and a grandchild ignore TERM so the isolated group's KILL is required;
# the fixture's own process group must remain alive throughout.
cat > "$TASK_TMP/group-child" <<'GROUP_CHILD'
#!/bin/bash
trap '' TERM
sleep 30 &
printf '%s\n' "$!" > "$TASK_TMP/grandchild.pid"
wait
GROUP_CHILD
cat > "$TASK_TMP/group-leader" <<'GROUP_LEADER'
#!/bin/bash
trap '' TERM
printf '%s\n' "$$" > "$TASK_TMP/leader.pid"
/bin/bash "$TASK_TMP/group-child" &
printf '%s\n' "$!" > "$TASK_TMP/child.pid"
wait
GROUP_LEADER
assert_tree_stopped() {
    local name pid state
    for name in leader child grandchild; do
        [ -f "$TASK_TMP/$name.pid" ] || return 1
        pid=$(cat "$TASK_TMP/$name.pid")
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        [ "$pid" -gt 1 ] && [ "$pid" -ne "$$" ] || return 1
        if kill -0 "$pid" 2>/dev/null; then
            state=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]' || :)
            # Orphaned descendants may briefly remain zombies under the host
            # init; they cannot execute and are not live command survivors.
            case "$state" in
                Z*) ;;
                '') if kill -0 "$pid" 2>/dev/null; then return 1; fi ;;
                *) return 1 ;;
            esac
        fi
    done
    kill -0 "$$"
}
group_code=0
session_bounded_group 1 "$TASK_TMP/group-timeout.txt" /bin/bash "$TASK_TMP/group-leader" || group_code=$?
[ "$group_code" -eq 124 ]
grep -q command_timeout_seconds=1 "$TASK_TMP/group-timeout.txt"
assert_tree_stopped

# The same stop helper is used by the root abort trap. Signalling that isolated
# controller must stop all descendants without signalling this fixture parent.
rm -- "$TASK_TMP/leader.pid" "$TASK_TMP/child.pid" "$TASK_TMP/grandchild.pid"
(
    trap 'session_stop_group; exit 130' TERM
    session_bounded_group 30 "$TASK_TMP/group-abort.txt" /bin/bash "$TASK_TMP/group-leader"
) &
controller=$!
ticks=0
while [ ! -f "$TASK_TMP/grandchild.pid" ] && [ "$ticks" -lt 50 ]; do sleep 0.1; ticks=$((ticks + 1)); done
kill -TERM "$controller"
controller_code=0
wait "$controller" || controller_code=$?
[ "$controller_code" -eq 130 ]
assert_tree_stopped

# Even an already-reaped successful leader must not leave a probe/logger in
# its private group. Exercise the no-leader-PID signalling branch explicitly.
rm -- "$TASK_TMP/leader.pid" "$TASK_TMP/child.pid" "$TASK_TMP/grandchild.pid"
cat > "$TASK_TMP/group-exit-leader" <<'GROUP_EXIT_LEADER'
#!/bin/bash
printf '%s\n' "$$" > "$TASK_TMP/leader.pid"
/bin/bash "$TASK_TMP/group-child" &
printf '%s\n' "$!" > "$TASK_TMP/child.pid"
ticks=0
while [ ! -f "$TASK_TMP/grandchild.pid" ] && [ "$ticks" -lt 30 ]; do sleep 0.1; ticks=$((ticks + 1)); done
exit 0
GROUP_EXIT_LEADER
session_bounded_group 5 "$TASK_TMP/group-completed.txt" /bin/bash "$TASK_TMP/group-exit-leader"
grep -q command_exit_status=0 "$TASK_TMP/group-completed.txt"
assert_tree_stopped
# A follower must be gone even when TERM is ignored, as when it lands before exec.
( trap '' TERM; exec sleep 30 ) & follower=$!
session_stop_follower "$follower"
if kill -0 "$follower" 2>/dev/null; then exit 1; fi

# The Metal frontend allows its own diagnostic names; only the Metal copy is renamed.
[ "$(session_derived_probe_name uhd770-metal-probe)" = mtlprobe ]
[ "$(session_derived_probe_name uhd770-compute-probe)" = uhd770-compute-probe ]

printf 'Session transaction, terminal/deadline export, recorder and sequential failure gates passed; no GPU accessed.\n'
