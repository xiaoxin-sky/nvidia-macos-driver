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
LOCK=/private/var/run/com.uhd770.mvp.prepare.lock
LOCK_OWNED=0
KEY='NVRAM.Add.7C436110-AB2A-4BBB-A880-FE41995C9F82.boot-args'
KIT=$(cd "$(dirname "$0")/.." && pwd -P)
HERE="$KIT/tools"
case "$0" in */incoming/tools/session.sh) KIT="$ROOT/incoming"; HERE="$KIT/tools" ;; esac

die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
usage() {
    printf '%s\n' 'Usage: sudo /bin/bash -p tools/session.sh prepare|export|restore' \
      'prepare: automatic staging, recorder validation, matched install and ONE next-boot test.' \
      'export: collect all surviving system and selected-user diagnostic evidence.' \
      'restore: restore the USB opt-out and journaled original files/KC; takes effect next boot.' \
      'Requires the machine-specific session-target payload. Never reboots automatically.'
}
[ "${1:-}" != --help ] || { usage; exit 0; }
[ "$#" -eq 1 ] || { usage >&2; exit 64; }
MODE=$1
case "$MODE" in prepare|export|restore|boot) ;; *) usage >&2; exit 64 ;; esac
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
      'rootjob|/Library/LaunchDaemons/com.uhd770.mvp.session.plist' \
      'userjob|/Library/LaunchAgents/com.uhd770.mvp.session.plist'
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

export_all() {
    local output uid account home
    output=$(mktemp -d /Users/Shared/UHD770MVP-session-reports.XXXXXX)
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
    fi
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
    session_bounded 5 "$PRIVATE/optout-sync.txt" sync || return 1
}

restore_files() {
    local key target code=0
    while IFS='|' read -r key target; do
        session_restore_one "$JOURNAL" "$key" "$target" || code=1
    done < <(targets)
    return "$code"
}

prepare() {
    local args current uid account volume='' cfg candidate n=0 label uuid
    args=$(sysctl -n kern.bootargs)
    case " $args " in *' -nvoff '*) ;; *) die 'Current boot must contain -nvoff.' ;; esac
    case " $args " in *' nmxintel='*|*' nmxdiagdelay='*) die 'Remove stale test boot arguments before preparing.' ;; esac
    uid=${SUDO_UID:-0}
    case "$uid" in ''|*[!0-9]*) die 'Invalid login account.' ;; esac
    [ "$uid" -ge 501 ] || die 'Launch through sudo from the intended ordinary macOS account.'
    safe_directory /private/var/run
    mkdir -m 700 "$LOCK" || die 'Another preparation or an interrupted lock exists; preserved.'
    LOCK_OWNED=1
    account=$(id -nu "$uid")
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
    mkdir -m 700 "$PRIVATE" "$JOURNAL"
    mkdir -m 755 "$PUBLIC"
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
    printf 'Checking the automatic recorder for one 300-second normal-desktop session...\n'
    while [ "$elapsed" -lt 330 ]; do
        for report in /private/var/log/UHD770MVP/session-*; do
            if session_recorder_valid "$report" "$current"; then found=$report; break; fi
        done
        [ -z "$found" ] || break
        sleep 5; elapsed=$((elapsed + 5))
    done
    [ -n "$found" ] || die 'Recorder did not pass; no live driver was replaced or enabled.'
    printf 'recorder=%s\nnormal_desktop_capture=passed\n' "$found" > "$PRIVATE/recorder-check.txt"
    # Use ten minutes on the next boot: attach delay plus both bounded probes.
    /usr/libexec/PlistBuddy -c 'Set :ProgramArguments:3 600' /Library/LaunchDaemons/com.uhd770.mvp.capture.plist
    local work="$PRIVATE/prepared" repo="$PRIVATE/repository" key target
    mkdir "$work" "$repo"
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
    ditto "$ROOT/components/Library/GPUBundles/nvmtl" "$work/runtime"
    ditto "$ROOT/components/Library/GPUBundles/NVMTLDriver.bundle" "$work/frontend"
    cp "$HERE/com.uhd770.mvp.session-root.plist" "$work/rootjob"
    cp "$HERE/com.uhd770.mvp.session-user.plist" "$work/userjob"
    mkdir -m 755 "$ROOT/session-tools"
    cp "$HERE/session-user.sh" "$HERE/session-lib.sh" "$ROOT/session-tools/"
    chmod 644 "$ROOT/session-tools/"*.sh
    # Local x86 CLI executables have no developer signature. Sign only derived
    # copies, retain their original bytes and record the transformation.
    mkdir "$ROOT/derived-probes"; chmod 755 "$ROOT/derived-probes"
    for key in uhd770-compute-probe uhd770-metal-probe; do
        cp "$ROOT/components/probe/$key" "$ROOT/derived-probes/$key"
        codesign --force --sign - "$ROOT/derived-probes/$key" >> "$PRIVATE/probe-signatures.txt" 2>&1
        codesign --verify --strict "$ROOT/derived-probes/$key" >> "$PRIVATE/probe-signatures.txt" 2>&1
        chmod 755 "$ROOT/derived-probes/$key"
        shasum -a 256 "$ROOT/components/probe/$key" "$ROOT/derived-probes/$key" >> "$PRIVATE/probe-signatures.txt"
    done
    # Reject collisions before the first live rename, then journal every write.
    [ ! -e /Library/LaunchDaemons/$LABEL.plist ] && [ ! -e /Library/LaunchAgents/$LABEL.plist ] || die 'An unrelated session job exists.'
    printf 'installing\n' > "$PUBLIC/state.txt"
    while IFS='|' read -r key target; do
        prepare_parent "$target"
        chown -hR root:wheel "$work/$key"
        chmod -RN "$work/$key"
        if [ -d "$work/$key" ]; then chmod -R go-w,a+rX "$work/$key"; else chmod 644 "$work/$key"; fi
        session_replace "$JOURNAL" "$key" "$target" "$work/$key"
    done < <(targets)
    # Register only the root recovery job now. In this boot it is a no-op;
    # launchd will start both root recovery and the user agent at the next boot.
    launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist
    restore_optout || die 'Independent opt-out check failed before arming.'
    [ "$(hash "$cfg")" = "$(property safe_hash)" ] || die 'USB changed before arming.'
    [ ! -e "$cfg.uhd770-pending" ] && [ ! -L "$cfg.uhd770-pending" ] || die 'A pending USB config already exists; preserved.'
    cp "$KIT/session-target/config.test.plist" "$cfg.uhd770-pending"
    [ "$(hash "$cfg.uhd770-pending")" = "$(property test_hash)" ] || die 'Test config copy failed.'
    mv -f "$cfg.uhd770-pending" "$cfg"
    session_bounded 5 "$PRIVATE/arm-sync.txt" sync || die 'Cannot confirm test config flush.'
    printf 'armed\n' > "$PUBLIC/state.txt"
    printf '\nPREPARED. Restart ONCE through the same 1401 USB and choose macOS 15.\n'
    printf 'Log in normally. GPU takeover waits 180 seconds after firmware availability.\n'
    printf 'The next-boot opt-out is restored automatically; Vulkan then Metal run only if initialization succeeds.\n'
    printf 'Allow up to 10 minutes. If black, wait 6 minutes after signal loss, then restart through the same USB.\n'
    printf 'If that recovery boot fails, return to Windows and run the package Restore-UHD770.ps1.\n'
    printf 'No automatic reboot or claim of acceleration success.\n'
}

boot() {
    safe_directory "$ROOT"; safe_directory "$PRIVATE"; safe_directory "$PUBLIC"
    local current prepare_boot args
    current=$(sysctl -n kern.bootsessionuuid); prepare_boot=$(property preparation_boot)
    [ "$current" != "$prepare_boot" ] || exit 0
    # Restore the persistent USB opt-out first, even on an aborted test boot.
    if restore_optout; then
        printf 'next_boot_optout=verified\nboot=%s\n' "$current" > "$PUBLIC/recovery-$current.txt"
    else
        printf 'next_boot_optout=NOT_VERIFIED\nboot=%s\n' "$current" > "$PUBLIC/recovery-$current.txt"
        chmod 644 "$PUBLIC/recovery-$current.txt"
        export_all
        exit 1
    fi
    chmod 644 "$PUBLIC/recovery-$current.txt"
    [ "$(cat "$PUBLIC/state.txt")" = armed ] || exit 0
    args=$(sysctl -n kern.bootargs)
    case " $args " in
        *' -nvoff '*) printf 'recovered\n' > "$PUBLIC/state.txt"; export_all; exit 0 ;;
        *' nmxintel=1 '*) ;;
        *) export_all; exit 0 ;;
    esac
    # Current recorder/probes write directly to disk. A later safe boot exports
    # their partial files even if this wait is interrupted by a kernel failure.
    sleep 600
    printf 'finished\n' > "$PUBLIC/state.txt"
    export_all
}

failed() {
    local code=$1
    trap - EXIT INT TERM HUP
    set +e
    if [ "$MODE" = prepare ] && [ -f "$PLAN" ]; then
        restore_optout
        local safe_code=$?
        restore_files
        local restore_code=$?
        printf 'failed\n' > "$PUBLIC/state.txt"
        printf 'prepare_exit=%s\noptout_restore_exit=%s\nfile_restore_exit=%s\n' "$code" "$safe_code" "$restore_code" > "$PRIVATE/failure.txt"
        printf 'Preparation stopped. Recovery status is in the exported report; do not reboot for a test.\n' >&2
    fi
    export_all || :
    if [ "$LOCK_OWNED" -eq 1 ]; then rmdir "$LOCK" || :; fi
    exit "$code"
}
trap 'code=$?; if [ "$code" -ne 0 ]; then failed "$code"; elif [ "$LOCK_OWNED" -eq 1 ]; then rmdir "$LOCK"; fi' EXIT
trap 'exit 130' INT TERM HUP
case "$MODE" in
    prepare) prepare ;;
    export) export_all ;;
    restore)
        safe_directory "$ROOT"; safe_directory "$PRIVATE"
        restore_optout
        launchctl bootout "system/$LABEL" 2>/dev/null || :
        # Remove the loaded agent in the selected login domain, if any. Do not
        # touch other users or unload an active GPU driver in this boot.
        launchctl bootout "gui/$(property user_uid)/$LABEL" 2>/dev/null || :
        restore_files
        printf 'restored\n' > "$PUBLIC/state.txt"
        sync
        export_all
        printf 'Original files and USB opt-out restored for the next boot; no kext was unloaded.\n'
        ;;
    boot) boot ;;
esac
