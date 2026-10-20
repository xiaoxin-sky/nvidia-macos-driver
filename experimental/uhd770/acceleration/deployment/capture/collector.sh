#!/bin/bash
# Boot-time, read-only evidence capture for the UHD770 application MVP.
# launchd owns this process group. The collector never opens a GPU user client,
# changes a boot option, loads a driver, or submits GPU/Metal work. Functions
# are sourceable solely so the host fixture can substitute harmless commands.

capture_configure() {
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    CAPTURE_ROOT='/private/var/log/UHD770MVP'
    CAPTURE_DURATION=300
    C_MKDIR=/bin/mkdir
    C_RMDIR=/bin/rmdir
    C_RM=/bin/rm
    C_STAT=/usr/bin/stat
    C_DATE=/bin/date
    C_SYSCTL=/usr/sbin/sysctl
    C_SWVERS=/usr/bin/sw_vers
    C_SLEEP=/bin/sleep
    C_SYNC=/bin/sync
    C_LOG=/usr/bin/log
    C_DMESG=/sbin/dmesg
    C_IOREG=/usr/sbin/ioreg
    CAPTURE_FINISH_BUDGET=10
    QUERY_PID=''
    STREAM_PID=''
    WATCHDOG_PID=''
    FINISH_WATCHDOG_PID=''
    REPORT=''
    BOOTSTRAP=''
    LAST_UTC=unknown
    LAST_STATUS=0
    END_REASON=completed
    STOPPING=0
}

# Run a single child with a finite poll budget. A stalled command is signalled
# and detached rather than waited on indefinitely. launchd's default process
# group cleanup is intentionally retained in the supplied plist.
capture_bounded() {
    local limit="$1" output="$2" ticks=0 max_ticks status
    shift 2
    max_ticks=$((limit * 10))
    (ulimit -f 4096 || exit 125; exec "$@") > "$output" 2>&1 &
    QUERY_PID=$!
    while kill -0 "$QUERY_PID" 2>/dev/null && [ "$ticks" -lt "$max_ticks" ]; do
        "$C_SLEEP" 0.1
        ticks=$((ticks + 1))
    done
    if kill -0 "$QUERY_PID" 2>/dev/null; then
        kill -TERM "$QUERY_PID" 2>/dev/null || :
        "$C_SLEEP" 0.1
        kill -KILL "$QUERY_PID" 2>/dev/null || :
        disown "$QUERY_PID" 2>/dev/null || :
        QUERY_PID=''
        LAST_STATUS=124
        return 124
    fi
    wait "$QUERY_PID"
    status=$?
    QUERY_PID=''
    LAST_STATUS="$status"
    return "$status"
}

capture_clock() {
    if capture_bounded 1 "$REPORT/clock.pending" "$C_DATE" -u '+%Y-%m-%dT%H:%M:%SZ'; then
        IFS= read -r LAST_UTC < "$REPORT/clock.pending" || LAST_UTC=unknown
    fi
}

# A marker is written before each possibly stalled read. sync itself is bounded;
# a sync timeout stays visible and is not represented as guaranteed persistence.
capture_marker() {
    printf 'utc_last=%s elapsed_s=%s %s\n' "$LAST_UTC" "$SECONDS" "$*" >> "$REPORT/stages.txt"
    if ! capture_bounded 1 "$REPORT/sync-status.txt" "$C_SYNC"; then
        printf 'utc_last=%s elapsed_s=%s sync_failed status=%s\n' "$LAST_UTC" "$SECONDS" "$LAST_STATUS" >> "$REPORT/stages.txt"
    fi
}

capture_snapshot() {
    local name="$1" limit="$2" status
    shift 2
    capture_marker "stage=$name begin"
    capture_bounded "$limit" "$REPORT/$name.txt" "$@"
    status=$?
    printf '\ncollector_command_exit=%s\n' "$status" >> "$REPORT/$name.txt"
    capture_marker "stage=$name end status=$status"
    return "$status"
}

capture_stop_child() {
    local child="$1"
    [ -n "$child" ] || return 0
    kill -TERM "$child" 2>/dev/null || :
    "$C_SLEEP" 0.1
    kill -KILL "$child" 2>/dev/null || :
    disown "$child" 2>/dev/null || :
}

# Keep cleanup independently finite after replacing the collection watchdog.
# This runs in its own child so a blocked write/read in the parent cannot turn
# off the final hard bound. launchd retains process-group cleanup on parent exit.
capture_finish_guard() {
    local owner=$1 budget=$2 timer_pid=''
    trap - EXIT
    trap '[ -z "$timer_pid" ] || kill -TERM "$timer_pid" 2>/dev/null || :; exit 0' TERM INT HUP
    "$C_SLEEP" "$budget" &
    timer_pid=$!
    wait "$timer_pid" || return 0
    timer_pid=''
    kill -KILL "$owner" 2>/dev/null || :
}

capture_finish() {
    # Natural completion and the collection deadline can coincide. Restoring
    # TERM to its default here previously let that deadline kill normal cleanup
    # before collector_end was written. Ignore repeat signals while a separate
    # hard guard bounds this one cleanup attempt.
    trap '' INT TERM HUP
    trap - EXIT
    [ "$STOPPING" -eq 0 ] || return 0
    STOPPING=1
    capture_finish_guard "$$" "$CAPTURE_FINISH_BUDGET" &
    FINISH_WATCHDOG_PID=$!
    capture_stop_child "$WATCHDOG_PID"
    WATCHDOG_PID=''
    capture_stop_child "$QUERY_PID"
    QUERY_PID=''
    capture_stop_child "$STREAM_PID"
    STREAM_PID=''
    if [ -n "$REPORT" ]; then
        capture_clock
        capture_marker "collector_end reason=$END_REASON gpu_executed=false"
    fi
    capture_stop_child "$FINISH_WATCHDOG_PID"
    FINISH_WATCHDOG_PID=''
}

# Called only after root-owned log storage has passed validation. The watchdog
# provides a second bound independent of wall-clock changes and query outcomes.
capture_run() {
    local session="session-$$-$RANDOM-$RANDOM" count=0 next_snapshot=0
    local gpu_ok=1 accel_ok=1 dmesg_ok=1 stream_reported=0 stream_alive
    local owner_pid="$$"
    SECONDS=0
    capture_bounded 2 /dev/null "$C_MKDIR" -m 700 "$CAPTURE_ROOT/$session" || return 1
    REPORT="$CAPTURE_ROOT/$session"
    trap 'END_REASON=interrupted; capture_finish; exit 130' INT HUP
    trap 'END_REASON=deadline_or_termination; capture_finish; exit 0' TERM
    trap capture_finish EXIT
    (
        timer_pid=''
        trap '[ -z "$timer_pid" ] || kill -TERM "$timer_pid" 2>/dev/null || :; exit 0' TERM INT HUP
        "$C_SLEEP" "$CAPTURE_DURATION" &
        timer_pid=$!
        wait "$timer_pid" || exit 0
        timer_pid=''
        kill -TERM "$owner_pid" 2>/dev/null || exit 0
        "$C_SLEEP" 3 &
        timer_pid=$!
        wait "$timer_pid" || exit 0
        kill -KILL "$owner_pid" 2>/dev/null || :
    ) &
    WATCHDOG_PID=$!
    capture_marker "collector_start session=$session duration_s=$CAPTURE_DURATION gpu_executed=false"
    capture_clock
    capture_snapshot boot-identity 2 "$C_SYSCTL" kern.bootsessionuuid kern.boottime || :
    capture_snapshot macos-version 2 "$C_SWVERS" || :
    # No boot arguments, serial numbers, user directories, network listeners, or
    # full IORegistry/system_profiler dumps are needed for this narrow capture.
    capture_marker 'stage=kernel-stream begin'
    (
        ulimit -f 16384 || exit 125
        exec "$C_LOG" stream --level debug --style compact --predicate \
            'process == "kernel" AND (eventMessage CONTAINS[c] "NMXGPU" OR eventMessage CONTAINS[c] "NMXAccel" OR eventMessage CONTAINS[c] "NullMoth" OR eventMessage CONTAINS[c] "i915" OR eventMessage CONTAINS[c] "drm" OR eventMessage CONTAINS[c] "UHD770")'
    ) > "$REPORT/kernel-stream.txt" 2>&1 &
    STREAM_PID=$!
    "$C_SLEEP" 0.1
    if ! kill -0 "$STREAM_PID" 2>/dev/null; then
        wait "$STREAM_PID"
        capture_marker "stage=kernel-stream startup_failed status=$?"
        stream_reported=1
    fi
    while [ "$SECONDS" -lt "$CAPTURE_DURATION" ] && [ "$count" -lt "$CAPTURE_DURATION" ]; do
        capture_clock
        stream_alive=0
        kill -0 "$STREAM_PID" 2>/dev/null && stream_alive=1
        if [ "$stream_alive" -eq 0 ] && [ "$stream_reported" -eq 0 ]; then
            capture_marker 'stage=kernel-stream exited; partial_output_retained=true'
            stream_reported=1
        fi
        if [ $((count % 5)) -eq 0 ]; then
            capture_marker "heartbeat stream_alive=$stream_alive"
        fi
        if [ "$SECONDS" -ge "$next_snapshot" ]; then
            if [ "$dmesg_ok" -eq 1 ]; then
                capture_snapshot "dmesg-$count" 3 "$C_DMESG" || dmesg_ok=0
            fi
            if [ "$gpu_ok" -eq 1 ]; then
                capture_snapshot "ioreg-NMXGPU-$count" 3 "$C_IOREG" -r -c NMXGPU -l -w0 || gpu_ok=0
            fi
            if [ "$accel_ok" -eq 1 ]; then
                capture_snapshot "ioreg-NMXAccel-$count" 3 "$C_IOREG" -r -c NMXAccel -l -w0 || accel_ok=0
            fi
            next_snapshot=$((SECONDS + 20))
        fi
        count=$((count + 1))
        "$C_SLEEP" 1
    done
    END_REASON=duration_complete
    capture_finish
    return 0
}

capture_startup_fail() {
    printf 'capture_startup_failed stage=%s elapsed_s=%s\n' "$1" "$SECONDS" >&2
    return 1
}

# Validate every existing ancestor before creating a report. Private bootstrap
# storage is atomically created without -p; collisions or symlinks fail closed.
# BSD stat output is read from a bounded command, never evaluated as shell code.
capture_validate_storage() {
    local path meta uid mode
    BOOTSTRAP="/private/tmp/uhd770-capture-$$-$RANDOM-$RANDOM"
    capture_bounded 2 /dev/null "$C_MKDIR" -m 700 "$BOOTSTRAP" || { capture_startup_fail bootstrap; return 1; }
    for path in /private /private/var /private/var/log "$CAPTURE_ROOT"; do
        if [ -L "$path" ] || [ ! -d "$path" ]; then
            capture_startup_fail storage_path
            return 1
        fi
        capture_bounded 2 "$BOOTSTRAP/stat.txt" "$C_STAT" -f '%u %Lp' "$path" || { capture_startup_fail storage_stat; return 1; }
        IFS=' ' read -r uid mode < "$BOOTSTRAP/stat.txt" || { capture_startup_fail storage_metadata; return 1; }
        case "$uid:$mode" in *[!0-7:]*|:*|*:) capture_startup_fail storage_metadata; return 1 ;; esac
        if [ "$uid" != 0 ] || [ $((8#$mode & 0022)) -ne 0 ]; then
            capture_startup_fail storage_permissions
            return 1
        fi
    done
    capture_bounded 2 /dev/null "$C_RM" -f "$BOOTSTRAP/stat.txt" || :
    capture_bounded 2 /dev/null "$C_RMDIR" "$BOOTSTRAP" || :
    BOOTSTRAP=''
    return 0
}

capture_main() {
    capture_configure
    umask 077
    case "${OSTYPE:-}" in darwin*) ;; *) capture_startup_fail requires_macos; return 1 ;; esac
    [ "$EUID" -eq 0 ] || { capture_startup_fail requires_root; return 1; }
    if [ "$#" -eq 2 ] && [ "$1" = --duration ]; then
        case "$2" in ''|*[!0-9]*) capture_startup_fail duration; return 1 ;; esac
        [ "${#2}" -le 3 ] || { capture_startup_fail duration; return 1; }
        CAPTURE_DURATION=$((10#$2))
        [ "$CAPTURE_DURATION" -ge 120 ] && [ "$CAPTURE_DURATION" -le 600 ] || { capture_startup_fail duration; return 1; }
    elif [ "$#" -ne 0 ]; then
        capture_startup_fail arguments
        return 1
    fi
    capture_validate_storage || return 1
    capture_run || { capture_startup_fail report_creation; return 1; }
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -u
    capture_main "$@"
fi
