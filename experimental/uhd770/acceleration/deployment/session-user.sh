#!/bin/bash -p
# Explicit selected-account test entry point. It never installs a driver or
# edits EFI/NVRAM. No-argument/login invocation cannot start a GPU diagnostic;
# both probes retain their own UUID/ownership/readback/deadline gates.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH GLOBIGNORE
umask 077
ROOT='/Library/Application Support/UHD770MVP'
PLAN="$ROOT/session-public/plan.plist"
usage() {
    printf '%s\n' 'Usage: /bin/bash -p session-user.sh manual|preflight' \
        'manual: explicitly run the bounded Vulkan, then Metal compute/readback tests after reboot.' \
        'preflight: preparation-boot identity/readability check only; never starts a GPU test.' \
        'Use Run-UHD770-Test.command. Its root coordinator starts fresh logging and drops to the selected user.'
}
refuse() { printf 'REFUSED: %s\n' "$*" >&2; exit 64; }
[ "${1:-}" != --help ] || { usage; exit 0; }
[ "$#" -eq 1 ] || { usage >&2; exit 64; }
MODE=$1
case "$MODE" in manual|preflight) ;; *) refuse 'Choose manual or preflight explicitly.' ;; esac
[ "$(uname -s)" = Darwin ] || refuse 'macOS is required; no diagnostic was started.'
[ "$EUID" -ne 0 ] || refuse 'Run as your ordinary macOS user, without sudo.'
case $- in *p*) ;; *) refuse 'Use /bin/bash -p.' ;; esac
[ -f "$PLAN" ] && [ ! -L "$PLAN" ] || refuse 'Missing protected preparation plan.'
[ "$(stat -f '%u' "$PLAN")" = 0 ] || refuse 'Preparation plan is not root owned.'
[ $((8#$(stat -f '%Lp' "$PLAN") & 0022)) -eq 0 ] || refuse 'Preparation plan is writable by group/others.'
[ "$(plutil -extract user_uid raw -o - "$PLAN")" = "$EUID" ] || refuse 'Run from the user account selected during preparation.'
BOOT=$(sysctl -n kern.bootsessionuuid)
case "$BOOT" in ''|*[!a-zA-Z0-9-]*) refuse 'Invalid current boot identity.' ;; esac
ACCOUNT=$(id -un)
USER_HOME=$(dscl . -read "/Users/$ACCOUNT" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
case "$USER_HOME" in /Users/*) ;; *) refuse 'Cannot determine the selected account home.' ;; esac
PREPARATION_BOOT=$(plutil -extract preparation_boot raw -o - "$PLAN")
if [ "$MODE" = preflight ]; then
    [ "$BOOT" = "$PREPARATION_BOOT" ] || refuse 'Preflight is allowed only on the preparation boot.'
else
    [ "$BOOT" != "$PREPARATION_BOOT" ] || refuse 'Preparation is complete only after PREPARED; reboot before running the manual test.'
    ARGS=$(sysctl -n kern.bootargs)
    case " $ARGS " in *' -nvoff '*) refuse 'This boot is opted out (-nvoff); no test was started.' ;; esac
    case " $ARGS " in *' nmxintel=1 '*) ;; *) refuse 'This is not the prepared Intel test boot (nmxintel=1 missing).' ;; esac
    [ "$(cat "$ROOT/session-public/state.txt")" = armed ] || refuse 'The prepared session is not armed; no test was started.'
    AUTH="$ROOT/session-public/manual-authorization-$BOOT.txt"
    [ -f "$AUTH" ] && [ ! -L "$AUTH" ] || refuse 'Use Run-UHD770-Test.command to start and verify fresh logging first.'
    [ "$(stat -f '%u' "$AUTH")" = 0 ] && [ $((8#$(stat -f '%Lp' "$AUTH") & 0022)) -eq 0 ] || refuse 'Unsafe manual capture authorization.'
    grep -qx 'manual_authorization=active' "$AUTH" && grep -qx "boot=$BOOT" "$AUTH" && \
        grep -qx "uid=$EUID" "$AUTH" || refuse 'No active root-verified manual capture for this boot.'
fi
OUTPUT="$USER_HOME/Library/Logs/UHD770MVP"
mkdir -p "$OUTPUT"
chmod 700 "$OUTPUT"
[ ! -L "$OUTPUT" ] && [ "$(stat -f '%u' "$OUTPUT")" = "$EUID" ] || refuse 'Unsafe selected-user log directory.'
if [ "$MODE" = preflight ]; then
    # The installer invokes this once as the actual selected ordinary user to
    # verify file readability/identity now, before changing any USB boot flag.
    printf 'boot=%s\nuid=%s\nuser_job_entrypoint=passed\n' "$BOOT" "$EUID" > "$OUTPUT/preflight-$BOOT.txt"
    printf 'Preflight identity/readability check passed. No GPU diagnostic was started.\n'
    exit 0
fi
# Directory creation is an atomic per-boot lock: another manual invocation
# cannot repeat GPU submission after an incomplete/hung invocation this boot.
SESSION="$OUTPUT/manual-$BOOT"
mkdir -m 700 "$SESSION" || refuse "A manual session already exists for this boot. Preserve its logs: $SESSION"
. "$ROOT/session-tools/session-lib.sh"
exec 3>&1 4>&2
exec > >(tee "$SESSION/coordinator.txt" >&3) 2>&1
LOGGER=$!
printf 'boot=%s\nmode=manual\ngpu_started=false\n' "$BOOT" > "$SESSION/session.txt"
finish() {
    local code=$?
    trap - EXIT INT TERM HUP
    set +e
    if [ "$code" -eq 0 ]; then
        printf '\nFINISHED: both bounded application compute/readback diagnostics passed. Desktop acceleration is not established.\n'
    else
        printf '\nSTOPPED: manual test exited with status %s. This is not a GPU success result.\n' "$code"
    fi
    printf 'User evidence: %s\n' "$SESSION"
    # Close the streaming pipe and wait for tee before publishing completion.
    # A blocked logger leaves no completed terminal marker; a failed logger
    # cannot convert a successful probe return into a fully recorded session.
    exec 1>&3 2>&4
    wait "$LOGGER" || { [ "$code" -ne 0 ] || code=74; }
    printf 'coordinator_exit=%s\n' "$code" >> "$SESSION/session.txt"
    session_write_terminal "$SESSION" "$BOOT" "$EUID" "$code" || { [ "$code" -ne 0 ] || code=74; }
    exit "$code"
}
trap finish EXIT
trap 'exit 130' INT HUP
trap 'exit 143' TERM
elapsed=0
ready=0
printf 'MANUAL TEST: explicitly started by %s (uid %s).\n' "$ACCOUNT" "$EUID"
printf 'Evidence is written to disk and shown here: %s\n' "$SESSION"
printf 'WAITING: verifying next-boot recovery and driver initialization (up to 330 seconds).\n'
while [ "$elapsed" -lt 330 ]; do
    [ ! -f "$ROOT/session-public/deadline-$BOOT.txt" ] || { printf 'The bounded session deadline has expired; no new probe will be started.\n'; exit 124; }
    recovery="$ROOT/session-public/recovery-$BOOT.txt"
    if [ -f "$recovery" ] && grep -qx 'next_boot_optout=NOT_VERIFIED' "$recovery"; then
        printf 'Independent next-boot recovery not verified; no probe started.\n'
        exit 65
    fi
    if [ -f "$recovery" ] && grep -qx 'next_boot_optout=verified' "$recovery"; then
        if session_bounded 3 "$SESSION/registry-latest.txt" ioreg -r -c NMXGPU -l -w0; then
            if session_registry_ready "$SESSION/registry-latest.txt"; then ready=1; break; fi
            if grep -q 'failed:.*guard retained\|attach.no_framebuffer' "$SESSION/registry-latest.txt"; then
                printf 'Driver initialization failed; no compute probe started.\n'
                exit 66
            fi
        else
            printf 'IORegistry timed out/failed; no compute probe started.\n'
            exit 67
        fi
    fi
    if [ $((elapsed % 30)) -eq 0 ]; then
        printf 'WAITING: %s seconds elapsed; no compute runner started yet.\n' "$elapsed"
    fi
    sleep 5; elapsed=$((elapsed + 5))
done
[ "$ready" -eq 1 ] || { printf 'Initialization/recovery gate did not complete.\n'; exit 68; }
printf 'READY: recovery and initialization checks passed. Each runner will still validate the loaded candidate and device identity.\n'
# This records entry into the guarded runner sequence, not proven GPU work or
# successful hardware acceleration. Readback success remains probe evidence.
printf 'gpu_started=true\n' >> "$SESSION/session.txt"
session_compute_sequence "$ROOT/probes/run-probe.sh" "$SESSION" "$ROOT/session-public/deadline-$BOOT.txt" live
