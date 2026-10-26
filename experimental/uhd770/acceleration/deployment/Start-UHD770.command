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
      'An earlier package'"'"'s session, stage or stale lock is restored and archived first, through the same' \
      'session.sh restore / Archive-UHD770-Failed.command checks; the first refusal stops with nothing replaced.' \
      'No automatic reboot or login-time compute. The full transcript goes to the log, not the terminal.'
    exit 0
fi
[ "$#" -eq 0 ] || exit 64
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = x86_64 ] || { printf 'STOP: native x86_64 macOS required.\n' >&2; exit 64; }
[ "$EUID" -eq 0 ] || { printf 'STOP: use sudo /bin/bash -p Start-UHD770.command.\n' >&2; exit 64; }
case $- in *p*) ;; *) printf 'STOP: use /bin/bash -p.\n' >&2; exit 64 ;; esac
REPORT=$(mktemp -d /Users/Shared/UHD770MVP-bootstrap.XXXXXX)
chmod 700 "$REPORT"
printf 'UHD770 准备中：通常 10–25 分钟。请保持终端打开，不要重启。\n'

# Clear whatever an earlier package left, with the same tools a person would
# otherwise run by hand after a refusal. Each keeps all of its own checks; the
# first one that refuses stops here, before any system file is replaced.
UHD_PARENT='/Library/Application Support'
UHD_ROOT="$UHD_PARENT/UHD770MVP"
UHD_LOCK="$UHD_PARENT/.com.uhd770.mvp.prepare.lock"
auto_clean() {
    local state='' archive
    if [ -L "$UHD_LOCK" ]; then printf 'STOP: the preparation lock is a link; preserved.\n'; return 1; fi
    if [ -d "$UHD_LOCK" ]; then
        # The lock is an empty directory with no owner record; it is stale only
        # when no UHD770 helper that takes it is still running.
        if pgrep -f 'session\.sh|manage\.sh|Archive-UHD770-Failed' >/dev/null; then
            printf 'STOP: another UHD770 preparation or test is still running.\n'; return 1
        fi
        rmdir "$UHD_LOCK" || { printf 'STOP: cannot remove the stale preparation lock.\n'; return 1; }
        printf 'cleanup: removed a stale preparation lock; no UHD770 helper was running\n'
    fi
    if [ -L "$UHD_ROOT" ]; then printf 'STOP: the earlier stage is a link; preserved.\n'; return 1; fi
    [ -e "$UHD_ROOT" ] || return 0
    [ ! -f "$UHD_ROOT/session-public/state.txt" ] || state=$(cat "$UHD_ROOT/session-public/state.txt")
    if [ -z "$state" ] && [ ! -e "$UHD_ROOT/session-private" ]; then
        # A stage without a session installed nothing. A complete stage of this
        # same package is reused by prepare; any other one is set aside whole.
        if cmp -s "$KIT/SHA256SUMS" "$UHD_ROOT/incoming/SHA256SUMS" &&
           grep -qx 'stage=offline-ready' "$UHD_ROOT/stage-state.txt" 2>/dev/null; then
            return 0
        fi
        archive=$(mktemp -d "$UHD_PARENT/UHD770MVP-retired.XXXXXX") && mv "$UHD_ROOT" "$archive/stage" ||
            { printf 'STOP: cannot set the earlier stage aside.\n'; return 1; }
        printf 'cleanup: earlier stage without a session moved to %s\n' "$archive"
        return 0
    fi
    printf 'cleanup: earlier session state=%s\n' "${state:-unknown}"
    case "$state" in
        failed) /bin/bash -p "$KIT/Archive-UHD770-Failed.command" ;;
        restored) /bin/bash -p "$KIT/Archive-UHD770-Failed.command" --restored-session ;;
        *) /bin/bash -p "$KIT/tools/session.sh" restore &&
           /bin/bash -p "$KIT/Archive-UHD770-Failed.command" --restored-session ;;
    esac
}

# The transcript goes only to the log; the terminal gets a minute counter and
# the outcome. The counter's sleep holds no inherited descriptor.
( m=0; while sleep 60 </dev/null >/dev/null 2>&1; do m=$((m + 1)); printf '  …已进行 %s 分钟\n' "$m"; done ) &
BEAT=$!
trap 'kill "$BEAT" 2>/dev/null || :' EXIT
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
    auto_clean || exit 1
    /bin/bash -p "$KIT/tools/session.sh" prepare
} 2>&1 | tee "$REPORT/prepare.txt" >/dev/null; then
    statuses=("${PIPESTATUS[@]}")
else
    statuses=("${PIPESTATUS[@]}")
fi
kill "$BEAT" 2>/dev/null || :
wait "$BEAT" 2>/dev/null || :
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
        fi
    fi
fi
logs=$REPORT
[ "$copied" -eq 0 ] || logs="$destination/${REPORT##*/}"
if [ "$code" -eq 0 ]; then
    printf '\nPREPARED：准备完成。\n下一步：用 1401 U 盘重启一次，进入 macOS 后在本目录运行\n  sudo /bin/bash -p ./Run-UHD770-Test.command\n'
else
    reason=$(grep '^STOP:' "$REPORT/prepare.txt" 2>/dev/null | tail -1 || :)
    reason=${reason#STOP: }
    printf '\nSTOPPED：%s\n不要为测试而重启。把这个日志文件夹带回来即可：\n  %s\n' \
        "${reason:-见日志（exit $code）}" "$logs" >&2
fi
exit "$code"
