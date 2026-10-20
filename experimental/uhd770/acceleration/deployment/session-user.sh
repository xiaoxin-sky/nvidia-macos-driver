#!/bin/bash -p
# Selected-account, next-boot coordinator. It never installs a driver or edits
# EFI/NVRAM. Both probes retain their own UUID/ownership/readback/deadline gates.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH GLOBIGNORE
umask 077
ROOT='/Library/Application Support/UHD770MVP'
PLAN="$ROOT/session-public/plan.plist"
[ "$(uname -s)" = Darwin ] && [ "$EUID" -ne 0 ] || exit 64
case $- in *p*) ;; *) exit 64 ;; esac
[ -f "$PLAN" ] && [ ! -L "$PLAN" ] || exit 64
[ "$(stat -f '%u' "$PLAN")" = 0 ] || exit 64
[ $((8#$(stat -f '%Lp' "$PLAN") & 0022)) -eq 0 ] || exit 64
[ "$(plutil -extract user_uid raw -o - "$PLAN")" = "$EUID" ] || exit 0
BOOT=$(sysctl -n kern.bootsessionuuid)
ACCOUNT=$(id -un)
USER_HOME=$(dscl . -read "/Users/$ACCOUNT" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
case "$USER_HOME" in /Users/*) ;; *) exit 64 ;; esac
OUTPUT="$USER_HOME/Library/Logs/UHD770MVP"
mkdir -p "$OUTPUT"
chmod 700 "$OUTPUT"
[ ! -L "$OUTPUT" ] && [ "$(stat -f '%u' "$OUTPUT")" = "$EUID" ] || exit 64
if [ "$BOOT" = "$(plutil -extract preparation_boot raw -o - "$PLAN")" ]; then
    # The installer launches this once in the real selected login domain to
    # verify file readability/identity now, before changing any USB boot flag.
    printf 'boot=%s\nuid=%s\nuser_job_entrypoint=passed\n' "$BOOT" "$EUID" > "$OUTPUT/preflight-$BOOT.txt"
    exit 0
fi
ARGS=$(sysctl -n kern.bootargs)
case " $ARGS " in *' -nvoff '*) exit 0 ;; esac
case " $ARGS " in *' nmxintel=1 '*) ;; *) exit 0 ;; esac
[ "$(cat "$ROOT/session-public/state.txt")" = armed ] || exit 0
# Directory creation is an atomic per-boot lock: launchd restart cannot repeat
# GPU submission after an incomplete/hung invocation on this same boot.
SESSION="$OUTPUT/automatic-$BOOT"
mkdir -m 700 "$SESSION" || exit 0
exec > "$SESSION/coordinator.txt" 2>&1
printf 'boot=%s\ngpu_started=false\n' "$BOOT" > "$SESSION/session.txt"
. "$ROOT/session-tools/session-lib.sh"
finish() {
    local code=$?
    trap - EXIT INT TERM HUP
    set +e
    printf 'coordinator_exit=%s\n' "$code" >> "$SESSION/session.txt"
    session_write_terminal "$SESSION" "$BOOT" "$EUID" "$code"
}
trap finish EXIT
trap 'exit 130' INT HUP
trap 'exit 143' TERM
elapsed=0
ready=0
while [ "$elapsed" -lt 330 ]; do
    [ ! -f "$ROOT/session-public/deadline-$BOOT.txt" ] || exit 124
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
    sleep 5; elapsed=$((elapsed + 5))
done
[ "$ready" -eq 1 ] || { printf 'Initialization/recovery gate did not complete.\n'; exit 68; }
printf 'gpu_started=true\n' >> "$SESSION/session.txt"
session_compute_sequence "$ROOT/probes/run-probe.sh" "$SESSION" "$ROOT/session-public/deadline-$BOOT.txt"
printf 'Both bounded application compute/readback diagnostics passed. Desktop acceleration is not established.\n'
