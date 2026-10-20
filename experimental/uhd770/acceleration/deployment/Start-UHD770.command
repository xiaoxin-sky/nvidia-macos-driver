#!/bin/bash -p
# Capture preparation from its first command, including failures before PLAN
# exists. The root-only original remains authoritative for later export.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH GLOBIGNORE
umask 077
KIT=$(cd "$(dirname "$0")" && pwd -P)
if [ "${1:-}" = --help ]; then
    printf '%s\n' 'Usage: sudo /bin/bash -p Start-UHD770.command' \
      'Prepare only. After PREPARED and reboot, use Run-UHD770-Test.command to explicitly start compute.' \
      'No automatic reboot or login-time compute. Read README-session.txt first.'
    exit 0
fi
[ "$#" -eq 0 ] || exit 64
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = x86_64 ] || { printf 'STOP: native x86_64 macOS required.\n' >&2; exit 64; }
[ "$EUID" -eq 0 ] || { printf 'STOP: use sudo /bin/bash -p Start-UHD770.command.\n' >&2; exit 64; }
case $- in *p*) ;; *) printf 'STOP: use /bin/bash -p.\n' >&2; exit 64 ;; esac
REPORT=$(mktemp -d /Users/Shared/UHD770MVP-bootstrap.XXXXXX)
chmod 700 "$REPORT"
printf 'Preparation log: %s\n' "$REPORT"
if {
    printf 'bootstrap_utc=%s\nroot_account=%s\nkit=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(id -un)" "$KIT"
    # Do not change system permissions: record the exact ancestors that made
    # earlier runs fail before the ordinary session report could be created.
    ls -lde /private /private/var /private/var/run /Library '/Library/Application Support' \
        '/Library/Application Support/.com.uhd770.mvp.prepare.lock' \
        '/Library/Application Support/UHD770MVP' \
        /Library/Extensions /Library/NullMoth /Library/GPUBundles /Library/KernelCollections \
        /Library/LaunchDaemons /Library/LaunchAgents "$KIT" "$KIT/tools/session.sh" "$REPORT" || :
    stat -f 'path=%N uid=%u gid=%g mode=%Lp type=%HT' /private/var/run "$REPORT" || :
    /bin/bash -p "$KIT/tools/session.sh" prepare
} 2>&1 | tee "$REPORT/prepare.txt"; then
    statuses=("${PIPESTATUS[@]}")
else
    statuses=("${PIPESTATUS[@]}")
fi
code=${statuses[0]}
if [ "$code" -eq 0 ] && [ "${statuses[1]}" -ne 0 ]; then code=74; fi
printf 'child_exit=%s\ntee_exit=%s\nbootstrap_exit=%s\n' "${statuses[0]}" "${statuses[1]}" "$code" > "$REPORT/bootstrap-result.txt" || :

# Copy only to one already-mounted volume carrying this package's exact safe
# or test EFI bytes. This writes a fresh log directory, never the EFI/config.
identity="$KIT/session-target/identity.plist"
safe=$(plutil -extract safe_hash raw -o - "$identity" 2>/dev/null || :)
test=$(plutil -extract test_hash raw -o - "$identity" 2>/dev/null || :)
match=''
matches=0
if [ "${#safe}" -eq 64 ] && [ "${#test}" -eq 64 ] &&
   [ -z "$(printf '%s%s' "$safe" "$test" | tr -d '0-9a-f')" ]; then
    for volume in /Volumes/*; do
        [ -d "$volume" ] && [ ! -L "$volume" ] || continue
        cfg="$volume/EFI/OC/config.plist"
        [ -d "$volume/EFI" ] && [ ! -L "$volume/EFI" ] &&
        [ -d "$volume/EFI/OC" ] && [ ! -L "$volume/EFI/OC" ] &&
        [ -f "$cfg" ] && [ ! -L "$cfg" ] || continue
        actual=$(shasum -a 256 "$cfg" 2>/dev/null | awk '{print $1}') || continue
        if [ "$actual" = "$safe" ] || [ "$actual" = "$test" ]; then
            match=$volume; matches=$((matches + 1))
        fi
    done
fi
copied=0
if [ "$matches" -eq 1 ]; then
    destination="$match/UHD770-prepare-logs"
    if [ ! -e "$destination" ] && [ ! -L "$destination" ]; then mkdir "$destination" || :; fi
    if [ -d "$destination" ] && [ ! -L "$destination" ] &&
       [ ! -e "$destination/${REPORT##*/}" ] && [ ! -L "$destination/${REPORT##*/}" ]; then
        if mkdir "$destination/${REPORT##*/}" && ditto "$REPORT" "$destination/${REPORT##*/}"; then
            copied=1
            printf 'USB log copy: %s\n' "$destination/${REPORT##*/}"
        fi
    fi
fi
[ "$copied" -eq 1 ] || printf 'USB log copy unavailable/ambiguous/failed; keep the system-disk report.\n' >&2
printf 'Preparation exit=%s. Original report: %s\n' "$code" "$REPORT"
exit "$code"
