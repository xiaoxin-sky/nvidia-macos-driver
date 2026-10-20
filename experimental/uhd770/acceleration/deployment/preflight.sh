#!/bin/bash -p
# Read-only target inventory. Writes only a fresh report directory; it never
# starts a driver/probe, changes SIP/AMFI, mounts an EFI or edits boot arguments.
set -u
set -o pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH GLOBIGNORE
umask 077

if [ "${1:-}" = --help ]; then
    printf '%s\n' 'Usage: sudo /bin/bash -p tools/preflight.sh' \
        'Creates a fresh /Users/Shared/UHD770MVP-preflight.* report; no reboot or GPU activation.'
    exit 0
fi
[ "$#" -eq 0 ] || { echo 'No arguments accepted.' >&2; exit 64; }
[ "$(uname -s)" = Darwin ] || { echo 'Run in macOS.' >&2; exit 1; }
[ "$EUID" -eq 0 ] || { echo 'Run with sudo /bin/bash -p.' >&2; exit 1; }
case $- in *p*) ;; *) echo 'Use /bin/bash -p.' >&2; exit 1 ;; esac
REPORT=$(mktemp -d /Users/Shared/UHD770MVP-preflight.XXXXXX) || exit 1
CHILD=''
WATCHDOG=''
printf 'Report: %s\n' "$REPORT"
printf 'preflight_started=true\ngpu_executed=false\ndriver_installed=false\n' > "$REPORT/progress.txt"

# Queries are finite and output-capped. Preserve incomplete output and the
# pending stage even if the relevant kernel service never answers.
query() {
    local name=$1 limit=$2 ticks=0 status
    shift 2
    printf 'begin=%s utc=%s\n' "$name" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$REPORT/progress.txt"
    (ulimit -f 4096 || exit 125; exec "$@") > "$REPORT/$name.txt" 2>&1 &
    CHILD=$!
    while kill -0 "$CHILD" 2>/dev/null && [ "$ticks" -lt "$limit" ]; do
        sleep 1
        ticks=$((ticks + 1))
    done
    if kill -0 "$CHILD" 2>/dev/null; then
        kill -TERM "$CHILD" 2>/dev/null || :
        sleep 1
        kill -KILL "$CHILD" 2>/dev/null || :
        disown "$CHILD" 2>/dev/null || :
        status=124
    else
        wait "$CHILD"
        status=$?
    fi
    CHILD=''
    printf '\ncommand_exit_status=%s\n' "$status" >> "$REPORT/$name.txt"
    printf 'end=%s status=%s\n' "$name" "$status" >> "$REPORT/progress.txt"
    return "$status"
}

finish() {
    trap - EXIT INT TERM HUP
    if [ -n "$CHILD" ]; then kill -TERM "$CHILD" 2>/dev/null || :; disown "$CHILD" 2>/dev/null || :; fi
    if [ -n "$WATCHDOG" ]; then kill -TERM "$WATCHDOG" 2>/dev/null || :; disown "$WATCHDOG" 2>/dev/null || :; fi
    case "${SUDO_UID:-}:${SUDO_GID:-}" in *[!0-9:]*|:*|*:) ;; *) chown -hR "$SUDO_UID:$SUDO_GID" "$REPORT" ;; esac
    printf 'Keep the entire report folder: %s\n' "$REPORT"
}
trap finish EXIT
trap 'printf "preflight_interrupted=true\n" >> "$REPORT/progress.txt"; exit 130' INT TERM HUP
OWNER=$$
(
    sleeper=''
    trap '[ -z "$sleeper" ] || kill -TERM "$sleeper" 2>/dev/null; exit 0' TERM INT HUP
    sleep 150 & sleeper=$!
    wait "$sleeper" || exit 0
    kill -TERM "$OWNER" 2>/dev/null || :
) &
WATCHDOG=$!

query 01-macos 3 sw_vers || :
query 02-architecture 3 uname -m || :
query 03-boot 3 sysctl kern.bootargs kern.bootsessionuuid kern.boottime || :
query 04-sip 3 csrutil status || :
query 05-authenticated-root 3 csrutil authenticated-root status || :
query 06-loaded 10 kmutil showloaded || :
query 07-attach-guard 3 nvram nullmoth-gpu-attaching || :
query 08-remove-guard 3 nvram nullmoth-remove || :
query 09-nv-starts 3 nvram nullmoth-nv-starts || :
query 10-nv-ok 3 nvram nullmoth-nv-ok || :
query 11-gpu-registry 5 ioreg -r -c NMXGPU -l -w0 || :
query 12-accel-registry 5 ioreg -r -c NMXAccel -l -w0 || :
query 13-igpu-registry 5 ioreg -r -n IGPU -l -w0 || :
query 14-dmesg 5 dmesg || :
query 15-recent-driver-events 12 log show --last 5m --info --debug --style compact --predicate \
    'process == "kernel" AND (eventMessage CONTAINS[c] "NMXGPU" OR eventMessage CONTAINS[c] "NMXAccel" OR eventMessage CONTAINS[c] "NullMoth" OR eventMessage CONTAINS[c] "i915")' || :
query 16-safe-stage-parent 3 stat -f '%N uid=%u mode=%Lp' /Library '/Library/Application Support' /private /private/var /private/var/log /Library/LaunchDaemons || :

for name in NMXGPU NMXAccel; do
    path="/Library/Extensions/$name.kext"
    if [ -d "$path" ] && [ ! -L "$path" ]; then
        query "17-$name-hash" 5 shasum -a 256 "$path/Contents/MacOS/$name" || :
        query "18-$name-signature" 5 codesign -d --verbose=4 "$path" || :
        query "19-$name-info" 3 plutil -p "$path/Contents/Info.plist" || :
    fi
done
{
    printf 'Target: UHD 770 / 8086:4680 / x86_64 macOS 15\n'
    if grep -Eq 'kern.bootargs:.*(^|[[:space:]])-nvoff([[:space:]]|$)' "$REPORT/03-boot.txt"; then
        printf 'current_boot_optout=observed\n'
    else
        printf 'current_boot_optout=NOT_CONFIRMED; do not stage or enable yet\n'
    fi
    printf 'No live EFI was read or modified. Saved EFI references do not attest the current boot configuration.\n'
    printf 'No driver was installed/loaded by this tool; no GPU test was run.\n'
    printf 'Read command_exit_status in each file: a missing/timeout query is unknown, not success.\n'
} > "$REPORT/summary.txt"
printf 'preflight_finished=true\ngpu_executed=false\n' >> "$REPORT/progress.txt"
cat "$REPORT/summary.txt"
