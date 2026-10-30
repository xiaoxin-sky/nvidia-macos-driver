#!/bin/bash -p
# Plan step F2 (experimental/uhd770/DESKTOP-PLAN.zh.md 3.5): on a test boot (Run-UHD770-Test first is optional), arm NMXAccel with its framebuffer (NMIntelFB) and restart WindowServer once,
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
        'Run once, on the test boot, once logged in (Run-UHD770-Test.command first is optional).' \
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
            debug.nmxaccel_heads_piped debug.nmxaccel_front_copies debug.nmxaccel_front_hz 2>&1 || :
        pgrep -lx WindowServer || printf 'WindowServer: not running\n'
    } > "$report/$name-sysctl.txt"
    bounded 5 "$report/$name-NMXAccel.txt" ioreg -r -c NMXAccel -l -w0
    bounded 5 "$report/$name-NMIntelFB.txt" ioreg -r -c NMIntelFB -l -w0
    # r40: the DRM user clients WindowServer opens on NMXGPU when its sandbox denies ioctls on /dev/dri
    bounded 5 "$report/$name-DRMClient.txt" ioreg -r -c IOAccelNMXDRMClient -l -w0
}

# r41: WindowServer's vkCreateDevice failed (-3) once its ioctls went through NMXGPU's IOKit client. The compute
# probe runs here with every ioctl on that client (NMX_DRM_IOKIT=1), outside the sandbox, so its output shows
# whether the transport itself breaks device creation, and Mesa's reason if it does.
iokit_probe() {
    local report=$1 rt=/Library/GPUBundles/nvmtl probe="$ROOT/components/probe" binary
    binary="$probe/uhd770-compute-probe"
    [ -x "$binary" ] || binary="$ROOT/derived-probes/uhd770-compute-probe"
    if [ ! -x "$binary" ] || [ ! -f "$probe/verify.comp.spv" ] || [ ! -f "$rt/libvulkan_intel.dylib" ]; then
        printf 'compute probe or runtime not found (%s, %s)\n' "$binary" "$rt" > "$report/iokit-probe.txt"
        return
    fi
    printf '{"file_format_version":"1.0.0","ICD":{"library_path":"%s/libvulkan_intel.dylib","api_version":"1.3.0"}}\n' \
        "$rt" > "$report/iokit-icd.json"
    bounded 60 "$report/iokit-probe.txt" env NMX_DRM_IOKIT=1 "$binary" --loader "$rt/libvulkan.1.dylib" \
        --icd "$report/iokit-icd.json" --shader "$probe/verify.comp.spv" --device-id 0x4680 --count 4099 \
        --iterations 3 --deadline 45
    bounded 5 "$report/iokit-probe-clients.txt" ioreg -r -c IOAccelNMXDRMClient -l -w0
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

# The 1401 USB by the volume UUID that preparation recorded, mounted if macOS has not; never by its mount name,
# which becomes "1401 2" when another volume has that name and missed the r40 report.
usb_mount_point() {
    local uuid info mp=''
    uuid=$(plutil -extract volume_uuid raw -o - "$PUBLIC/plan.plist" 2>/dev/null) || return 1
    [ -n "$uuid" ] || return 1
    info=$(mktemp /private/tmp/uhd770-usb.XXXXXX) || return 1
    if diskutil info -plist "$uuid" > "$info" 2>/dev/null; then mp=$(plutil -extract MountPoint raw -o - "$info" 2>/dev/null || :); fi
    if [ -z "$mp" ] && diskutil mount "$uuid" > /dev/null 2>&1 && diskutil info -plist "$uuid" > "$info" 2>/dev/null; then
        mp=$(plutil -extract MountPoint raw -o - "$info" 2>/dev/null || :)
    fi
    rm -f "$info"
    [ -n "$mp" ] && [ -d "$mp" ] && [ ! -L "$mp" ] && [ -f "$mp/EFI/OC/config.plist" ] || return 1
    printf '%s\n' "$mp"
}

# to_usb <report> <stage>: copy the report so far; repeated after every step, so a watchdog panic loses nothing
# already recorded and no extra macOS boot is needed to fetch it
to_usb() {
    local report=$1 stage=$2 usb
    if ! usb=$(usb_mount_point); then
        { printf '%s: no 1401 USB\n' "$stage"; ls -la /Volumes; } >> "$report/usb-copy.txt" 2>&1
        return 0
    fi
    printf '%s: %s/UHD770-desktop-reports/%s\n' "$stage" "$usb" "${report##*/}" >> "$report/usb-copy.txt"
    mkdir -p "$usb/UHD770-desktop-reports/${report##*/}" &&
        ditto "$report" "$usb/UHD770-desktop-reports/${report##*/}" &&
        bounded 30 "$report/usb-sync.txt" sync || printf '%s: copy failed\n' "$stage" >> "$report/usb-copy.txt"
}

worker() {
    local report=$1
    printf 'worker started %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    snapshot "$report" 1-before
    to_usb "$report" 1-before
    iokit_probe "$report"
    if [ "$(sysctl -n debug.nmxaccel_headless)" = 0 ]; then
        printf 'already armed on this boot: only WindowServer restarts\n' > "$report/arm-fb.txt"
    else
        sysctl -w debug.nmxaccel_iop=1 > "$report/arm-iop.txt" 2>&1 || :
        sleep 1
        sysctl -w debug.nmxaccelfb=3 > "$report/arm-fb.txt" 2>&1 || :
        sleep 2
    fi
    snapshot "$report" 2-armed
    to_usb "$report" 2-armed
    printf 'restarting WindowServer %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    restart_windowserver > "$report/windowserver-restart.txt" 2>&1
    sleep "$OBSERVE_FIRST"
    snapshot "$report" 3-after-${OBSERVE_FIRST}s
    to_usb "$report" 3-after
    sleep "$OBSERVE_SECOND"
    snapshot "$report" 4-after-$((OBSERVE_FIRST + OBSERVE_SECOND))s
    to_usb "$report" 4-after
    bounded 90 "$report/log.txt" log show --last 5m --info --debug --style compact --predicate \
        '(process == "kernel" AND (eventMessage CONTAINS "NMXAccel" OR eventMessage CONTAINS "NullMoth" OR (eventMessage CONTAINS "Sandbox" AND eventMessage CONTAINS "WindowServer"))) OR (process == "WindowServer" AND (messageType == error OR messageType == fault OR eventMessage CONTAINS "NullMoth" OR eventMessage CONTAINS[c] "metal" OR eventMessage CONTAINS[c] "accelerat" OR eventMessage CONTAINS[c] "display pipe" OR eventMessage CONTAINS "IOPresent"))'
    # r37: WindowServer found no Vulkan device although the render node is 0666; a sandbox denial would show here
    bounded 60 "$report/sandbox.txt" log show --last 5m --style compact --predicate \
        'eventMessage CONTAINS "Sandbox" AND (eventMessage CONTAINS "WindowServer" OR eventMessage CONTAINS "/dev/dri")'
    printf 'done %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$report/done.txt"
    to_usb "$report" done
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
# The boot job must have put the safe config back on the USB first, so whatever happens next the following boot is
# the recovery one. Run-UHD770-Test is no longer required (r41 speedup): it does the same check.
grep -qx 'next_boot_optout=verified' "$PUBLIC/recovery-$boot.txt" 2>/dev/null || {
    printf 'REFUSED: the next boot is not confirmed safe yet; wait a minute after login and run this again.\n' >&2
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
    'The report is copied to the 1401 USB (UHD770-desktop-reports/) at every step; the last copy about 3 minutes after this line.' \
    'If the screen stays black or frozen: wait 3 minutes, then restart; Windows can read the report, no macOS boot is needed.'
