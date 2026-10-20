#!/bin/bash
# Host fixture: source production supervision logic with mock read-only commands.
# This never calls capture_main, touches /Library, or installs a launchd job.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
FIXTURE_PARENT=${TMPDIR:-/tmp}
FIXTURE_PARENT=$(cd "$FIXTURE_PARENT" && pwd)
FIXTURE=$(mktemp -d "$FIXTURE_PARENT/uhd770-capture-fixture.XXXXXX")
case "$FIXTURE" in "$FIXTURE_PARENT"/uhd770-capture-fixture.*) ;; *) exit 1 ;; esac
[ -d "$FIXTURE" ] && [ ! -L "$FIXTURE" ] || exit 1
fixture_cleanup() {
    local status=$?
    if [ "$status" -eq 0 ]; then
        rm -rf -- "$FIXTURE"
    else
        printf 'Fixture failed; evidence retained at %s\n' "$FIXTURE" >&2
    fi
}
trap fixture_cleanup EXIT
mkdir "$FIXTURE/mock" "$FIXTURE/reports"
export FIXTURE HERE

cat > "$FIXTURE/mock/mock" <<'MOCK'
#!/bin/bash
printf '%s\n' "$0 $*" >> "$FIXTURE/invocations.txt"
case "${0##*/}" in
    date) printf '2026-10-20T04:00:00Z\n' ;;
    sysctl) printf 'kern.bootsessionuuid: FIXTURE-BOOT-UUID\nkern.boottime: { sec = 1 }\n' ;;
    sw_vers) printf 'ProductVersion: 15.7.9\n' ;;
    sync) : ;;
    dmesg) printf 'i915 fixture kernel ring\n' ;;
    ioreg) printf 'fixture registry %s\n' "$*" ;;
    log) printf 'fixture refuses stream startup\n'; exit 42 ;;
    hang) trap '' TERM; exec /bin/sleep 30 ;;
    sleep)
        case "$1" in 0.1) exec /bin/sleep 0.01 ;; 1) exec /bin/sleep 0.02 ;; *) exec /bin/sleep "$@" ;; esac
        ;;
    *) exit 91 ;;
esac
MOCK
chmod 700 "$FIXTURE/mock/mock"
for cmd in date sysctl sw_vers sync dmesg ioreg log hang sleep; do
    cp "$FIXTURE/mock/mock" "$FIXTURE/mock/$cmd"
done

cat > "$FIXTURE/run-one.sh" <<'RUN'
#!/bin/bash
set -u
source "$HERE/collector.sh"
capture_configure
# Git Bash cannot set RLIMIT_FSIZE. The fixture replaces only this shell builtin;
# production fails closed if the real macOS limit cannot be applied.
ulimit() { return 0; }
umask 077
CAPTURE_ROOT="$FIXTURE/reports"
CAPTURE_DURATION=6
C_DATE="$FIXTURE/mock/date"
C_SYSCTL="$FIXTURE/mock/sysctl"
C_SWVERS="$FIXTURE/mock/sw_vers"
C_SLEEP="$FIXTURE/mock/sleep"
C_SYNC="$FIXTURE/mock/sync"
C_LOG="$FIXTURE/mock/log"
C_DMESG="$FIXTURE/mock/dmesg"
C_IOREG="$FIXTURE/mock/ioreg"
if [ "${1:-}" = deadline ]; then
    CAPTURE_ROOT="$FIXTURE/deadline-reports"
    CAPTURE_DURATION=2
    C_SYSCTL="$FIXTURE/mock/hang"
    C_SLEEP=/bin/sleep
fi
capture_run
RUN
/bin/bash -n "$HERE/collector.sh"
/bin/bash -n "$HERE/test_capture.sh"
/bin/bash "$FIXTURE/run-one.sh"
/bin/bash "$FIXTURE/run-one.sh"

reports=0
for report in "$FIXTURE/reports"/session-*; do
    [ -d "$report" ] || { printf 'FAIL no report\n'; exit 1; }
    reports=$((reports + 1))
    grep -q 'collector_start .*gpu_executed=false' "$report/stages.txt"
    grep -q 'collector_end reason=duration_complete' "$report/stages.txt"
    grep -q 'stage=kernel-stream startup_failed status=42' "$report/stages.txt"
    grep -q 'FIXTURE-BOOT-UUID' "$report/boot-identity.txt"
    grep -q '2026-10-20T04:00:00Z' "$report/stages.txt"
    grep -q 'fixture registry -r -c NMXGPU -l -w0' "$report/ioreg-NMXGPU-0.txt"
    grep -q 'i915 fixture kernel ring' "$report/dmesg-0.txt"
    # Stage begin must precede both successful query data and completion marker.
    awk '/stage=dmesg-0 begin/ { b=NR } /stage=dmesg-0 end status=0/ { e=NR } END { exit !(b && e && b<e) }' "$report/stages.txt"
done
[ "$reports" -eq 2 ]

# Exercise the whole-collector watchdog while a metadata query is still stuck.
# This reduced duration is test-only; production CLI validation still requires
# 120..600 seconds and cannot select these mock commands or paths.
mkdir "$FIXTURE/deadline-reports"
started=$SECONDS
/bin/bash "$FIXTURE/run-one.sh" deadline
[ $((SECONDS - started)) -lt 8 ]
for report in "$FIXTURE/deadline-reports"/session-*; do
    grep -q 'stage=boot-identity begin' "$report/stages.txt"
    grep -q 'collector_end reason=deadline_or_termination' "$report/stages.txt"
done

# An ignoring-TERM child must time out, be killed, and leave a finite result.
source "$HERE/collector.sh"
capture_configure
ulimit() { return 0; }
C_SLEEP="$FIXTURE/mock/sleep"
status=0
capture_bounded 1 "$FIXTURE/timeout.txt" "$FIXTURE/mock/hang" || status=$?
[ "$status" -eq 124 ] && [ "$LAST_STATUS" -eq 124 ]
[ -z "$QUERY_PID" ]

# Snapshot failures remain visible; the following marker is still writable.
REPORT="$FIXTURE/reports/failed-query"
mkdir "$REPORT"
C_SYNC="$FIXTURE/mock/sync"
LAST_UTC=fixture
capture_snapshot failed 1 "$FIXTURE/mock/hang" && exit 1
grep -q 'stage=failed begin' "$REPORT/stages.txt"
grep -q 'stage=failed end status=124' "$REPORT/stages.txt"
grep -q 'collector_command_exit=124' "$REPORT/failed.txt"

# No fixture substituted command may receive activation or all-tree queries.
if grep -E 'load|bootstrap|nvram|system_profiler|log collect|ioreg -l' "$FIXTURE/invocations.txt"; then
    printf 'FAIL forbidden invocation\n'
    exit 1
fi
printf 'PASS capture: independent reports, finite children/collector, startup failures, staged snapshots, no activation\n'
