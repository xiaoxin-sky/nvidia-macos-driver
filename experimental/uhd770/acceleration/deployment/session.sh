#!/bin/bash -p
# One opt-in application-compute session for the pinned UHD770 candidate.
# Preparation runs while -nvoff is active. A dedicated USB config is armed last;
# a boot job restores its opt-out before user diagnostics. Original files/KC are
# journaled. No network, automatic reboot, SIP/AMFI change or global Metal opt-in.
set -Eeuo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH GLOBIGNORE
umask 077
ROOT='/Library/Application Support/UHD770MVP'
PUBLIC="$ROOT/session-public"
PRIVATE="$ROOT/session-private"
JOURNAL="$PRIVATE/journal"
PLAN="$PUBLIC/plan.plist"
LABEL=com.uhd770.mvp.session
# macOS may legitimately allow its daemon group to write /private/var/run.
# Use a private sibling of the staged tree; creating ROOT here would make
# manage.sh incorrectly treat an uninitialized stage as an existing one.
LOCK='/Library/Application Support/.com.uhd770.mvp.prepare.lock'
LOCK_OWNED=0
PREPARATION_OWNED=0
USB_SELECTION_OWNED=0
ROOT_JOB_OWNED=0
AUTO_EXPORT_ATTEMPTED=0
MANUAL_ACTIVE=0
MANUAL_CAPTURE=''
SESSION_GROUP_PID=''
FOLLOWER=''
KEY='NVRAM.Add.7C436110-AB2A-4BBB-A880-FE41995C9F82.boot-args'
KIT=$(cd "$(dirname "$0")/.." && pwd -P)
HERE="$KIT/tools"
case "$0" in */incoming/tools/session.sh) KIT="$ROOT/incoming"; HERE="$KIT/tools" ;; esac

die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
usage() {
    printf '%s\n' 'Usage: sudo /bin/bash -p tools/session.sh prepare|test|export|restore' \
      'prepare: automatic staging, recorder validation, matched install and ONE next-boot test.' \
      'test: explicitly run the ordinary-user compute tests after reboot; show progress and export.' \
      'export: collect all surviving system and selected-user diagnostic evidence.' \
      'restore: restore the USB opt-out and journaled original files/KC; takes effect next boot.' \
      'Requires the machine-specific session-target payload. Never reboots automatically.'
}
[ "${1:-}" != --help ] || { usage; exit 0; }
[ "$#" -eq 1 ] || { usage >&2; exit 64; }
MODE=$1
case "$MODE" in prepare|test|export|restore|boot) ;; *) usage >&2; exit 64 ;; esac
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = x86_64 ] || die 'Native x86_64 macOS required.'
[ "$EUID" -eq 0 ] || die 'Run with sudo /bin/bash -p.'
case $- in *p*) ;; *) die 'Use /bin/bash -p.' ;; esac
case "$(sw_vers -productVersion)" in 15.*) ;; *) die 'macOS 15 required.' ;; esac
[ -f "$HERE/session-lib.sh" ] && [ ! -L "$HERE/session-lib.sh" ] || die 'Missing session helpers.'
. "$HERE/session-lib.sh"

safe_directory() {
    local path=$1 uid mode
    [ -d "$path" ] && [ ! -L "$path" ] || die "Unsafe directory: $path"
    uid=$(stat -f '%u' "$path"); mode=$(stat -f '%Lp' "$path")
    [ "$uid" = 0 ] && [ $((8#$mode & 0022)) -eq 0 ] || die "Unsafe owner/mode: $path"
}
property() { plutil -extract "$1" raw -o - "$PLAN"; }
hash() { shasum -a 256 "$1" | awk '{print $1}'; }

# Capture budget for the manual run. One recorder session has to outlive the
# whole run: startup confirmation, the coordinator's own bound, the loaded-kext
# snapshot taken after it exits, and the post-test observation. A window shorter
# than their sum is exactly how a teardown panic at the end goes unrecorded.
# The budget is a constant with a guard rather than a computed value: what is
# checked here is that it covers every bounded step that runs while the
# recorder is alive, so a later edit to one constant fails at startup.
MANUAL_STARTUP_LIMIT=25
MANUAL_COORDINATOR_LIMIT=600
MANUAL_OBSERVE_LIMIT=180
# A failed run whose probes never printed "dispatch N:" (each probe prints it
# immediately before submitting) gave the GPU no work, so no delayed display
# failure can follow; a short observation still records any late panic line.
MANUAL_OBSERVE_SHORT_LIMIT=15
MANUAL_LOADED_AFTER_LIMIT=10
MANUAL_CAPTURE_LIMIT=900
MANUAL_REQUIRED_LIMIT=$((MANUAL_STARTUP_LIMIT + MANUAL_COORDINATOR_LIMIT + MANUAL_OBSERVE_LIMIT + MANUAL_LOADED_AFTER_LIMIT))
[ "$MANUAL_CAPTURE_LIMIT" -ge "$MANUAL_REQUIRED_LIMIT" ] || \
    die 'Capture budget does not cover startup, coordinator, loaded-kext snapshot and observation.'

# Every mutation/recovery target is fixed here, not read from a journal or EFI.
targets() {
    printf '%s\n' \
      'nmxgpu|/Library/Extensions/NMXGPU.kext' \
      'nmxaccel|/Library/Extensions/NMXAccel.kext' \
      'cachegpu|/Library/NullMoth/kexts/15/NMXGPU.kext' \
      'cacheaccel|/Library/NullMoth/kexts/15/NMXAccel.kext' \
      'firmware|/Library/NullMoth/firmware/i915' \
      'license|/Library/NullMoth/firmware/LICENSES/LICENSE.i915' \
      'runtime|/Library/GPUBundles/nvmtl' \
      'frontend|/Library/GPUBundles/NVMTLDriver.bundle' \
      'auxkc|/Library/KernelCollections/AuxiliaryKernelExtensions.kc' \
      'rootjob|/Library/LaunchDaemons/com.uhd770.mvp.session.plist'
}

# Runtime siblings retain their final names during all private validation so
# the signed AIR relative symlink resolves without rewriting its sealed bytes.
prepared_path() {
    case "$1" in
        runtime) printf '%s/Library/GPUBundles/nvmtl\n' "$PRIVATE/prepared" ;;
        frontend) printf '%s/Library/GPUBundles/NVMTLDriver.bundle\n' "$PRIVATE/prepared" ;;
        nmxgpu|nmxaccel|cachegpu|cacheaccel|firmware|license|auxkc|rootjob)
            printf '%s/%s\n' "$PRIVATE/prepared" "$1" ;;
        *) return 64 ;;
    esac
}

# Check only the two candidate trees, allowing unrelated system GPUBundles.
# Modes/ACLs may change; the signed symlink text and code signatures may not.
check_runtime() {
    local bundles=$1 report=$2 entry magic line relative manifest="$ROOT/incoming/runtime-SHA256SUMS" owner mode
    [ -d "$bundles/nvmtl" ] && [ ! -L "$bundles/nvmtl" ] || return 64
    [ -d "$bundles/NVMTLDriver.bundle" ] && [ ! -L "$bundles/NVMTLDriver.bundle" ] || return 64
    # The original resource seal covers the relative link text, not bytes in
    # its sibling runtime. Verify that entire external closure against the
    # digest-checked, root-protected candidate manifest in both private/live
    # layouts. Ad-hoc signature validity alone does not establish provenance.
    [ -f "$manifest" ] && [ ! -L "$manifest" ] || return 64
    owner=$(stat -f '%u' "$manifest"); mode=$(stat -f '%Lp' "$manifest")
    [ "$owner" = 0 ] && [ $((8#$mode & 0022)) -eq 0 ] || return 64
    : > "$report.manifest.txt" || return 74
    : > "$report.expected-pending.txt" || return 74
    while IFS= read -r line; do
        [[ "$line" =~ ^[0-9a-f]{64}\ \ [A-Za-z0-9_./+-]+$ ]] || return 64
        relative=${line:66}
        case "$relative" in
            Library/GPUBundles/nvmtl/*|Library/GPUBundles/NVMTLDriver.bundle/*) ;;
            *) continue ;;
        esac
        relative=${relative#Library/GPUBundles/}
        case "/$relative/" in *'/../'*|*'/./'*|*'//'*) return 64 ;; esac
        printf '%s  %s\n' "${line:0:64}" "$relative" >> "$report.manifest.txt" || return 74
        printf '%s\n' "$relative" >> "$report.expected-pending.txt" || return 74
    done < "$manifest"
    [ -s "$report.manifest.txt" ] || return 64
    LC_ALL=C sort "$report.expected-pending.txt" > "$report.expected-files.txt" || return 74
    uniq -d "$report.expected-files.txt" > "$report.duplicates.txt" || return 74
    [ ! -s "$report.duplicates.txt" ] || return 64
    find -P "$bundles/nvmtl" "$bundles/NVMTLDriver.bundle" -type f -print > "$report.files.txt" || return 74
    : > "$report.actual-pending.txt" || return 74
    while IFS= read -r entry; do
        printf '%s\n' "${entry#"$bundles/"}" >> "$report.actual-pending.txt" || return 74
    done < "$report.files.txt"
    LC_ALL=C sort "$report.actual-pending.txt" > "$report.actual-files.txt" || return 74
    cmp -s "$report.expected-files.txt" "$report.actual-files.txt" || return 64
    find -P "$bundles/nvmtl" "$bundles/NVMTLDriver.bundle" ! \( -type d -o -type f -o -type l \) -print > "$report.unsupported.txt" || return 74
    [ ! -s "$report.unsupported.txt" ] || return 64
    (cd "$bundles" && session_bounded 60 "$report.hashes.txt" /usr/bin/shasum -a 256 --strict -c "$report.manifest.txt") || return 1
    [ "$(readlink "$bundles/nvmtl/libvulkan.dylib")" = libvulkan.1.dylib ] || return 64
    [ "$(readlink "$bundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime")" = ../../../nvmtl ] || return 64
    [ -f "$bundles/nvmtl/libvulkan.dylib" ] && [ -d "$bundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime" ] || return 64
    find -P "$bundles/nvmtl" "$bundles/NVMTLDriver.bundle" -type l -print > "$report.links.txt" || return 74
    while IFS= read -r entry; do
        case "$entry" in
            "$bundles/nvmtl/libvulkan.dylib"|"$bundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime") ;;
            *) return 64 ;;
        esac
    done < "$report.links.txt"
    for entry in libvulkan.1.dylib libvulkan_intel.dylib libnvmtl_translate.dylib air-opt NVMTLDriver; do
        [ -f "$bundles/nvmtl/$entry" ] && [ ! -L "$bundles/nvmtl/$entry" ] || return 64
    done
    # --strict adds an in-bundle destination policy that this intentionally
    # shared relative runtime cannot satisfy. Ordinary bundle verification
    # still validates its code/resource seal and exact signed symlink text;
    # the manifest above closes the separately stored runtime's byte identity.
    session_bounded 20 "$report.bundle.txt" codesign --verify "$bundles/NVMTLDriver.bundle" || return 1
    while IFS= read -r entry; do
        case "$entry" in "$bundles/nvmtl/"*) ;; *) continue ;; esac
        magic=$(od -An -tu4 -N4 "$entry" | tr -d '[:space:]') || return 74
        [ "$magic" = 4277009103 ] || continue
        printf 'verifying=%s\n' "$entry" >> "$report.signatures.txt" || return 74
        session_bounded 20 "$report.current.txt" codesign --verify --strict "$entry" || return 1
        cat "$report.current.txt" >> "$report.signatures.txt" || return 74
    done < "$report.files.txt"
}

# A partial bootstrap may still register its job. Only a preparation that
# proved the label absent and attempted its own bootstrap can call this helper.
stop_owned_root_job() {
    [ "$ROOT_JOB_OWNED" -eq 1 ] || return 0
    local report state=0 bootout=not-run
    report=$(mktemp -d "$PRIVATE/root-job-stop.XXXXXX") || return 1
    session_bounded 2 "$report/domain-before.txt" launchctl print system || return 1
    session_launchd_state "$LABEL" "$report/label-before.txt" || state=$?
    [ "$state" -ne 2 ] || return 1
    awk '/^[[:space:]]*pid = [0-9]+[[:space:]]*$/ {print $3}' "$report/label-before.txt" > "$report/original-pids.txt"
    if [ "$state" -eq 0 ]; then
        bootout=0
        session_bounded 5 "$report/bootout.txt" launchctl bootout "system/$LABEL" || bootout=$?
    else
        printf 'bootout=not-needed-label-already-absent\n' > "$report/bootout.txt"
    fi
    printf 'bootout_exit=%s\n' "$bootout" > "$report/bootout-status.txt"
    # The root launch job shares session.sh with this preparation process.
    # Wait for only its captured label/PIDs, not every process using that file.
    session_wait_launchd_stopped "$LABEL" '' "$report/original-pids.txt" "$report" 20 || return 1
    printf 'stop=verified\nbootout_exit=%s\n' "$bootout" > "$report/result.txt"
    ROOT_JOB_OWNED=0
}

# Validate each existing ancestor before creating only known /Library parents.
prepare_parent() {
    local parent=${1%/*} current='' part
    local parts=()
    case "$parent" in /Library|/Library/*) ;; *) die 'Unexpected installation parent.' ;; esac
    IFS=/ read -r -a parts <<< "$parent"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        current="$current/$part"
        if [ ! -e "$current" ] && [ ! -L "$current" ]; then mkdir -m 755 "$current"; fi
        safe_directory "$current"
    done
}

# Include only protected stop/upgrade reports created by this tool, with a finite copy
# budget. Originals remain root-only; export_all later gives the aggregate copy
# to the selected user so Finder can retrieve failures without changing modes.
export_stop_reports() {
    local output=$1 source owner mode invalid count blocks
    for source in /Users/Shared/UHD770MVP-recorder-stop.* "$ROOT"/recorder-stop.* \
        "$PRIVATE"/root-job-stop.* "$PRIVATE"/restore-job-stop.* "$PRIVATE"/reviewed-fbfix.*; do
        [ -d "$source" ] && [ ! -L "$source" ] || continue
        owner=$(stat -f '%u' "$source") || continue
        mode=$(stat -f '%Lp' "$source") || continue
        [ "$owner" = 0 ] && [ $((8#$mode & 0022)) -eq 0 ] || continue
        invalid=$(find -P "$source" ! \( -type d -o -type f \) -print -quit) || continue
        [ -z "$invalid" ] || continue
        count=$(find -P "$source" -type f -print | wc -l | tr -d ' ')
        blocks=$(du -sk "$source" | awk '{print $1}')
        case "$count:$blocks" in *[!0-9:]*|:*|*:) continue ;; esac
        [ "$count" -le 512 ] && [ "$blocks" -le 65536 ] || continue
        mkdir -p "$output/recorder-stop"
        ditto "$source" "$output/recorder-stop/$(basename "$source")"
    done
}

export_all() {
    local output uid account home bootstrap owner mode
    output=$(mktemp -d /Users/Shared/UHD770MVP-session-reports.XXXXXX)
    # Always retain same-boot evidence even if session directories cannot be
    # copied. The r9 failure export lacked both preparation and user records.
    { printf 'mode=%s\nmanual_active=%s\nroot=%s\npublic=%s\nprivate=%s\n' \
          "$MODE" "$MANUAL_ACTIVE" "$ROOT" "$PUBLIC" "$PRIVATE"
      ls -ld "$ROOT" "$PUBLIC" "$PRIVATE" "$PLAN"; } > "$output/export-context.txt" 2>&1 || :
    session_bounded 5 "$output/boot-identity.txt" sysctl kern.bootsessionuuid kern.bootargs || :
    session_bounded 10 "$output/loaded-kexts.txt" kmutil showloaded || :
    /bin/bash -p "$HERE/manage.sh" export > "$output/manage-export.txt" 2>&1 || :
    # manage.sh prints the path of its separately created root evidence report.
    local managed
    managed=$(sed -n 's/^Reports exported to: //p' "$output/manage-export.txt")
    case "$managed" in /Users/Shared/UHD770MVP-reports.*)
        [ ! -L "$managed" ] && ditto "$managed" "$output/system" || : ;;
    esac
    if [ -d "$PUBLIC" ] && [ ! -L "$PUBLIC" ]; then ditto "$PUBLIC" "$output/session"; fi
    if [ -d "$PRIVATE" ] && [ ! -L "$PRIVATE" ]; then
        mkdir "$output/preparation"
        find "$PRIVATE" -maxdepth 1 -type f -name '*.txt' -exec cp '{}' "$output/preparation/" \;
        if [ -d "$JOURNAL" ] && [ ! -L "$JOURNAL" ]; then
            local journal_key journal_target receipt item size
            mkdir "$output/preparation/journal"
            find -P "$JOURNAL" -mindepth 1 -maxdepth 1 -print > "$output/preparation/journal/entries.txt"
            while IFS='|' read -r journal_key journal_target; do
                for receipt in target original restored; do
                    item="$JOURNAL/$journal_key.$receipt"
                    [ -f "$item" ] && [ ! -L "$item" ] || continue
                    size=$(stat -f '%z' "$item") || continue
                    [ "$size" -le 1024 ] || continue
                    cp "$item" "$output/preparation/journal/$journal_key.$receipt"
                done
                for receipt in backup backup-pending replaced replaced-pending; do
                    item="$JOURNAL/$journal_key.$receipt"
                    if [ -e "$item" ] || [ -L "$item" ]; then
                        printf '%s.%s=present\n' "$journal_key" "$receipt"
                    else
                        printf '%s.%s=absent\n' "$journal_key" "$receipt"
                    fi
                done
            done < <(
                targets
                printf '%s\n' 'userjob|/Library/LaunchAgents/com.uhd770.mvp.session.plist'
            ) > "$output/preparation/journal/retained-payloads.txt"
        fi
    fi
    # Start records even failures before PLAN/staging exist. Keep complete
    # root-owned transcripts retrievable by a later explicit export.
    for bootstrap in /Users/Shared/UHD770MVP-bootstrap.*; do
        [ -d "$bootstrap" ] && [ ! -L "$bootstrap" ] || continue
        owner=$(stat -f '%u' "$bootstrap" 2>/dev/null) || continue
        mode=$(stat -f '%Lp' "$bootstrap" 2>/dev/null) || continue
        [ "$owner" = 0 ] && [ $((8#$mode & 0022)) -eq 0 ] || continue
        mkdir -p "$output/bootstrap"
        ditto "$bootstrap" "$output/bootstrap/$(basename "$bootstrap")"
    done
    export_stop_reports "$output"
    if [ -f "$PLAN" ] && [ ! -L "$PLAN" ]; then
        uid=$(property user_uid)
        case "$uid" in ''|*[!0-9]*) die 'Invalid selected-user identity.' ;; esac
        account=$(id -nu "$uid")
        home=$(dscl . -read "/Users/$account" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
        # No arbitrary user path from a report is accepted as a root copy source.
        case "$home" in /Users/*)
            if [ -d "$home/Library/Logs/UHD770MVP" ] && [ ! -L "$home/Library/Logs/UHD770MVP" ]; then
                ditto "$home/Library/Logs/UHD770MVP" "$output/user-diagnostics"
            fi ;;
        esac
        chown -hR "$uid:$(id -g "$account")" "$output"
    elif [ -n "${SUDO_UID:-}" ]; then
        chown -hR "$SUDO_UID:$SUDO_GID" "$output"
    fi
    printf 'Report: %s\n' "$output"
}

# Resolve only the USB UUID selected during preparation, then recheck both its
# filesystem identity and config hash. Never pick the first EFI on the machine.
usb_config() {
    local uuid mount info="$PRIVATE/usb-current.txt"
    uuid=$(property volume_uuid)
    case "$uuid" in ''|*[!a-zA-Z0-9-]*) return 1 ;; esac
    session_bounded 15 "$info" diskutil info -plist "$uuid" || return 1
    # bounded appends a status line, so retain a separate parseable plist.
    sed '/^command_exit_status=/d' "$info" > "$PRIVATE/usb-info.plist"
    mount=$(plutil -extract MountPoint raw -o - "$PRIVATE/usb-info.plist" 2>/dev/null || :)
    if [ -z "$mount" ]; then
        session_bounded 20 "$PRIVATE/usb-mount.txt" diskutil mount "$uuid" || return 1
        diskutil info -plist "$uuid" > "$PRIVATE/usb-info.plist" || return 1
        mount=$(plutil -extract MountPoint raw -o - "$PRIVATE/usb-info.plist") || return 1
    fi
    case "$mount" in /Volumes/*) ;; *) return 1 ;; esac
    [ "$(plutil -extract BusProtocol raw -o - "$PRIVATE/usb-info.plist")" = USB ] || return 1
    [ "$(plutil -extract VolumeName raw -o - "$PRIVATE/usb-info.plist")" = "$(property volume_label)" ] || return 1
    [ ! -L "$mount/EFI" ] && [ ! -L "$mount/EFI/OC" ] && [ -f "$mount/EFI/OC/config.plist" ] && [ ! -L "$mount/EFI/OC/config.plist" ] || return 1
    printf '%s\n' "$mount/EFI/OC/config.plist"
}

restore_optout() {
    local cfg actual safe test
    cfg=$(usb_config) || return 1
    safe=$(property safe_hash); test=$(property test_hash); actual=$(hash "$cfg")
    if [ "$actual" = "$test" ]; then
        [ "$(hash "$ROOT/incoming/session-target/config.safe.plist")" = "$safe" ] || return 1
        [ ! -e "$cfg.uhd770-pending" ] && [ ! -L "$cfg.uhd770-pending" ] || return 1
        cp "$ROOT/incoming/session-target/config.safe.plist" "$cfg.uhd770-pending" || return 1
        [ "$(hash "$cfg.uhd770-pending")" = "$safe" ] || return 1
        mv -f "$cfg.uhd770-pending" "$cfg" || return 1
    elif [ "$actual" != "$safe" ]; then
        printf 'USB config changed independently; preserved.\n' >&2
        return 1
    fi
    [ "$(hash "$cfg")" = "$safe" ] || return 1
    # A global sync on the target routinely outlasts 5 s; the config is already
    # verified above, so only the flush confirmation needs the longer bound.
    session_bounded 30 "$PRIVATE/optout-sync.txt" sync || return 1
}

restore_files() {
    local key target code=0
    while IFS='|' read -r key target; do
        session_restore_one "$JOURNAL" "$key" "$target" || code=1
    done < <(targets)
    # A journal from the earlier automatic kit may contain this legacy entry.
    # New preparations never install it, but recovery still knows its one path.
    session_restore_one "$JOURNAL" userjob /Library/LaunchAgents/com.uhd770.mvp.session.plist || code=1
    return "$code"
}

# Check every matching root collector, not an ended report from an earlier boot
# or an earlier recorder restart while another same-boot stream still writes.
capture_finalized() {
    local boot=$1 expected=${2:-} report found=0
    if [ -n "$expected" ]; then
        session_recorder_ended "$expected" "$boot"
        return
    fi
    for report in /private/var/log/UHD770MVP/session-*; do
        [ -d "$report" ] && [ ! -L "$report" ] || continue
        [ -f "$report/boot-identity.txt" ] || continue
        grep -Fxq "kern.bootsessionuuid: $boot" "$report/boot-identity.txt" || continue
        found=1
        session_recorder_ended "$report" "$boot" || return 1
    done
    [ "$found" -eq 1 ]
}

# Stop only our current capture registration; its RunAtLoad plist remains for a
# recovery boot. Even a successful bootout needs a final collector marker before
# the export can describe capture as closed. Failure retains partial evidence.
finish_capture() {
    local boot=$1 expected=${2:-} started=$SECONDS
    session_bounded 20 "$PRIVATE/capture-stop-$boot.txt" \
        launchctl bootout system/com.uhd770.mvp.capture || :
    started=$SECONDS
    while ! capture_finalized "$boot" "$expected" && [ $((SECONDS - started)) -lt 12 ]; do sleep 1; done
    if capture_finalized "$boot" "$expected"; then
        printf 'capture_finalization=closed\n' > "$PRIVATE/capture-finalization-$boot.txt"
    else
        printf 'capture_finalization=partial\n' > "$PRIVATE/capture-finalization-$boot.txt"
    fi
    session_bounded 3 "$PRIVATE/final-dmesg-$boot.txt" dmesg || :
    session_bounded 3 "$PRIVATE/final-NMXGPU-$boot.txt" ioreg -r -c NMXGPU -l -w0 || :
    session_bounded 3 "$PRIVATE/final-NMXAccel-$boot.txt" ioreg -r -c NMXAccel -l -w0 || :
}

automatic_export() {
    local boot=$1
    AUTO_EXPORT_ATTEMPTED=1
    [ ! -f "$PUBLIC/exported-$boot.txt" ] || return 0
    # Include failed recovery/aborted boots in the same deduplication contract.
    # Manual export never takes this lock and can still retrieve partial data.
    if ! mkdir -m 700 "$PRIVATE/exporting-$boot"; then return 0; fi
    if export_all > "$PRIVATE/automatic-export-$boot.txt"; then
        cp "$PRIVATE/automatic-export-$boot.txt" "$PUBLIC/exported-$boot.txt"
        chmod 644 "$PUBLIC/exported-$boot.txt"
        cat "$PRIVATE/automatic-export-$boot.txt"
    else
        printf 'Automatic export failed; keep the existing logs and use manual export.\n' >&2
        return 1
    fi
}

prepare() {
    local args current uid account home volume='' cfg candidate n=0 label uuid
    args=$(sysctl -n kern.bootargs)
    case " $args " in *' -nvoff '*) ;; *) die 'Current boot must contain -nvoff.' ;; esac
    case " $args " in *' nmxintel='*|*' nmxdiagdelay='*) die 'Remove stale test boot arguments before preparing.' ;; esac
    uid=${SUDO_UID:-0}
    case "$uid" in ''|*[!0-9]*) die 'Invalid login account.' ;; esac
    [ "$uid" -ge 501 ] || die 'Launch through sudo from the intended ordinary macOS account.'
    safe_directory '/Library/Application Support'
    mkdir -m 700 "$LOCK" || die 'Another preparation or an interrupted lock exists; preserved.'
    LOCK_OWNED=1
    account=$(id -nu "$uid")
    home=$(dscl . -read "/Users/$account" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
    case "$home" in /Users/*) ;; *) die 'Selected account must have a normal system-disk home.' ;; esac
    [ -f "$KIT/session-target/identity.plist" ] || die 'Use the machine-specific single-session package.'
    # Stage is still the authoritative archive/runtime/KC gate. Its failure is
    # exported by the outer trap; no live file or USB config has changed yet.
    if [ ! -e "$ROOT" ]; then
        /bin/bash -p "$HERE/manage.sh" stage
    else
        safe_directory "$ROOT"
        cmp -s "$KIT/SHA256SUMS" "$ROOT/incoming/SHA256SUMS" || die 'A different private stage exists; it was preserved.'
        grep -qx 'stage=offline-ready' "$ROOT/stage-state.txt" || die 'Existing stage is incomplete; evidence preserved.'
        (cd "$ROOT/components" && shasum -a 256 -c "$ROOT/incoming/runtime-SHA256SUMS") >/dev/null
    fi
    KIT="$ROOT/incoming"; HERE="$KIT/tools"
    [ ! -e "$PRIVATE" ] && [ ! -L "$PRIVATE" ] || die 'A session already exists; export or restore it instead of rearming.'
    [ ! -e "$PUBLIC" ] && [ ! -L "$PUBLIC" ] || die 'Existing public session evidence was preserved; do not rearm it.'
    mkdir -m 700 "$PRIVATE" "$JOURNAL"
    mkdir -m 755 "$PUBLIC"
    PREPARATION_OWNED=1
    cp "$KIT/session-target/identity.plist" "$PLAN"
    plutil -insert user_uid -integer "$uid" "$PLAN"
    current=$(sysctl -n kern.bootsessionuuid)
    plutil -insert preparation_boot -string "$current" "$PLAN"
    chmod 644 "$PLAN"
    printf 'preparing\n' > "$PUBLIC/state.txt"; chmod 644 "$PUBLIC/state.txt"
    # Select the known opt-out USB by its exact saved config, never by order.
    for candidate in /Volumes/*; do
        cfg="$candidate/EFI/OC/config.plist"
        [ -f "$cfg" ] && [ ! -L "$cfg" ] || continue
        [ "$(hash "$cfg")" = "$(property safe_hash)" ] || continue
        diskutil info -plist "$candidate" > "$PRIVATE/usb-selection.plist" || continue
        [ "$(plutil -extract BusProtocol raw -o - "$PRIVATE/usb-selection.plist" 2>/dev/null)" = USB ] || continue
        label=$(plutil -extract VolumeName raw -o - "$PRIVATE/usb-selection.plist")
        [ "$label" = "$(property volume_label)" ] || continue
        uuid=$(plutil -extract VolumeUUID raw -o - "$PRIVATE/usb-selection.plist")
        [ -n "$uuid" ] || continue
        volume=$uuid; n=$((n + 1))
    done
    [ "$n" -eq 1 ] || die 'Exactly one mounted matching 1401 USB is required; no EFI was changed.'
    plutil -insert volume_uuid -string "$volume" "$PLAN"
    # Re-read through the same UUID resolver used by recovery before proceeding.
    cfg=$(usb_config) || die 'Cannot independently resolve the selected USB.'
    [ "$(hash "$cfg")" = "$(property safe_hash)" ] || die 'USB changed during preparation.'
    USB_SELECTION_OWNED=1
    sysctl kern.bootargs kern.bootsessionuuid > "$PRIVATE/preparation-boot.txt"
    csrutil status > "$PRIVATE/sip.txt"
    grep -Eq 'Kext Signing: disabled|System Integrity Protection status: disabled' "$PRIVATE/sip.txt" || die 'Existing kext signing policy is not confirmed suitable; no security setting was changed.'
    session_bounded 5 "$PRIVATE/target-gpu.txt" ioreg -r -n IGPU -l -w0 || die 'Cannot verify the target GPU.'
    grep -Eq '"device-id"[[:space:]]*=[[:space:]]*<80460000>' "$PRIVATE/target-gpu.txt" || die 'This package requires UHD 770 PCI device 4680.'
    grep -Eq '"vendor-id"[[:space:]]*=[[:space:]]*<86800000>' "$PRIVATE/target-gpu.txt" || die 'This package requires Intel PCI vendor 8086.'
    session_bounded 5 "$PRIVATE/current-nmxgpu.txt" ioreg -r -c NMXGPU -l -w0 || die 'Cannot inspect the current GPU owner.'
    if grep -q 'class NMXGPU' "$PRIVATE/current-nmxgpu.txt"; then die 'A GPU service is already attached; no live replacement is attempted.'; fi
    if nvram nullmoth-gpu-attaching > "$PRIVATE/attach-guard.txt" 2>&1; then
        die 'An earlier attach guard is present; it was preserved, not cleared to repeat a failed boot.'
    fi
    grep -Fq 'data was not found' "$PRIVATE/attach-guard.txt" || die 'Attach guard query failed for an unknown reason; preserved.'
    # Normal-desktop recorder validation is automatic, in this same invocation.
    [ ! -e /Library/LaunchDaemons/com.uhd770.mvp.capture.plist ] || die 'An earlier capture job exists; it was preserved.'
    /bin/bash -p "$HERE/manage.sh" install-recorder
    local elapsed=0 found='' report
    printf 'Checking the automatic recorder for one 120-second normal-desktop session...\n'
    while [ "$elapsed" -lt 150 ]; do
        for report in /private/var/log/UHD770MVP/session-*; do
            if session_recorder_valid "$report" "$current"; then found=$report; break; fi
        done
        [ -z "$found" ] || break
        sleep 5; elapsed=$((elapsed + 5))
    done
    [ -n "$found" ] || die 'Recorder did not pass; no live driver was replaced or enabled.'
    printf 'recorder=%s\nnormal_desktop_capture=passed\n' "$found" > "$PRIVATE/recorder-check.txt"
    # Use ten minutes on the next boot: attach delay plus both bounded probes.
    /usr/libexec/PlistBuddy -c "Set :ProgramArguments:3 $MANUAL_CAPTURE_LIMIT" /Library/LaunchDaemons/com.uhd770.mvp.capture.plist
    local work="$PRIVATE/prepared" repo="$PRIVATE/repository" key target prepared
    mkdir "$work" "$repo"
    mkdir -p "$work/Library/GPUBundles"
    safe_directory /Library/Extensions
    ditto /Library/Extensions "$repo"
    # The two substitutions below affect only a private repository. Originals
    # remain in /Library/Extensions until the whole native KC has passed.
    for key in NMXGPU NMXAccel; do
        if [ -e "$repo/$key.kext" ]; then mv "$repo/$key.kext" "$PRIVATE/$key.repository-original"; fi
        ditto "$ROOT/kc-preflight/repository/$key.kext" "$repo/$key.kext"
    done
    local ka=(--allow-missing-kdk -a x86_64)
    [ ! -f /System/Library/Kernels/kernel ] || ka+=(--kernel /System/Library/Kernels/kernel)
    [ ! -s /System/Library/KernelCollections/SystemKernelExtensions.kc ] || ka+=(-S /System/Library/KernelCollections/SystemKernelExtensions.kc)
    session_bounded 300 "$PRIVATE/live-kc-build.txt" kmutil create -n aux --volume-root / "${ka[@]}" \
        -B /System/Library/KernelCollections/BootKernelExtensions.kc --repository "$repo" \
        -A "$work/auxkc" -z || die 'Full-repository KC build failed; original files unchanged.'
    session_bounded 30 "$PRIVATE/live-kc-inspect.txt" kmutil inspect -a x86_64 -A "$work/auxkc" || die 'Cannot inspect candidate KC.'
    # Require every original top-level extension, rather than silently building
    # an AuxKC containing only our two bundles and dropping unrelated drivers.
    for candidate in /Library/Extensions/*.kext "$repo/NMXGPU.kext" "$repo/NMXAccel.kext"; do
        [ -d "$candidate" ] || continue
        label=$(plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist")
        grep -Fq "$label" "$PRIVATE/live-kc-inspect.txt" || die "Candidate KC omits $label; originals unchanged."
    done
    ditto "$repo/NMXGPU.kext" "$work/nmxgpu"
    ditto "$repo/NMXAccel.kext" "$work/nmxaccel"
    ditto "$repo/NMXGPU.kext" "$work/cachegpu"
    ditto "$repo/NMXAccel.kext" "$work/cacheaccel"
    ditto "$ROOT/components/firmware/i915" "$work/firmware"
    cp "$ROOT/components/firmware/LICENSES/LICENSE.i915" "$work/license"
    ditto "$ROOT/components/Library/GPUBundles/nvmtl" "$(prepared_path runtime)"
    ditto "$ROOT/components/Library/GPUBundles/NVMTLDriver.bundle" "$(prepared_path frontend)"
    cp "$HERE/com.uhd770.mvp.session-root.plist" "$work/rootjob"
    mkdir -m 755 "$ROOT/session-tools"
    cp "$HERE/session-user.sh" "$HERE/session-lib.sh" "$ROOT/session-tools/"
    chmod 644 "$ROOT/session-tools/"*.sh
    # Local x86 CLI executables have no developer signature. Sign only derived
    # copies, retain their original bytes and record the transformation.
    mkdir "$ROOT/derived-probes"; chmod 755 "$ROOT/derived-probes"
    local derived
    for key in uhd770-compute-probe uhd770-metal-probe; do
        derived=$(session_derived_probe_name "$key")
        cp "$ROOT/components/probe/$key" "$ROOT/derived-probes/$derived"
        codesign --force --sign - "$ROOT/derived-probes/$derived" >> "$PRIVATE/probe-signatures.txt" 2>&1
        codesign --verify --strict "$ROOT/derived-probes/$derived" >> "$PRIVATE/probe-signatures.txt" 2>&1
        chmod 755 "$ROOT/derived-probes/$derived"
        shasum -a 256 "$ROOT/components/probe/$key" "$ROOT/derived-probes/$derived" >> "$PRIVATE/probe-signatures.txt"
    done
    # Complete every permission/link/signature/ordinary-user gate before the
    # first live rename. Never recurse chmod through the signed AIR symlink.
    : > "$PRIVATE/prepared-check.txt"
    while IFS='|' read -r key target; do
        prepare_parent "$target"
        [ ! -L "$target" ] || die "A live target is a symlink; preserved: $target"
        prepared=$(prepared_path "$key")
        printf 'normalizing=%s path=%s\n' "$key" "$prepared" >> "$PRIVATE/prepared-check.txt"
        session_tree_permissions "$prepared" readable || die "Cannot normalize prepared $key; no live file changed."
    done < <(targets)
    session_tree_permissions "$ROOT/session-tools" readable || die 'Cannot normalize selected-user session tools.'
    session_tree_permissions "$ROOT/derived-probes" readable || die 'Cannot normalize derived diagnostic executables.'
    check_runtime "$work/Library/GPUBundles" "$PRIVATE/prepared-runtime" || die 'Prepared runtime links/signatures failed; no live file changed.'
    for key in nmxgpu nmxaccel; do
        session_bounded 20 "$PRIVATE/prepared-$key-signature.txt" codesign --verify --strict "$(prepared_path "$key")" || die "Prepared $key signature failed; no live file changed."
    done
    session_bounded 20 "$PRIVATE/user-entrypoint-preflight.txt" \
        sudo -n -u "#$uid" /bin/bash -p "$ROOT/session-tools/session-user.sh" preflight || die 'Selected-user manual entry preflight failed; no live file changed.'
    local user_preflight="$home/Library/Logs/UHD770MVP/preflight-$current.txt"
    [ -f "$user_preflight" ] && [ ! -L "$user_preflight" ] && [ "$(stat -f '%u' "$user_preflight")" = "$uid" ] || die 'Selected-user entry did not produce its preflight marker.'
    grep -qx "boot=$current" "$user_preflight" && grep -qx 'user_job_entrypoint=passed' "$user_preflight" || die 'Selected-user entry preflight failed.'
    cp "$user_preflight" "$PRIVATE/user-job-preflight.txt"
    session_bounded 20 "$PRIVATE/user-payload-preflight.txt" sudo -n -u "#$uid" /bin/bash -p -c \
        'for item do [ -r "$item" ] || exit 64; done; [ -x "$1" ] && [ -x "$2" ]' _ \
        "$ROOT/derived-probes/uhd770-compute-probe" "$ROOT/derived-probes/$(session_derived_probe_name uhd770-metal-probe)" \
        "$ROOT/components/Library/GPUBundles/nvmtl/libvulkan.1.dylib" \
        "$ROOT/components/Library/GPUBundles/nvmtl/libvulkan_intel.dylib" \
        "$ROOT/components/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver" \
        || die 'Selected-user payload readability preflight failed; no live file changed.'
    [ ! -e /Library/LaunchDaemons/$LABEL.plist ] && [ ! -L /Library/LaunchDaemons/$LABEL.plist ] && \
        [ ! -e /Library/LaunchAgents/$LABEL.plist ] && [ ! -L /Library/LaunchAgents/$LABEL.plist ] || die 'An unrelated session job exists.'
    session_bounded 5 "$PRIVATE/root-job-domain-before.txt" launchctl print system || die 'Cannot inspect the launchd system domain.'
    if session_bounded 5 "$PRIVATE/root-job-before.txt" launchctl print "system/$LABEL"; then die 'A root session job is already registered; preserved.'; fi
    printf 'prepared_payloads=passed\n' >> "$PRIVATE/prepared-check.txt"
    printf 'installing\n' > "$PUBLIC/state.txt"
    while IFS='|' read -r key target; do
        prepared=$(prepared_path "$key")
        if [ "$key" = auxkc ]; then
            # The private-repository KC proves linkage only. Its bundle paths
            # name staging copies, so it must not become the boot collection.
            # Match the previously working installer: build from final kext
            # locations after their journaled replacement, preserving the old
            # live KC until this output and its embedded paths both pass.
            prepared="$work/auxkc-installed"
            session_bounded 300 "$PRIVATE/installed-kc-build.txt" kmutil create -n aux --volume-root / "${ka[@]}" \
                -B /System/Library/KernelCollections/BootKernelExtensions.kc --repository /Library/Extensions \
                -A "$prepared" -z || die 'Installed-repository KC build failed; restoring original files.'
            session_bounded 30 "$PRIVATE/installed-kc-inspect.txt" kmutil inspect -a x86_64 -A "$prepared" \
                || die 'Cannot inspect the final KC; restoring original files.'
            for candidate in /Library/Extensions/*.kext; do
                [ -d "$candidate" ] || continue
                label=$(plutil -extract CFBundleIdentifier raw -o - "$candidate/Contents/Info.plist")
                awk -F '\t' -v id="$label" -v path="$candidate" \
                    '$1 == id && $3 == path { found=1 } END { exit !found }' "$PRIVATE/installed-kc-inspect.txt" \
                    || die "Final KC does not name the installed bundle $candidate; restoring original files."
            done
            session_tree_permissions "$prepared" readable || die 'Cannot normalize final KC; restoring original files.'
        fi
        session_replace "$JOURNAL" "$key" "$target" "$prepared"
    done < <(targets)
    check_runtime /Library/GPUBundles "$PRIVATE/installed-runtime" || die 'Installed runtime links/signatures failed; rollback required.'
    # Only recovery/logging starts automatically. No user LaunchAgent is
    # installed: explicit manual execution is required for compute submission.
    ROOT_JOB_OWNED=1
    launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist
    elapsed=0
    while [ ! -f "$PUBLIC/root-preflight-$current.txt" ] && [ "$elapsed" -lt 20 ]; do sleep 1; elapsed=$((elapsed + 1)); done
    grep -qx 'root_job_entrypoint=passed' "$PUBLIC/root-preflight-$current.txt" || die 'Root recovery job entry point did not pass its live preflight.'
    restore_optout || die 'Independent opt-out check failed before arming.'
    [ "$(hash "$cfg")" = "$(property safe_hash)" ] || die 'USB changed before arming.'
    [ ! -e "$cfg.uhd770-pending" ] && [ ! -L "$cfg.uhd770-pending" ] || die 'A pending USB config already exists; preserved.'
    cp "$KIT/session-target/config.test.plist" "$cfg.uhd770-pending"
    [ "$(hash "$cfg.uhd770-pending")" = "$(property test_hash)" ] || die 'Test config copy failed.'
    mv -f "$cfg.uhd770-pending" "$cfg"
    session_bounded 30 "$PRIVATE/arm-sync.txt" sync || die 'Cannot confirm test config flush.'
    printf 'armed\n' > "$PUBLIC/state.txt"
    printf '\nPREPARED. Restart ONCE through the same 1401 USB and choose macOS 15.\n'
    printf 'Log in normally. GPU takeover waits 60 seconds after firmware availability.\n'
    printf 'The next-boot opt-out is restored automatically. No compute test starts at login.\n'
    printf 'After login, run this kit Run-UHD770-Test.command with sudo /bin/bash -p when YOU choose.\n'
    printf 'If black, wait 6 minutes after signal loss, then restart through the same USB.\n'
    printf 'If that recovery boot fails, return to Windows and run the package Restore-UHD770.ps1.\n'
    printf 'No automatic reboot or claim of acceleration success.\n'
}

boot() {
    safe_directory "$ROOT"; safe_directory "$PRIVATE"; safe_directory "$PUBLIC"
    local current prepare_boot args attempt recovered=0
    current=$(sysctl -n kern.bootsessionuuid); prepare_boot=$(property preparation_boot)
    case "$current" in ''|*[!a-zA-Z0-9-]*) die 'Invalid current boot identity.' ;; esac
    if [ "$current" = "$prepare_boot" ]; then
        printf 'root_job_entrypoint=passed\nboot=%s\n' "$current" > "$PUBLIC/root-preflight-$current.txt"
        chmod 644 "$PUBLIC/root-preflight-$current.txt"
        exit 0
    fi
    # Restore the persistent USB opt-out first, even on an aborted test boot.
    # Disk Arbitration/USB publication can lag the root launchd domain. Retry
    # finite reads/mounts before giving up; never overwrite a changed config.
    for attempt in 1 2 3; do
        if restore_optout; then recovered=1; break; fi
        sleep 2
    done
    if [ "$recovered" -eq 1 ]; then
        printf 'next_boot_optout=verified\nboot=%s\n' "$current" > "$PUBLIC/recovery-$current.txt"
    else
        printf 'next_boot_optout=NOT_VERIFIED\nboot=%s\n' "$current" > "$PUBLIC/recovery-$current.txt"
        chmod 644 "$PUBLIC/recovery-$current.txt"
        automatic_export "$current"
        exit 1
    fi
    chmod 644 "$PUBLIC/recovery-$current.txt"
    [ "$(cat "$PUBLIC/state.txt")" = armed ] || exit 0
    args=$(sysctl -n kern.bootargs)
    case " $args " in
        *' -nvoff '*) printf 'recovered\n' > "$PUBLIC/state.txt"; automatic_export "$current"; exit 0 ;;
        *' nmxintel=1 '*) ;;
        *) automatic_export "$current"; exit 0 ;;
    esac
    # This task never invokes a user entry point. Leaving it armed lets the
    # human start later without an arbitrary login-to-test countdown.
    printf 'boot=%s\ncompute=not_started\ntrigger=manual_only\n' "$current" > "$PUBLIC/waiting-for-manual-$current.txt"
    chmod 644 "$PUBLIC/waiting-for-manual-$current.txt"
    printf 'Recovery checked. Compute is waiting for explicit Run-UHD770-Test.command.\n'
}

# An explicit root invocation owns capture/export; GPU work runs only as the
# selected ordinary user. The boot job above cannot reach this function.
run_manual_test() {
    safe_directory "$ROOT"; safe_directory "$PRIVATE"; safe_directory "$PUBLIC"
    local current uid code=0 report ready='' count=0
    current=$(sysctl -n kern.bootsessionuuid)
    case "$current" in ''|*[!a-zA-Z0-9-]*) die 'Invalid boot identity.' ;; esac
    [ "$current" != "$(property preparation_boot)" ] || die 'Restart through the prepared USB before running compute.'
    uid=$(property user_uid)
    [ "${SUDO_UID:-0}" = "$uid" ] || die 'Use sudo from the same ordinary account that prepared this test.'
    [ "$(cat "$PUBLIC/state.txt")" = armed ] || die 'This session is not armed, or its test already ended.'
    local args
    args=$(sysctl -n kern.bootargs)
    case " $args " in *' -nvoff '*) die 'This is an opt-out recovery boot; compute was not started.' ;; esac
    case " $args " in *' nmxintel=1 '*) ;; *) die 'The prepared Intel opt-in is not active in this boot.' ;; esac
    restore_optout || die 'Next-boot recovery cannot be verified; compute was not started.'
    printf 'next_boot_optout=verified\nboot=%s\n' "$current" > "$PUBLIC/recovery-$current.txt"
    chmod 644 "$PUBLIC/recovery-$current.txt"
    mkdir -m 700 "$PRIVATE/manual-$current" || die 'A manual test was already started in this boot; preserved.'
    MANUAL_ACTIVE=1
    printf 'manual_boot=%s\ncompute_trigger=explicit_command\n' "$current" > "$PRIVATE/manual-current.txt"
    # An empty IORegistry service is not proof that its kext was never loaded.
    # Keep the actual loaded UUIDs from this test boot, including query failures;
    # a later -nvoff recovery boot cannot provide this missing evidence.
    session_bounded 10 "$PRIVATE/manual-loaded-before-$current.txt" kmutil showloaded || :
    printf '\nManual test requested. Verifying a fresh persistent recorder before compute...\n'
    # A person may start long after the boot recorder has finished. Record the
    # old directory names so a new capture is required, never stale evidence.
    : > "$PRIVATE/manual-$current/previous-captures.txt"
    for report in /private/var/log/UHD770MVP/session-*; do
        if [ -d "$report" ]; then printf '%s\n' "$report" >> "$PRIVATE/manual-$current/previous-captures.txt"; fi
    done
    session_bounded 10 "$PRIVATE/manual-capture-start-$current.txt" \
        launchctl kickstart -k system/com.uhd770.mvp.capture || die 'Cannot start the recorder; compute was not started.'
    while [ "$count" -lt "$MANUAL_STARTUP_LIMIT" ]; do
        for report in /private/var/log/UHD770MVP/session-*; do
            [ -d "$report" ] && [ ! -L "$report" ] || continue
            grep -Fxq "$report" "$PRIVATE/manual-$current/previous-captures.txt" && continue
            [ -f "$report/boot-identity.txt" ] && [ -f "$report/stages.txt" ] || continue
            grep -Fxq "kern.bootsessionuuid: $current" "$report/boot-identity.txt" || continue
            grep -q 'heartbeat stream_alive=1' "$report/stages.txt" || continue
            grep -Eq 'startup_failed|kernel-stream exited|sync_failed|collector_end' "$report/stages.txt" && continue
            ready=$report; break
        done
        [ -z "$ready" ] || break
        sleep 1; count=$((count + 1))
    done
    [ -n "$ready" ] || die 'The new recorder did not confirm startup; compute was not started.'
    MANUAL_CAPTURE=$ready
    printf 'capture=%s\ncompute=explicit_manual\n' "$ready" > "$PRIVATE/manual-capture-$current.txt"
    printf 'manual_authorization=active\nboot=%s\nuid=%s\n' "$current" "$uid" > "$PRIVATE/manual-$current/authorization.pending"
    chmod 644 "$PRIVATE/manual-$current/authorization.pending"
    mv "$PRIVATE/manual-$current/authorization.pending" "$PUBLIC/manual-authorization-$current.txt"
    printf 'Recorder is ready. Waiting for driver checks, then Vulkan and Metal in this terminal.\n'
    : > "$PRIVATE/manual-coordinator-$current.txt"
    tail -n +1 -f "$PRIVATE/manual-coordinator-$current.txt" & FOLLOWER=$!
    session_bounded_group "$MANUAL_COORDINATOR_LIMIT" "$PRIVATE/manual-coordinator-$current.txt" \
        sudo -n -u "#$uid" /bin/bash -p "$ROOT/session-tools/session-user.sh" manual || code=$?
    kill -TERM "$FOLLOWER" 2>/dev/null || :; FOLLOWER=''
    session_bounded "$MANUAL_LOADED_AFTER_LIMIT" "$PRIVATE/manual-loaded-after-$current.txt" kmutil showloaded || :
    if [ "$code" -eq 124 ]; then
        printf 'boot=%s\ntrigger=manual-timeout\npartial=true\n' "$current" > "$PUBLIC/deadline-$current.txt"
        chmod 644 "$PUBLIC/deadline-$current.txt"
    fi
    printf '\nManual coordinator exit=%s. Compute is stopped; observing the display before exporting...\n' "$code"
    printf 'manual_authorization=closed\nboot=%s\n' "$current" > "$PUBLIC/manual-authorization-$current.txt"
    local observe=$MANUAL_OBSERVE_LIMIT
    if [ "$code" -ne 0 ] && [ "$code" -ne 124 ] && \
        ! grep -Eq '^dispatch [0-9]+:' "$PRIVATE/manual-coordinator-$current.txt"; then
        observe=$MANUAL_OBSERVE_SHORT_LIMIT
        printf 'No probe reached GPU submission; shortening the observation.\n'
    fi
    session_observe_capture "$MANUAL_CAPTURE" "$current" "$observe" "$PRIVATE/post-test-observation-$current.txt"
    finish_capture "$current" "$MANUAL_CAPTURE"
    printf 'finished\n' > "$PUBLIC/state.txt"
    printf 'boot=%s\nmanual_exit=%s\n' "$current" "$code" > "$PUBLIC/manual-result-$current.txt"
    chmod 644 "$PUBLIC/manual-result-$current.txt"
    MANUAL_ACTIVE=0
    export_all
    AUTO_EXPORT_ATTEMPTED=1
    return "$code"
}

failed() {
    local code=$1
    trap - EXIT INT TERM HUP
    set +e
    [ -z "$FOLLOWER" ] || kill -TERM "$FOLLOWER" 2>/dev/null || :
    if [ "$MODE" = test ] && [ "$MANUAL_ACTIVE" -eq 1 ]; then
        local manual_boot
        manual_boot=$(sysctl -n kern.bootsessionuuid)
        printf 'boot=%s\ntrigger=manual-interrupted\npartial=true\n' "$manual_boot" > "$PUBLIC/deadline-$manual_boot.txt"
        printf 'manual_authorization=closed\nboot=%s\n' "$manual_boot" > "$PUBLIC/manual-authorization-$manual_boot.txt"
        chmod 644 "$PUBLIC/deadline-$manual_boot.txt" "$PUBLIC/manual-authorization-$manual_boot.txt"
        session_stop_group
        finish_capture "$manual_boot" "$MANUAL_CAPTURE"
        printf 'finished\n' > "$PUBLIC/state.txt"
        printf 'boot=%s\nmanual_exit=%s\n' "$manual_boot" "$code" > "$PUBLIC/manual-result-$manual_boot.txt"
        chmod 644 "$PUBLIC/manual-result-$manual_boot.txt"
    fi
    if [ "$MODE" = prepare ] && [ "$PREPARATION_OWNED" -eq 1 ]; then
        local safe_code=0 restore_code=0 job_code=0
        stop_owned_root_job || job_code=$?
        if [ "$USB_SELECTION_OWNED" -eq 1 ]; then restore_optout; safe_code=$?; fi
        if [ "$job_code" -eq 0 ]; then restore_files; restore_code=$?; else restore_code=1; fi
        printf 'failed\n' > "$PUBLIC/state.txt"
        printf 'prepare_exit=%s\noptout_restore_exit=%s\nfile_restore_exit=%s\nroot_job_stop_exit=%s\n' "$code" "$safe_code" "$restore_code" "$job_code" > "$PRIVATE/failure.txt"
        printf 'Preparation stopped. Recovery status is in the exported report; do not reboot for a test.\n' >&2
    fi
    if [ "$AUTO_EXPORT_ATTEMPTED" -eq 0 ]; then export_all || :; fi
    if [ "$LOCK_OWNED" -eq 1 ]; then rmdir "$LOCK" || :; fi
    exit "$code"
}
trap 'code=$?; if [ "$code" -ne 0 ]; then failed "$code"; elif [ "$LOCK_OWNED" -eq 1 ]; then rmdir "$LOCK"; fi' EXIT
trap 'exit 130' INT TERM HUP
case "$MODE" in
    prepare) prepare ;;
    test) run_manual_test ;;
    export) export_all ;;
    restore)
        safe_directory "$ROOT"; safe_directory "$PRIVATE"
        restore_optout
        restore_report=$(mktemp -d "$PRIVATE/restore-job-stop.XXXXXX")
        printf 'Restore job-stop diagnostics: %s\n' "$restore_report"
        # New manual sessions install no user agent. A legacy registration must
        # be reviewed explicitly rather than silently left running during replay.
        [ ! -e "/Library/LaunchAgents/$LABEL.plist" ] && [ ! -L "/Library/LaunchAgents/$LABEL.plist" ] || \
            die 'A legacy user-session plist is installed; recovery evidence preserved before file replay.'
        restore_uid=$(property user_uid)
        case "$restore_uid" in ''|*[!0-9]*) die 'Invalid selected-user identity.' ;; esac
        session_bounded 2 "$restore_report/gui-domain.txt" launchctl print "gui/$restore_uid" || \
            die 'Cannot verify the selected login domain; no original files were replayed.'
        restore_gui_code=0
        session_bounded 2 "$restore_report/gui-session.txt" launchctl print "gui/$restore_uid/$LABEL" || restore_gui_code=$?
        [ "$restore_gui_code" -ne 0 ] && [ "$restore_gui_code" -ne 124 ] && \
            grep -Fq "Could not find service \"$LABEL\" in domain" "$restore_report/gui-session.txt" || \
            die 'A legacy user-session job is present or unknown; no original files were replayed.'
        restore_stop_code=0
        session_stop_recorder "$LABEL" "/Library/LaunchDaemons/$LABEL.plist" \
            "$ROOT/incoming/tools/session.sh" "$restore_report" || restore_stop_code=$?
        printf 'helper_exit=%s\n' "$restore_stop_code" > "$restore_report/helper-exit.txt"
        [ "$restore_stop_code" -eq 0 ] || die 'Root recovery job stop was not verified; no original files were replayed.'
        restore_files
        printf 'restored\n' > "$PUBLIC/state.txt"
        sync
        export_all
        printf 'Original files and USB opt-out restored for the next boot; no kext was unloaded.\n'
        ;;
    boot) boot ;;
esac
