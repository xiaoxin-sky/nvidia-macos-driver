#!/bin/bash
# Inert helpers shared by the single-session installer and its host fixtures.
# Callers supply protected storage and exact destinations; sourcing never reads
# a device, edits EFI, installs a kext or starts a GPU diagnostic.

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

# Run the two diagnostics in order only when the preceding command actually
# returned success. The production probe independently requires its own exact
# readback marker, deadline and candidate UUID; callers cannot skip that gate.
session_compute_sequence() {
    local runner=$1 output=$2 code=0
    "$runner" vulkan > "$output/vulkan-runner.txt" 2>&1 || code=$?
    if [ "$code" -ne 0 ]; then
        printf 'phase=vulkan\nexit=%s\nmetal_started=false\n' "$code" > "$output/sequence.txt"
        return "$code"
    fi
    "$runner" metal > "$output/metal-runner.txt" 2>&1 || code=$?
    printf 'phase=metal\nexit=%s\nmetal_started=true\n' "$code" > "$output/sequence.txt"
    return "$code"
}
