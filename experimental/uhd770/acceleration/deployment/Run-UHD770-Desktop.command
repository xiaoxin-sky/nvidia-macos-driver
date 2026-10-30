#!/bin/bash -p
# Plan step F2 (experimental/uhd770/DESKTOP-PLAN.zh.md 3.5): after Run-UHD770-Test on a
# test boot, arm NMXAccel with its framebuffer (NMIntelFB) and restart WindowServer once,
# so the desktop composites on the GPU and the display pipe copies frames to the screen.
# Everything it switches on is runtime state: a reboot disarms it. A root launchd job does
# the work, because restarting WindowServer ends this Terminal session; it records the
# switches, registry and logs and copies them to the 1401 USB.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH GLOBIGNORE
LABEL=com.uhd770.mvp.desktop
ROOT='/Library/Application Support/UHD770MVP'
PUBLIC="$ROOT/session-public"
OBSERVE_FIRST=20
OBSERVE_SECOND=40

usage() {
    printf '%s\n' 'Usage: sudo /bin/bash -p Run-UHD770-Desktop.command' \
        'Run once, on the test boot, after Run-UHD770-Test.command finished.' \
        'Arms the Intel accelerator for WindowServer and restarts WindowServer (you are logged out once).' \
        'A reboot undoes it. The report goes to the 1401 USB under UHD770-desktop-reports/.'
}

# bounded <seconds> <output> <command...>: never let one capture hold up the rest
bounded() {
    local limit=$1 output=$2 child elapsed=0
    shift 2
    "$@" > "$output" 2>&1 &
    child=$!
    while kill -0 "$child" 2>/dev/null && [ "$elapsed" -lt $((limit * 10)) ]; do sleep 0.1; elapsed=$((elapsed + 1)); done
    if kill -0 "$child" 2>/dev/null; then kill -KILL "$child" 2>/dev/null || :; printf '\ncommand_timeout_seconds=%s\n' "$limit" >> "$output"; fi
    wait "$child" 2>/dev/null || :
}

snapshot() {
    local report=$1 name=$2
    {
        printf 'utc=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        sysctl debug.nmxaccel_headless debug.nmxaccelfb debug.nmxaccel_iop debug.nmxaccel_iop_ok \
            debug.nmxaccel_iop_ok_h0 debug.nmxaccel_iop_fail debug.nmxaccel_iop_empty debug.nmxaccel_iop_src_surf \
            debug.nmxaccel_iop_blank debug.nmxaccel_heads_published debug.nmxaccel_heads_registered \
            debug.nmxaccel_heads_piped 2>&1 || :
        pgrep -lx WindowServer || printf 'WindowServer: not running\n'
    } > "$report/$name-sysctl.txt"
    bounded 5 "$report/$name-NMXAccel.txt" ioreg -r -c NMXAccel -l -w0
    bounded 5 "$report/$name-NMIntelFB.txt" ioreg -r -c NMIntelFB -l -w0
}

# r35: a plain killall (SIGTERM) left WindowServer running. SIGHUP is the usual way to
# end it (loginwindow starts a new one); SIGKILL only if the same process is still there.
restart_windowserver() {
    local before
    before=$(pgrep -x WindowServer || :)
    printf 'before: %s\n' "${before:-none}"
    killall -HUP WindowServer || :
    sleep 5
    if [ -n "$before" ] && pgrep -x WindowServer | grep -qx "$before"; then
        printf 'still pid %s after SIGHUP: SIGKILL\n' "$before"
        killall -KILL WindowServer || :
        sleep 5
    fi
    printf 'after: %s\n' "$(pgrep -x WindowServer | tr '\n' ' ')"
}

worker() {
    local report=$1 usb
    printf 'worker started %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    snapshot "$report" 1-before
    if [ "$(sysctl -n debug.nmxaccel_headless)" = 0 ]; then
        printf 'already armed on this boot: only WindowServer restarts\n' > "$report/arm-fb.txt"
    else
        sysctl -w debug.nmxaccel_iop=1 > "$report/arm-iop.txt" 2>&1 || :
        sleep 1
        sysctl -w debug.nmxaccelfb=3 > "$report/arm-fb.txt" 2>&1 || :
        sleep 2
    fi
    snapshot "$report" 2-armed
    printf 'restarting WindowServer %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    restart_windowserver > "$report/windowserver-restart.txt" 2>&1
    sleep "$OBSERVE_FIRST"
    snapshot "$report" 3-after-${OBSERVE_FIRST}s
    sleep "$OBSERVE_SECOND"
    snapshot "$report" 4-after-$((OBSERVE_FIRST + OBSERVE_SECOND))s
    bounded 90 "$report/log.txt" log show --last 5m --info --debug --style compact --predicate \
        '(process == "kernel" AND (eventMessage CONTAINS "NMXAccel" OR eventMessage CONTAINS "NullMoth" OR (eventMessage CONTAINS "Sandbox" AND eventMessage CONTAINS "WindowServer"))) OR (process == "WindowServer" AND (messageType == error OR messageType == fault OR eventMessage CONTAINS "NullMoth" OR eventMessage CONTAINS[c] "metal" OR eventMessage CONTAINS[c] "accelerat" OR eventMessage CONTAINS[c] "display pipe" OR eventMessage CONTAINS "IOPresent"))'
    # r37: WindowServer found no Vulkan device although the render node is 0666; a sandbox denial would show here
    bounded 60 "$report/sandbox.txt" log show --last 5m --style compact --predicate \
        'eventMessage CONTAINS "Sandbox" AND (eventMessage CONTAINS "WindowServer" OR eventMessage CONTAINS "/dev/dri")'
    printf 'done %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$report/done.txt"
    for usb in /Volumes/*; do
        [ -d "$usb" ] && [ ! -L "$usb" ] && [ -f "$usb/EFI/OC/config.plist" ] || continue
        [ "${usb##*/}" = 1401 ] || continue
        mkdir -p "$usb/UHD770-desktop-reports" && ditto "$report" "$usb/UHD770-desktop-reports/${report##*/}" &&
            bounded 60 "$report/usb-sync.txt" sync && printf 'USB copy: %s\n' "$usb/UHD770-desktop-reports/${report##*/}"
    done
    printf 'worker finished %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}

if [ "${1:-}" = --worker ]; then
    [ "$EUID" -eq 0 ] && [ -d "${2:-}" ] && [ ! -L "$2" ] || exit 64
    worker "$2"
    exit 0
fi
[ "${1:-}" != --help ] || { usage; exit 0; }
[ "$#" -eq 0 ] || { usage >&2; exit 64; }
[ "$(uname -s)" = Darwin ] || { printf 'REFUSED: macOS is required.\n' >&2; exit 64; }
[ "$EUID" -eq 0 ] || { printf 'REFUSED: use sudo /bin/bash -p Run-UHD770-Desktop.command.\n' >&2; exit 64; }
case $- in *p*) ;; *) printf 'REFUSED: use /bin/bash -p.\n' >&2; exit 64 ;; esac

boot=$(sysctl -n kern.bootsessionuuid)
case "$boot" in ''|*[!a-zA-Z0-9-]*) printf 'REFUSED: invalid boot identity.\n' >&2; exit 65 ;; esac
args=$(sysctl -n kern.bootargs)
case " $args " in *' -nvoff '*) printf 'REFUSED: this is the opt-out recovery boot; nothing to arm.\n' >&2; exit 65 ;; esac
case " $args " in *' nmxintel=1 '*) ;; *) printf 'REFUSED: the Intel driver is not enabled on this boot.\n' >&2; exit 65 ;; esac
[ -f "$PUBLIC/manual-result-$boot.txt" ] || {
    printf 'REFUSED: run Run-UHD770-Test.command first on this boot, so its report is saved before WindowServer restarts.\n' >&2
    exit 65; }
sysctl -n debug.nmxaccelfb > /dev/null 2>&1 || { printf 'REFUSED: this NMXAccel has no debug.nmxaccelfb switch.\n' >&2; exit 66; }
ioreg -r -c NMXGPU -l -w0 | grep -q '"nmxdiag-display-state" = "owned-by-NMIntelFB"' ||
    { printf 'REFUSED: the screen does not belong to NMIntelFB on this boot.\n' >&2; exit 66; }
# An earlier run on this boot may have armed the accelerator but not restarted WindowServer
# (r35): run again, re-arming nothing. Its finished job is removed first.
if launchctl print "system/$LABEL" > /dev/null 2>&1; then
    pgrep -f -- '--worker /Users/Shared/UHD770MVP-desktop' > /dev/null &&
        { printf 'REFUSED: a desktop switch is still running; wait for its report.\n' >&2; exit 66; }
    launchctl bootout "system/$LABEL" 2>/dev/null || :
fi

report=$(mktemp -d /Users/Shared/UHD770MVP-desktop.XXXXXX)
chmod 755 "$report"
printf 'boot=%s\nboot_args=%s\n' "$boot" "$args" > "$report/context.txt"
# the job runs a copy here: launchd may not read a kit inside Downloads or Desktop
cp "$0" "$report/Run-UHD770-Desktop.command"
chmod 755 "$report/Run-UHD770-Desktop.command"
plist="$report/$LABEL.plist"
plutil -create xml1 "$plist"
plutil -insert Label -string "$LABEL" "$plist"
plutil -insert ProgramArguments -array "$plist"
for word in /bin/bash -p "$report/Run-UHD770-Desktop.command" --worker "$report"; do
    plutil -insert ProgramArguments -string "$word" -append "$plist"
done
plutil -insert RunAtLoad -bool true "$plist"
plutil -insert KeepAlive -bool false "$plist"
plutil -insert LaunchOnlyOnce -bool true "$plist"
plutil -insert StandardOutPath -string "$report/worker.txt" "$plist"
plutil -insert StandardErrorPath -string "$report/worker.txt" "$plist"
chown root:wheel "$plist"
chmod 644 "$plist"
launchctl bootstrap system "$plist"
printf '%s\n' '' "Desktop switch started; report: $report" \
    'In a few seconds the screen goes back to the login window: log in again.' \
    'About 2 minutes after this line the report is copied to the 1401 USB (UHD770-desktop-reports/).' \
    'If the screen stays black or frozen: wait 5 minutes, then restart through the 1401 USB; the reboot disarms everything.'
