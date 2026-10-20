#!/bin/bash
# Exercise the real collector's natural/deadline cleanup under slow final reads.
# Only harmless commands and a temporary report root are substituted. The test
# source argument is optional so a preserved pre-fix collector can demonstrate
# the regression without changing production files or accessing any GPU/EFI.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
COLLECTOR=${1:-"$HERE/collector.sh"}
[ "$#" -le 1 ] && [ -f "$COLLECTOR" ] || exit 64
PARENT=$(cd "${TMPDIR:-/tmp}" && pwd)
FIXTURE=$(mktemp -d "$PARENT/uhd770-capture-finish.XXXXXX")
case "$FIXTURE" in "$PARENT"/uhd770-capture-finish.*) ;; *) exit 1 ;; esac
cleanup() {
    local code=$?
    if [ "$code" -eq 0 ]; then rm -rf -- "$FIXTURE"; else printf 'Finish fixture evidence: %s\n' "$FIXTURE" >&2; fi
}
trap cleanup EXIT
export FIXTURE COLLECTOR
mkdir "$FIXTURE/mock"
cat > "$FIXTURE/mock/read" <<'READ'
#!/bin/bash
case "${0##*/}" in
    date)
        if [ -f "$FIXTURE/$MODE/finish-begun" ]; then /bin/sleep 0.2; fi
        printf '2026-10-20T04:00:00Z\n'
        ;;
    sync)
        if [ -f "$FIXTURE/$MODE/finish-begun" ]; then /bin/sleep 0.2; fi
        ;;
    sysctl)
        if [ "$MODE" = term-first ]; then exec /bin/sleep 30; fi
        printf 'kern.bootsessionuuid: FIXTURE-BOOT-UUID\n'
        ;;
    log) exec /bin/sleep 30 ;;
    sw_vers) printf 'ProductVersion: 15.7.9\n' ;;
    dmesg) printf 'inert kernel snapshot\n' ;;
    ioreg) printf 'inert registry snapshot\n' ;;
    *) exit 91 ;;
esac
READ
chmod 700 "$FIXTURE/mock/read"
for name in date sync sysctl log sw_vers dmesg ioreg; do cp "$FIXTURE/mock/read" "$FIXTURE/mock/$name"; done

cat > "$FIXTURE/run.sh" <<'RUN'
#!/bin/bash
set -u
MODE=$1
export MODE
. "$COLLECTOR"
capture_configure
ulimit() { return 0; }
CAPTURE_ROOT="$FIXTURE/$MODE/reports"
CAPTURE_DURATION=2
CAPTURE_FINISH_BUDGET=3
if [ "$MODE" != finish-hung ]; then CAPTURE_FINISH_BUDGET=10; fi
C_DATE="$FIXTURE/mock/date"
C_SYNC="$FIXTURE/mock/sync"
C_SYSCTL="$FIXTURE/mock/sysctl"
C_SWVERS="$FIXTURE/mock/sw_vers"
C_LOG="$FIXTURE/mock/log"
C_DMESG="$FIXTURE/mock/dmesg"
C_IOREG="$FIXTURE/mock/ioreg"

# The original collection watchdog keeps its real two-second deadline. Fast
# ordinary reads let count-based natural completion start first. Cleanup polls
# then take 1.2 seconds each and final date/sync reads take 0.2 seconds, so
# cleanup necessarily crosses that original deadline. In the TERM-first case
# the metadata read is still pending when the real watchdog interrupts it.
fixture_sleep() {
    if [ "$1" = 0.1 ]; then
        if [ "$STOPPING" -eq 1 ]; then
            if [ ! -f "$FIXTURE/$MODE/finish-begun" ]; then
                printf '%s\n' "$SECONDS" > "$FIXTURE/$MODE/finish-begun"
            fi
            if [ "$MODE" = finish-hung ]; then /bin/sleep 30; else /bin/sleep 1.2; fi
        elif [ "$MODE" = term-first ]; then
            /bin/sleep 0.1
        else
            /bin/sleep 0.01
        fi
    elif [ "$1" = 1 ]; then
        /bin/sleep 0.01
    else
        /bin/sleep "$@"
    fi
}
C_SLEEP=fixture_sleep
capture_run
RUN

failed=0
for mode in natural term-first finish-hung; do
    mkdir -p "$FIXTURE/$mode/reports"
    started=$SECONDS
    # Isolate and clean the fixture's entire harmless process tree even when
    # the old collector is killed before it can stop its own watchdog/stream.
    /usr/bin/perl -MPOSIX -e 'my $sid=POSIX::setsid(); die "setsid failed" unless defined($sid) && $sid>=0; exec @ARGV; die "exec failed";' \
        -- /bin/bash "$FIXTURE/run.sh" "$mode" > "$FIXTURE/$mode/console.txt" 2>&1 &
    child=$!
    ticks=0
    while kill -0 "$child" 2>/dev/null && [ "$ticks" -lt 150 ]; do /bin/sleep 0.1; ticks=$((ticks + 1)); done
    if kill -0 "$child" 2>/dev/null; then
        kill -KILL -- "-$child" 2>/dev/null || :
        code=124
        wait "$child" 2>/dev/null || :
    else
        code=0
        wait "$child" 2>/dev/null || code=$?
    fi
    kill -TERM -- "-$child" 2>/dev/null || :
    /bin/sleep 0.1
    kill -KILL -- "-$child" 2>/dev/null || :
    elapsed=$((SECONDS - started))
    report=''
    for candidate in "$FIXTURE/$mode/reports"/session-*; do [ ! -d "$candidate" ] || report=$candidate; done
    if [ -z "$report" ] || [ ! -f "$FIXTURE/$mode/finish-begun" ]; then
        printf 'FAIL finish %s: no real cleanup start; exit=%s elapsed=%s\n' "$mode" "$code" "$elapsed"
        failed=1
        continue
    fi
    case "$mode" in
        natural)
            if [ "$code" -ne 0 ] || ! grep -q 'collector_end reason=duration_complete' "$report/stages.txt" ||
               [ "$(cat "$FIXTURE/$mode/finish-begun")" -ge 2 ]; then
                printf 'FAIL finish natural: exit=%s end_marker=%s elapsed=%s\n' "$code" "$(grep -c collector_end "$report/stages.txt" || :)" "$elapsed"
                failed=1
            else printf 'PASS finish natural: cleanup crosses collection deadline; exit=0 elapsed=%s\n' "$elapsed"; fi
            ;;
        term-first)
            if [ "$code" -ne 0 ] || ! grep -q 'collector_end reason=deadline_or_termination' "$report/stages.txt"; then
                printf 'FAIL finish TERM-first: exit=%s end_marker=%s elapsed=%s\n' "$code" "$(grep -c collector_end "$report/stages.txt" || :)" "$elapsed"
                failed=1
            else printf 'PASS finish TERM-first: slow final clock/sync remain recorded; exit=0 elapsed=%s\n' "$elapsed"; fi
            ;;
        finish-hung)
            if [ "$code" -ne 137 ] || [ "$elapsed" -gt 7 ] || [ "$elapsed" -lt 3 ]; then
                printf 'FAIL finish hard guard: exit=%s elapsed=%s\n' "$code" "$elapsed"
                failed=1
            else printf 'PASS finish hard guard: stalled cleanup remains bounded; exit=137 elapsed=%s\n' "$elapsed"; fi
            ;;
    esac
    kill -0 "$$"
done
[ "$failed" -eq 0 ]
