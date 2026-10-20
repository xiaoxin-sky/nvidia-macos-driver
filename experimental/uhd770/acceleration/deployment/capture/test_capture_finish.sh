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
if [ "$MODE" = natural ]; then CAPTURE_DURATION=30; fi
CAPTURE_FINISH_BUDGET=3
if [ "$MODE" != finish-hung ]; then CAPTURE_FINISH_BUDGET=10; fi
C_DATE="$FIXTURE/mock/date"
C_SYNC="$FIXTURE/mock/sync"
C_SYSCTL="$FIXTURE/mock/sysctl"
C_SWVERS="$FIXTURE/mock/sw_vers"
C_LOG="$FIXTURE/mock/log"
C_DMESG="$FIXTURE/mock/dmesg"
C_IOREG="$FIXTURE/mock/ioreg"

# Natural completion gets a generous collection budget so process startup is
# not the trigger. An independent fixture sender injects an in-flight TERM only
# after real cleanup starts; production cannot disarm that sender. TERM-first
# retains its real two-second watchdog with a pending metadata read. Slow final
# polls/clock/sync still exercise the original cleanup race and hard guard.
fixture_sleep() {
    if [ "$1" = 0.1 ]; then
        if [ "$STOPPING" -eq 1 ]; then
            if [ ! -f "$FIXTURE/$MODE/finish-begun" ]; then
                printf 'finish_start\n' >> "$FIXTURE/$MODE/events.txt"
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
printf '%s\n' "$CAPTURE_DURATION" > "$FIXTURE/$MODE/collection-budget"
INJECTOR_PID=''
if [ "$MODE" = natural ]; then
    owner=$$
    (
        ticks=0
        while [ ! -s "$FIXTURE/$MODE/finish-begun" ] && [ "$ticks" -lt 1500 ]; do
            /bin/sleep 0.01; ticks=$((ticks + 1))
        done
        [ -s "$FIXTURE/$MODE/finish-begun" ] || exit 91
        /bin/sleep 0.05
        printf 'signal_send\n' >> "$FIXTURE/$MODE/events.txt"
        if kill -TERM "$owner"; then
            printf 'signal_exit=0\n' >> "$FIXTURE/$MODE/events.txt"
        else
            printf 'signal_exit=1\n' >> "$FIXTURE/$MODE/events.txt"
            exit 92
        fi
    ) &
    INJECTOR_PID=$!
fi
capture_run
if [ -n "$INJECTOR_PID" ]; then wait "$INJECTOR_PID" || exit 93; fi
printf 'collector_return\n' >> "$FIXTURE/$MODE/events.txt"
RUN

failed=0
for mode in natural term-first finish-hung; do
    mkdir -p "$FIXTURE/$mode/reports"
    started=$SECONDS
    # The natural case's outer fixture guard covers its 30-second collection
    # budget, 10-second production cleanup guard and five seconds of margin.
    # Other cases retain their existing 15-second fixture bound.
    outer_limit=15
    if [ "$mode" = natural ]; then outer_limit=$((30 + 10 + 5)); fi
    # Isolate and clean the fixture's entire harmless process tree even when
    # the old collector is killed before it can stop its own watchdog/stream.
    /usr/bin/perl -MPOSIX -e 'my $sid=POSIX::setsid(); die "setsid failed" unless defined($sid) && $sid>=0; exec @ARGV; die "exec failed";' \
        -- /bin/bash "$FIXTURE/run.sh" "$mode" > "$FIXTURE/$mode/console.txt" 2>&1 &
    child=$!
    ticks=0
    while kill -0 "$child" 2>/dev/null && [ "$ticks" -lt $((outer_limit * 10)) ]; do /bin/sleep 0.1; ticks=$((ticks + 1)); done
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
            ordered=0
            if awk '
                $0=="finish_start" { finish=NR; finishes++ }
                $0=="signal_send" { signal=NR; signals++ }
                $0=="signal_exit=0" { delivered=NR; deliveries++ }
                $0=="collector_return" { ended=NR; ends++ }
                END { exit !(finishes==1 && signals==1 && deliveries==1 && ends==1 && finish<signal && signal<delivered && delivered<ended) }
            ' "$FIXTURE/$mode/events.txt"; then ordered=1; fi
            began=$(cat "$FIXTURE/$mode/finish-begun")
            budget=$(cat "$FIXTURE/$mode/collection-budget")
            if [ "$code" -ne 0 ] || ! grep -q 'collector_end reason=duration_complete' "$report/stages.txt" ||
               [ "$began" -ge "$budget" ] || [ "$ordered" -ne 1 ]; then
                printf 'FAIL finish natural: exit=%s finish_begin=%s collection_budget=%s ordered=%s end_marker=%s elapsed=%s\n' "$code" "$began" "$budget" "$ordered" "$(grep -c collector_end "$report/stages.txt" || :)" "$elapsed"
                grep collector_end "$report/stages.txt" || :
                cat "$FIXTURE/$mode/events.txt"
                failed=1
            else printf 'PASS finish natural: finish_start < delivered TERM < collector_return; duration_complete exit=0 finish_begin=%s elapsed=%s\n' "$began" "$elapsed"; fi
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
