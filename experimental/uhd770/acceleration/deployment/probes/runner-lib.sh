#!/bin/bash
# Shared, inert lifecycle helpers. Sourcing this file never opens a GPU. The
# installed entry point performs platform/ownership/UUID gates before calling
# these helpers; fixture tests exercise only fake child processes.

# Run one explicitly selected child with a disk marker written before launch.
# Arguments: private session directory, exact success-marker prefix, outer
# deadline in seconds, command and its arguments. Both exit 0 AND the marker
# are required. The child diagnostic supplies its own shorter API deadline.
uhd_run_bounded() (
    set -u
    local session=$1 marker=$2 limit=$3
    shift 3
    local child= watcher= follower= flusher= code=0 outer=$$
    # $$ identifies the entry point in production; BASHPID is absent in Bash3.2.
    # Use a subshell-specific PID obtained without opening any driver.
    outer=$( /bin/sh -c 'echo "$PPID"' )
    local stop="$session/watchdog.stop" log="$session/probe.log"
    : > "$log" || exit 74

    uhd_stop_helpers() {
        : > "$stop"
        [ -z "$watcher" ] || kill "$watcher" 2>/dev/null || :
        [ -z "$follower" ] || kill "$follower" 2>/dev/null || :
        [ -z "$flusher" ] || kill "$flusher" 2>/dev/null || :
    }
    uhd_interrupted() {
        local reason=130
        [ ! -f "$session/outer-timeout.marker" ] || reason=124
        [ -z "$child" ] || kill -TERM "$child" 2>/dev/null || :
        uhd_stop_helpers
        printf 'state=interrupted\nrunner_exit=%s\n' "$reason" > "$session/result.txt"
        sync
        exit "$reason"
    }
    trap uhd_interrupted INT TERM HUP
    trap uhd_stop_helpers EXIT

    printf 'PROBE_START\nstarted_utc=%s\nouter_deadline_s=%s\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$limit" > "$session/probe-start.marker" || exit 74
    sync || exit 74
    "$@" > "$log" 2>&1 &
    child=$!
    printf 'probe_pid=%s\n' "$child" > "$session/probe-pid.txt"
    # The log is written directly by the unbuffered diagnostic, never through a
    # pipe whose unread buffer could lose the final visible messages.
    tail -n +1 -F "$log" &
    follower=$!
    # Disk flushes have their own helper so a slow sync never postpones the
    # parent's deadline. A kernel/filesystem hang is outside user-space recovery.
    (while :; do sleep 2; [ ! -f "$stop" ] || exit 0; sync; done) &
    flusher=$!
    (
        local elapsed=0
        while [ "$elapsed" -lt "$limit" ]; do
            sleep 1
            [ ! -f "$stop" ] || exit 0
            kill -0 "$child" 2>/dev/null || exit 0
            elapsed=$((elapsed + 1))
        done
        [ ! -f "$stop" ] || exit 0
        printf 'OUTER_TIMEOUT\ndeadline_s=%s\n' "$limit" > "$session/outer-timeout.marker"
        kill -TERM "$child" 2>/dev/null || :
        sleep 2
        [ ! -f "$stop" ] || exit 0
        kill -KILL "$child" 2>/dev/null || :
        # If a kernel-blocked child cannot be reaped, release the waiting shell
        # too. User-space deadlines cannot recover a wedged kernel or display.
        kill -TERM "$outer" 2>/dev/null || :
    ) &
    watcher=$!
    wait "$child" || code=$?
    uhd_stop_helpers
    if [ -f "$session/outer-timeout.marker" ]; then code=124; fi
    if [ "$code" -eq 0 ] && grep -Eq "^${marker}:" "$log"; then
        printf 'state=verified-readback\nprobe_exit=0\nrunner_exit=0\nmarker=%s\n' "$marker" > "$session/result.txt"
    else
        [ "$code" -ne 0 ] || code=65
        printf 'state=failed\nrunner_exit=%s\nrequired_marker=%s\n' "$code" "$marker" > "$session/result.txt"
    fi
    sync
    printf 'Session: %s\n' "$session"
    cat "$session/result.txt"
    exit "$code"
)

# Extract the native little-endian x86_64 Mach-O LC_UUID without Xcode tools.
# Input is an already ownership-checked regular file. The returned lowercase
# UUID has no punctuation, matching the normalized kextstat identity.
uhd_macho_uuid() {
    local image=$1 words ncmds bytes offset=32 index=0 command size
    words=$(od -An -tu4 -N8 "$image") || return 1
    set -- $words
    [ "$#" -eq 2 ] && [ "$1" = 4277009103 ] && [ "$2" = 16777223 ] || return 1
    words=$(od -An -tu4 -N8 -j16 "$image") || return 1
    set -- $words
    [ "$#" -eq 2 ] || return 1
    ncmds=$1 bytes=$2
    [ "$ncmds" -gt 0 ] && [ "$ncmds" -le 4096 ] && [ "$bytes" -le 16777216 ] || return 1
    while [ "$index" -lt "$ncmds" ]; do
        words=$(od -An -tu4 -N8 -j"$offset" "$image") || return 1
        set -- $words
        [ "$#" -eq 2 ] || return 1
        command=$1 size=$2
        [ "$size" -ge 8 ] && [ $((offset + size)) -le $((32 + bytes)) ] || return 1
        if [ "$command" -eq 27 ]; then
            [ "$size" -eq 24 ] || return 1
            od -An -v -tx1 -N16 -j$((offset + 8)) "$image" | tr -d ' \n'
            return
        fi
        offset=$((offset + size)) index=$((index + 1))
    done
    return 1
}
