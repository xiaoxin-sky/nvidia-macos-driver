#!/bin/bash -p
# Native launchd stop regression. Only unique fixture labels and a private
# temporary heartbeat script are registered. No production service, /Library
# registration, boot option, driver client or GPU command is used.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
if [ "$(uname -s)" != Darwin ]; then
    printf 'SKIP native recorder stop: Darwin launchd is unavailable; no macOS service validation claimed.\n'
    exit 0
fi
[ "$EUID" -eq 0 ] || { printf 'Use sudo /bin/bash -p for the native recorder fixture.\n' >&2; exit 64; }
HERE=$(cd "$(dirname "$0")" && pwd -P)
. "$HERE/session-lib.sh"
type session_stop_recorder >/dev/null 2>&1 || { printf 'Missing production session_stop_recorder helper.\n' >&2; exit 1; }
PARENT=$(cd "${TMPDIR:-/private/tmp}" && pwd -P)
FIXTURE=$(mktemp -d "$PARENT/uhd770-native-recorder.XXXXXX")
case "$FIXTURE" in "$PARENT"/uhd770-native-recorder.*) ;; *) exit 1 ;; esac
BASE_LABEL="com.uhd770.mvp.capture.fixture.$$.$RANDOM.$RANDOM"
PHASES='normal slow absent orphan mismatch'

cleanup() {
    local code=$? phase label stopped=1
    trap - EXIT INT TERM HUP
    set +e
    # This namespace is constructed here, never read from a report or plist.
    # Cleanup can signal only our own temporary launchd label, never a PID or
    # the production recorder. Keep every native diagnostic for inspection.
    for phase in $PHASES; do
        label="$BASE_LABEL.$phase"
        case "$label" in com.uhd770.mvp.capture.fixture.*) ;; *) stopped=0; continue ;; esac
        [ -d "$FIXTURE/$phase" ] || continue
        session_bounded 8 "$FIXTURE/$phase/cleanup-bootout.txt" launchctl bootout "system/$label" || :
        if launchctl print "system/$label" > "$FIXTURE/$phase/cleanup-state.txt" 2>&1; then
            session_bounded 3 "$FIXTURE/$phase/cleanup-kill.txt" launchctl kill SIGKILL "system/$label" || :
            session_bounded 8 "$FIXTURE/$phase/cleanup-retry.txt" launchctl bootout "system/$label" || :
        fi
        if launchctl print "system/$label" >> "$FIXTURE/$phase/cleanup-state.txt" 2>&1; then stopped=0; fi
    done
    [ "$stopped" -eq 1 ] || code=1
    printf 'Native recorder evidence retained: %s\n' "$FIXTURE"
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
launchctl print system > "$FIXTURE/system-domain.txt"

for phase in $PHASES; do
    current="$FIXTURE/$phase"
    label="$BASE_LABEL.$phase"
    plist="$current/job.plist"
    # A literal space exercises the same argument boundary as Application Support.
    script="$current/heartbeat collector.sh"
    report="$current/stop-report"
    stage="$current/private-stage"
    archive="$current/retired-stage"
    mkdir -m 700 "$current" "$report" "$stage"
    printf '%s\n' "$phase" > "$current/mode"
    printf 'preserve stage until confirmed stop\n' > "$stage/evidence.txt"
    cat > "$script" <<'DUMMY'
#!/bin/bash -p
set -eu
base=$(cd "$(dirname "$0")" && pwd -P)
finish() {
    trap - TERM INT HUP
    printf 'TERM received\n' >> "$base/heartbeat-events.txt"
    [ "$(cat "$base/mode")" = orphan ] || [ -f "$base/job.plist" ] || printf 'plist removed before termination\n' > "$base/early-delete.txt"
    if [ "$(cat "$base/mode")" = slow ]; then /bin/sleep 2; fi
    [ "$(cat "$base/mode")" = orphan ] || [ -f "$base/job.plist" ] || printf 'plist removed before termination\n' > "$base/early-delete.txt"
    printf 'dummy stopped\n' >> "$base/heartbeat-events.txt"
    exit 0
}
trap finish TERM INT HUP
printf '%s\n' "$$" > "$base/dummy.pid"
while :; do printf 'heartbeat\n' >> "$base/heartbeat.txt"; /bin/sleep 0.2; done
DUMMY
    chmod 700 "$script"
    script_xml=$(printf '%s' "$script" | sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
    cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>-p</string><string>$script_xml</string></array>
<key>RunAtLoad</key><true/><key>KeepAlive</key><false/>
<key>ExitTimeOut</key><integer>10</integer>
</dict></plist>
PLIST
    chmod 600 "$plist"
    plutil -lint "$plist" > "$current/plist-validation.txt"
    pid=''
    if [ "$phase" != absent ]; then
        session_bounded 10 "$current/bootstrap.txt" launchctl bootstrap system "$plist"
        ticks=0
        while [ ! -s "$current/dummy.pid" ] && [ "$ticks" -lt 80 ]; do /bin/sleep 0.1; ticks=$((ticks + 1)); done
        [ -s "$current/dummy.pid" ] || { printf 'FAIL %s: fixture heartbeat did not start.\n' "$phase" >&2; exit 1; }
        pid=$(cat "$current/dummy.pid")
        case "$pid" in ''|*[!0-9]*) exit 1 ;; esac
        ps -p "$pid" -o pid=,command= > "$current/process-before.txt"
    fi
    # Model an earlier remover that deleted its plist before launchd actually
    # stopped the service. The helper must validate live registered arguments.
    if [ "$phase" = orphan ]; then rm "$plist"; fi
    expected="$script"
    if [ "$phase" = mismatch ]; then
        expected="$current/different-script.sh"
        printf '#!/bin/bash\nexit 0\n' > "$expected"
        chmod 700 "$expected"
    fi
    started=$SECONDS
    code=0
    session_stop_recorder "$label" "$plist" "$expected" "$report" > "$current/helper-output.txt" 2>&1 || code=$?
    elapsed=$((SECONDS - started))
    printf 'phase=%s\nlabel=%s\noriginal_pid=%s\nhelper_exit=%s\nelapsed_seconds=%s\n' \
        "$phase" "$label" "$pid" "$code" "$elapsed" > "$current/case-result.txt"
    # Model only the caller's final same-filesystem archive gate. The actual
    # Archive entry point has separate redirected integration fixtures.
    if [ "$code" -eq 0 ]; then mv "$stage" "$archive"; fi
    if [ "$phase" = mismatch ]; then
        [ "$code" -ne 0 ] && [ -f "$plist" ] && [ -d "$stage" ] && [ ! -e "$archive" ]
        launchctl print "system/$label" > "$current/protected-service.txt"
        ps -p "$pid" -o command= > "$current/protected-process.txt"
        grep -Fq "$script" "$current/protected-process.txt"
        printf 'PASS native recorder mismatch: service, plist and stage preserved; exit=%s.\n' "$code"
    else
        [ "$code" -eq 0 ] && [ ! -e "$plist" ] && [ ! -L "$plist" ] && [ -d "$archive" ] && [ ! -e "$stage" ]
        if launchctl print "system/$label" > "$current/service-after.txt" 2>&1; then exit 1; fi
        [ ! -f "$current/early-delete.txt" ]
        if [ -n "$pid" ]; then
            ps -p "$pid" -o command= > "$current/process-after.txt" 2>/dev/null || :
            if grep -Fq "$script" "$current/process-after.txt"; then exit 1; fi
            grep -Fq 'dummy stopped' "$current/heartbeat-events.txt"
        fi
        if [ "$phase" = slow ]; then [ "$elapsed" -ge 2 ] && [ "$elapsed" -lt 30 ]; fi
        printf 'PASS native recorder %s: stop confirmed before plist removal/archive; exit=0 elapsed=%s.\n' "$phase" "$elapsed"
    fi
done
printf 'PASS native recorder: unique temporary launchd services only; no production recorder, EFI or GPU accessed.\n'
