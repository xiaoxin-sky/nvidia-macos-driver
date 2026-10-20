#!/bin/bash
# Inert helpers shared by the single-session installer and its host fixtures.
# Callers supply protected storage and exact destinations; sourcing never reads
# a device, edits EFI, installs a kext or starts a GPU diagnostic.

# Normalize a caller-validated private root-owned payload without following its
# signed symlinks. Callers must already require root and a protected, unlinked
# parent. "sealed" retains private modes; "readable" exposes ordinary-user read
# and existing execute permissions. Ownership of symlinks changes with -h, but
# ACL/mode operations apply only to regular files/directories. In particular a
# bundle's relative AIR link may legitimately be dangling while being moved.
session_tree_permissions() {
    local tree=$1 policy=$2 mode invalid
    [ ! -L "$tree" ] && { [ -d "$tree" ] || [ -f "$tree" ]; } || return 64
    case "$policy" in sealed) mode=go-w ;; readable) mode=go-w,a+rX ;; *) return 64 ;; esac
    invalid=$(find -P "$tree" ! \( -type d -o -type f -o -type l \) -print -quit) || return 74
    [ -z "$invalid" ] || return 64
    chown -hR root:wheel "$tree" || return 74
    # The + form propagates a failing chmod invocation through find's status;
    # a false -exec ... \; predicate alone would still let find exit zero.
    find -P "$tree" \( -type d -o -type f \) -exec chmod -N {} + || return 74
    find -P "$tree" \( -type d -o -type f \) -exec chmod "$mode" {} + || return 74
}

# Preserve an existing destination by rename before replacing it. The journal
# must be on the destination filesystem and protected by the root caller.
# A prepared payload is consumed; a failed move remains recoverable by rollback.
session_replace() {
    local journal=$1 key=$2 target=$3 prepared=$4
    case "$key" in ''|*[!a-zA-Z0-9_-]*) return 64 ;; esac
    [ -d "$journal" ] && [ ! -L "$journal" ] || return 64
    [ ! -e "$journal/$key.target" ] || return 64
    [ -e "$prepared" ] && [ ! -L "$target" ] || return 64
    printf '%s\n' "$target" > "$journal/$key.target" || return 74
    if [ -e "$target" ]; then
        printf 'present\n' > "$journal/$key.original" || return 74
        if [ -f "$target" ] && [ -f "$prepared" ]; then
            # Keep the old AuxKC/config-like files in place until an atomic
            # same-filesystem replacement is ready. An interrupted copy is not
            # accepted as a complete original backup during recovery.
            cp -p "$target" "$journal/$key.backup-pending" || return 74
            mv "$journal/$key.backup-pending" "$journal/$key.backup" || return 74
        else
            mv "$target" "$journal/$key.backup" || return 74
        fi
    else
        printf 'absent\n' > "$journal/$key.original" || return 74
    fi
    mv -f "$prepared" "$target"
}

# Restore only a caller-supplied, immutable target whitelist. A journal entry
# cannot redirect deletion/rename, and missing backups are never fabricated.
# Repeated recovery is inert after its completion marker was written.
session_restore_one() {
    local journal=$1 key=$2 target=$3 original recorded
    case "$key" in ''|*[!a-zA-Z0-9_-]*) return 64 ;; esac
    [ -f "$journal/$key.target" ] || return 0
    [ ! -f "$journal/$key.restored" ] || return 0
    IFS= read -r recorded < "$journal/$key.target" || return 74
    [ "$recorded" = "$target" ] && [ ! -L "$target" ] || return 64
    [ -f "$journal/$key.original" ] || return 74
    IFS= read -r original < "$journal/$key.original" || return 74
    case "$original" in
        present)
            if [ -e "$journal/$key.backup" ]; then
                # Retain the replaced candidate as evidence instead of deleting
                # any tree recursively. Both paths stay in protected storage.
                if [ -e "$target" ]; then
                    [ ! -e "$journal/$key.replaced" ] || return 74
                    if [ -f "$target" ] && [ -f "$journal/$key.backup" ]; then
                        cp -p "$target" "$journal/$key.replaced-pending" || return 74
                        mv "$journal/$key.replaced-pending" "$journal/$key.replaced" || return 74
                    else
                        mv "$target" "$journal/$key.replaced" || return 74
                    fi
                fi
                mv -f "$journal/$key.backup" "$target" || return 74
            else
                # The original may not yet have been moved when interrupted.
                [ -e "$target" ] || return 74
            fi
            ;;
        absent)
            if [ -e "$target" ]; then
                [ ! -e "$journal/$key.replaced" ] || return 74
                mv "$target" "$journal/$key.replaced" || return 74
            fi
            ;;
        *) return 64 ;;
    esac
    : > "$journal/$key.restored"
}

# Bound a macOS read/build command without GNU timeout. A kernel-blocked child
# can outlive SIGKILL; do not wait for it indefinitely or infer successful work.
session_bounded() {
    local limit=$1 output=$2 elapsed=0 child code
    shift 2
    "$@" > "$output" 2>&1 &
    child=$!
    while kill -0 "$child" 2>/dev/null && [ "$elapsed" -lt $((limit * 10)) ]; do
        sleep 0.1
        elapsed=$((elapsed + 1))
    done
    if kill -0 "$child" 2>/dev/null; then
        kill -TERM "$child" 2>/dev/null || :
        sleep 0.1
        kill -KILL "$child" 2>/dev/null || :
        disown "$child" 2>/dev/null || :
        printf '\ncommand_timeout_seconds=%s\n' "$limit" >> "$output"
        return 124
    fi
    if wait "$child"; then code=0; else code=$?; fi
    printf '\ncommand_exit_status=%s\n' "$code" >> "$output"
    return "$code"
}

# A manually started coordinator gets its own session/process group so Ctrl-C
# in the root terminal can stop its helpers/probes before closing evidence.
# Perl/POSIX is provided with the system (also used by macOS shasum).
session_stop_group() {
    local pid=${SESSION_GROUP_PID:-} reaped=${1:-no} ticks=0
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    [ "$pid" -gt 1 ] || return 64
    kill -TERM -- "-$pid" 2>/dev/null || :
    # Also stop the leader if interruption arrived before setsid completed.
    # After wait has reaped it, only the still-owned group may be signalled.
    if [ "$reaped" != yes ]; then kill -TERM "$pid" 2>/dev/null || :; fi
    while { kill -0 -- "-$pid" 2>/dev/null || { [ "$reaped" != yes ] && kill -0 "$pid" 2>/dev/null; }; } && [ "$ticks" -lt 20 ]; do
        sleep 0.1; ticks=$((ticks + 1))
    done
    kill -KILL -- "-$pid" 2>/dev/null || :
    if [ "$reaped" != yes ]; then kill -KILL "$pid" 2>/dev/null || :; fi
    disown "$pid" 2>/dev/null || :
    SESSION_GROUP_PID=''
}

session_bounded_group() {
    local limit=$1 output=$2 elapsed=0 code pid
    shift 2
    SESSION_GROUP_PID=''
    case "$limit" in ''|*[!0-9]*) return 64 ;; esac
    if [ "$limit" -eq 0 ]; then
        printf 'command_timeout_seconds=0\n' > "$output"
        return 124
    fi
    /usr/bin/perl -MPOSIX -e 'my $sid = POSIX::setsid(); die "setsid failed: $!" unless defined($sid) && $sid >= 0; exec @ARGV; die "exec failed: $!";' \
        -- "$@" </dev/null > "$output" 2>&1 &
    SESSION_GROUP_PID=$!; pid=$SESSION_GROUP_PID
    while kill -0 "$pid" 2>/dev/null && [ "$elapsed" -lt $((limit * 10)) ]; do
        sleep 0.1; elapsed=$((elapsed + 1))
    done
    if kill -0 "$pid" 2>/dev/null; then
        session_stop_group
        printf '\ncommand_timeout_seconds=%s\n' "$limit" >> "$output"
        return 124
    fi
    if wait "$pid"; then code=0; else code=$?; fi
    session_stop_group yes
    printf '\ncommand_exit_status=%s\n' "$code" >> "$output"
    return "$code"
}

# Accept a completed normal-desktop recorder session, never an old boot or an
# empty/timeout-only report. GPU success is deliberately outside this predicate.
session_recorder_valid() {
    local report=$1 boot=$2
    [ -f "$report/stages.txt" ] && [ -f "$report/boot-identity.txt" ] || return 1
    grep -Fq "$boot" "$report/boot-identity.txt" || return 1
    grep -Eq 'collector_end reason=(duration_complete|deadline_or_termination)' "$report/stages.txt" || return 1
    grep -Eq 'stage=kernel-stream startup_failed|stage=kernel-stream exited|sync_failed|end status=124' "$report/stages.txt" && return 1
    awk '
      /heartbeat stream_alive=1/ {
        for (i=1;i<=NF;i++) if ($i ~ /^elapsed_s=/) {
          split($i,a,"="); if (!seen++) first=a[2]; last=a[2]
        }
      }
      END { exit !(seen >= 2 && last-first >= 250) }
    ' "$report/stages.txt" || return 1
    grep -q 'collector_command_exit=0' "$report/dmesg-0.txt" || return 1
    grep -q 'collector_command_exit=0' "$report/ioreg-NMXGPU-0.txt" || return 1
    grep -q 'collector_command_exit=0' "$report/ioreg-NMXAccel-0.txt" || return 1
}

# PM callbacks can overwrite the last attach checkpoint after successful
# lifecycle completion. In that case require the published framebuffer plus a
# successful completed PM callback; a claim or framebuffer alone is insufficient.
session_registry_ready() {
    local report=$1
    grep -Eq 'failed:|parked:|cancelled:|attach.no_framebuffer' "$report" && return 1
    grep -q 'class NMXGPUFB' "$report" || return 1
    grep -Eq '(attach.complete|pm.callback.after) ret=0(["[:space:]]|$)' "$report"
}

# Publish only that the ordinary-user coordinator exited. This notification is
# not a GPU verdict; the guarded probe logs remain the readback evidence. Rename
# last so root cannot mistake partially written fields for a completed session.
session_write_terminal() (
    umask 077
    local session=$1 boot=$2 uid=$3 code=$4
    case "$boot" in ''|*[!a-zA-Z0-9-]*) return 64 ;; esac
    case "$uid" in ''|*[!0-9]*) return 64 ;; esac
    case "$code" in ''|*[!0-9]*) return 64 ;; esac
    [ "$code" -le 255 ] && [ -d "$session" ] && [ ! -L "$session" ] || return 64
    printf 'terminal_version=1\nboot=%s\nuid=%s\ncoordinator_exit=%s\n' \
        "$boot" "$uid" "$code" > "$session/terminal.pending" || return 74
    mv -f "$session/terminal.pending" "$session/terminal.txt"
)

# Validate a bounded private snapshot, never source a user-supplied notification.
# Root performs owner/mode/path checks and reads as the selected user first.
session_terminal_content_valid() {
    local report=$1 boot=$2 uid=$3
    [ -f "$report" ] && [ ! -L "$report" ] || return 1
    [ "$(wc -c < "$report" | tr -d ' ')" -le 512 ] || return 1
    awk -v boot="$boot" -v uid="$uid" '
      $0 == "terminal_version=1" { version++; next }
      $0 == "boot=" boot { boots++; next }
      $0 == "uid=" uid { users++; next }
      /^coordinator_exit=[0-9]+$/ {
        split($0,a,"="); if (length(a[2]) > 3 || a[2]+0 > 255) bad=1
        codes++; next
      }
      { bad=1 }
      END { exit !(NR==4 && version==1 && boots==1 && users==1 && codes==1 && !bad) }
    ' "$report"
}

# A stopped collector must have written its final marker for this exact boot.
# Command success alone does not establish that its buffered evidence is closed.
session_recorder_ended() {
    local report=$1 boot=$2
    [ -f "$report/boot-identity.txt" ] && [ -f "$report/stages.txt" ] || return 1
    grep -Fxq "kern.bootsessionuuid: $boot" "$report/boot-identity.txt" || return 1
    grep -Eq 'collector_end reason=(duration_complete|deadline_or_termination|interrupted)' "$report/stages.txt"
}

# Wait only until a validated exit notification exists. SECONDS is monotonic
# within Bash and does not depend on this Hackintosh's wall-clock configuration.
# The callback can report completion only; it cannot make a GPU result pass.
session_wait_terminal() {
    local limit=$1 output=$2 started=$SECONDS
    shift 2
    while [ $((SECONDS - started)) -lt "$limit" ]; do
        if "$@"; then
            printf 'trigger=coordinator-ended\nwaited_seconds=%s\n' "$((SECONDS - started))" > "$output"
            return 0
        fi
        sleep 2
    done
    printf 'trigger=deadline\nwaited_seconds=%s\npartial=true\n' "$((SECONDS - started))" > "$output"
    return 124
}

# Keep each selected runner's exit code when displaying its output live. A tee
# failure is an evidence failure even if the runner itself returned success.
session_compute_phase() {
    local runner=$1 phase=$2 log=$3 live=$4 codes=()
    if [ "$live" = live ]; then
        printf '\n=== %s: checking the driver and running compute/readback ===\n' "$phase"
        if "$runner" "$phase" 2>&1 | tee "$log"; then
            return 0
        else
            codes=("${PIPESTATUS[@]}")
            [ "${codes[0]}" -eq 0 ] || return "${codes[0]}"
            return 74
        fi
    fi
    "$runner" "$phase" > "$log" 2>&1
}

# Run the two diagnostics in order only when the preceding command actually
# returned success. The production probe independently requires its own exact
# readback marker, deadline and candidate UUID; callers cannot skip that gate.
session_compute_sequence() {
    local runner=$1 output=$2 stop=${3:-} live=${4:-quiet} code=0
    if [ -n "$stop" ] && [ -f "$stop" ]; then
        printf 'phase=not-started\nexit=124\nvulkan_started=false\nmetal_started=false\n' > "$output/sequence.txt"
        return 124
    fi
    session_compute_phase "$runner" vulkan "$output/vulkan-runner.txt" "$live" || code=$?
    if [ "$code" -ne 0 ]; then
        printf 'phase=vulkan\nexit=%s\nmetal_started=false\n' "$code" > "$output/sequence.txt"
        return "$code"
    fi
    if [ -n "$stop" ] && [ -f "$stop" ]; then
        printf 'phase=vulkan\nexit=124\nmetal_started=false\nautomation_deadline=true\n' > "$output/sequence.txt"
        return 124
    fi
    [ "$live" != live ] || printf '\nVulkan compute/readback passed. Continuing to Metal.\n'
    session_compute_phase "$runner" metal "$output/metal-runner.txt" "$live" || code=$?
    printf 'phase=metal\nexit=%s\nmetal_started=true\n' "$code" > "$output/sequence.txt"
    return "$code"
}
