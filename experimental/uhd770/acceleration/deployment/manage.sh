#!/bin/bash -p
# Target preflight/staging and recorder management only. This tool never writes
# a live kernel collection, copies a kext into /Library/Extensions, modifies an
# EFI/NVRAM value, loads a driver, or executes either GPU probe.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH GLOBIGNORE
umask 077
ROOT='/Library/Application Support/UHD770MVP'
LOGROOT='/private/var/log/UHD770MVP'
LABEL=com.uhd770.mvp.capture
PLIST="/Library/LaunchDaemons/$LABEL.plist"
KIT=$(cd "$(dirname "$0")/.." && pwd -P)

die() { printf 'REFUSED: %s\n' "$*" >&2; exit 1; }
usage() {
    printf '%s\n' 'Usage: sudo /bin/bash -p tools/manage.sh COMMAND' \
        '  stage              Verify and privately stage candidates; isolated KC preflight only.' \
        '  install-recorder   Register/start the read-only 300-second boot recorder.' \
        '  recorder-status    Inspect the recorder without starting a test.' \
        '  remove-recorder    Unregister this recorder; keep its logs.' \
        '  export             Copy surviving reports to a new /Users/Shared directory.' \
        'No driver installation or GPU enable command exists in this tool.'
}

# Each read/build subprocess has a finite parent budget. No dependency on GNU
# timeout, Xcode, Python or a network service on the target Mac.
bounded() {
    local limit=$1 output=$2 child elapsed=0 status
    shift 2
    "$@" > "$output" 2>&1 &
    child=$!
    while kill -0 "$child" 2>/dev/null && [ "$elapsed" -lt $((limit * 10)) ]; do
        sleep 0.1
        elapsed=$((elapsed + 1))
    done
    if kill -0 "$child" 2>/dev/null; then
        printf '\ncommand_timeout_seconds=%s\n' "$limit" >> "$output"
        kill -TERM "$child" 2>/dev/null || :
        sleep 1
        kill -KILL "$child" 2>/dev/null || :
        disown "$child" 2>/dev/null || :
        return 124
    fi
    if wait "$child"; then status=0; else status=$?; fi
    printf '\ncommand_exit_status=%s\n' "$status" >> "$output"
    return "$status"
}

safe_directory() {
    local path=$1 uid mode
    [ -d "$path" ] && [ ! -L "$path" ] || die "Unsafe directory: $path"
    uid=$(stat -f '%u' "$path")
    mode=$(stat -f '%Lp' "$path")
    [ "$uid" = 0 ] && [ $((8#$mode & 0022)) -eq 0 ] || die "Unsafe directory owner/mode: $path"
}

check_optout() {
    local args
    args=$(sysctl -n kern.bootargs) || die 'Cannot read actual current boot arguments.'
    case " $args " in *' -nvoff '*) ;; *) die 'Stage requires a current boot with persistent -nvoff; no setting was changed.' ;; esac
}

verify_package() {
    local path=$1 report=$2
    [ -f "$path/SHA256SUMS" ] && [ ! -L "$path/SHA256SUMS" ] || die 'Missing package checksum manifest.'
    bounded 120 "$report" /bin/bash -p -c 'cd "$1" && exec /usr/bin/shasum -a 256 --strict -c SHA256SUMS' _ "$path" || die 'Preparation package digest check failed.'
}

snapshot_package() {
    local line name count=0 bytes=0 size target
    mkdir -m 700 "$ROOT/incoming"
    bounded 10 "$ROOT/copy-current.txt" cp "$KIT/SHA256SUMS" "$ROOT/incoming/SHA256SUMS" || die 'Cannot copy manifest.'
    # Copy only manifest members, never recursively copy the caller's directory
    # or old reports. Portable names exclude shell escapes/ambiguous separators.
    while IFS= read -r line; do
        [[ "$line" =~ ^[0-9a-f]{64}\ \ [A-Za-z0-9_./-]+$ ]] || die 'Malformed/nonportable package checksum line.'
        name=${line:66}
        case "/$name/" in *'/../'*|*'/./'*|*'//'*) die 'Unsafe package path.' ;; esac
        case "$name" in /*|SHA256SUMS) die 'Unexpected package member.' ;; esac
        [ -f "$KIT/$name" ] && [ ! -L "$KIT/$name" ] || die "Missing/linked source: $name"
        count=$((count + 1))
        size=$(stat -f '%z' "$KIT/$name") || die 'Cannot measure package member.'
        bytes=$((bytes + size))
        [ "$count" -le 256 ] && [ "$bytes" -le 268435456 ] || die 'Preparation package exceeds its bounded size/count.'
        target="$ROOT/incoming/$name"
        [ ! -e "$target" ] && [ ! -L "$target" ] || die 'Duplicate package member.'
        mkdir -p "$(dirname "$target")"
        bounded 30 "$ROOT/copy-current.txt" cp "$KIT/$name" "$target" || die "Copy failed: $name"
    done < "$ROOT/incoming/SHA256SUMS"
    [ "$count" -gt 0 ] || die 'Empty package checksum manifest.'
}

# Source shared mutations only from the digest-verified root snapshot. The
# download/Desktop KIT may still be writable by the ordinary user, so staging
# must not execute its helper while trying to establish protected ownership.
load_staged_helpers() {
    local helper="$ROOT/incoming/tools/session-lib.sh" owner mode
    safe_directory "$ROOT"; safe_directory "$ROOT/incoming"; safe_directory "$ROOT/incoming/tools"
    [ -f "$helper" ] && [ ! -L "$helper" ] || die 'Missing regular staged session helpers.'
    owner=$(stat -f '%u' "$helper"); mode=$(stat -f '%Lp' "$helper")
    [ "$owner" = 0 ] && [ $((8#$mode & 0022)) -eq 0 ] || die 'Unsafe staged helper owner/mode.'
    . "$helper"
}

isolated_kc() {
    local work="$ROOT/kc-preflight" original signed
    local args=(--allow-missing-kdk -a x86_64)
    mkdir -m 700 "$work" "$work/repository"
    ditto "$ROOT/components/Library/Extensions/NMXGPU.kext" "$work/repository/NMXGPU.kext"
    ditto "$ROOT/components/Library/Extensions/NMXAccel.kext" "$work/repository/NMXAccel.kext"
    original=$(shasum -a 256 "$work/repository/NMXGPU.kext/Contents/MacOS/NMXGPU")
    # Only this derived KC-check copy is signed; the original tar/staged payload
    # stays unchanged, preserving the identity used by later runtime probes.
    bounded 20 "$work/codesign-NMXGPU.txt" codesign --force --sign - "$work/repository/NMXGPU.kext" || return 1
    bounded 20 "$work/codesign-verify-NMXGPU.txt" codesign --verify --strict "$work/repository/NMXGPU.kext" || return 1
    bounded 20 "$work/codesign-verify-NMXAccel.txt" codesign --verify --strict "$work/repository/NMXAccel.kext" || return 1
    signed=$(shasum -a 256 "$work/repository/NMXGPU.kext/Contents/MacOS/NMXGPU")
    printf 'original=%s\nderived_signed=%s\ninstalled=false\n' "$original" "$signed" > "$work/derived-identity.txt"
    session_tree_permissions "$work/repository" sealed || return 1
    [ -s /System/Library/KernelCollections/BootKernelExtensions.kc ] || return 1
    if [ -s /System/Library/KernelCollections/SystemKernelExtensions.kc ]; then
        args+=(-S /System/Library/KernelCollections/SystemKernelExtensions.kc)
    fi
    if [ -f /System/Library/Kernels/kernel ]; then args+=(--kernel /System/Library/Kernels/kernel); fi
    bounded 180 "$work/kmutil-create.txt" kmutil create -n aux --volume-root / "${args[@]}" \
        -B /System/Library/KernelCollections/BootKernelExtensions.kc \
        --repository "$work/repository" \
        -p "$work/repository/NMXGPU.kext" -p "$work/repository/NMXAccel.kext" \
        -A "$work/AuxiliaryKernelExtensions.kc" -z || return 1
    bounded 30 "$work/kmutil-inspect.txt" kmutil inspect -a x86_64 -A "$work/AuxiliaryKernelExtensions.kc" || return 1
    grep -Fq com.nullmoth.NMXGPU "$work/kmutil-inspect.txt" || return 1
    grep -Fq com.nullmoth.NMXAccel "$work/kmutil-inspect.txt" || return 1
    printf 'temporary_KC_linkage=passed\ninstalled=false\nloaded=false\ntrust_verified=false\ngpu_executed=false\n' > "$work/result.txt"
}

stage() {
    check_optout
    safe_directory /Library
    safe_directory '/Library/Application Support'
    [ ! -e "$ROOT" ] && [ ! -L "$ROOT" ] || die 'Private stage already exists; it is not overwritten.'
    local initial_report
    initial_report=$(mktemp /private/tmp/uhd770-verify.XXXXXX)
    verify_package "$KIT" "$initial_report"
    mkdir -m 755 "$ROOT"
    printf 'stage=incomplete\ndriver_installed=false\ngpu_executed=false\n' > "$ROOT/stage-state.txt"
    # Snapshot into root-owned storage before another validation/extraction. The
    # source may be on a Windows USB filesystem without native ownership bits.
    snapshot_package
    verify_package "$ROOT/incoming" "$ROOT/package-verification.txt"
    load_staged_helpers
    session_tree_permissions "$ROOT" sealed || die 'Cannot normalize protected stage permissions.'
    chmod 700 "$ROOT/incoming"
    mkdir "$ROOT/unpacked" "$ROOT/components"
    local name
    for name in kernel userland metal; do
        mkdir "$ROOT/unpacked/$name"
        tar -xzf "$ROOT/incoming/candidate/uhd770-acceleration-$name.tar.gz" -C "$ROOT/unpacked/$name"
        # Build/runtime trees merge; build logs remain component-specific.
        ditto "$ROOT/unpacked/$name/Library" "$ROOT/components/Library"
        if [ -d "$ROOT/unpacked/$name/probe" ]; then ditto "$ROOT/unpacked/$name/probe" "$ROOT/components/probe"; fi
    done
    mkdir "$ROOT/components/firmware"
    tar -xzf "$ROOT/incoming/firmware.tar.gz" -C "$ROOT/components/firmware"
    (cd "$ROOT/components" && shasum -a 256 -c "$ROOT/incoming/runtime-SHA256SUMS") > "$ROOT/runtime-verification.txt" 2>&1
    [ "$(readlink "$ROOT/components/Library/GPUBundles/nvmtl/libvulkan.dylib")" = libvulkan.1.dylib ] || die 'Loader symlink was not preserved.'
    [ "$(readlink "$ROOT/components/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime")" = ../../../nvmtl ] || die 'Signed AIR runtime symlink was not preserved.'
    ditto "$ROOT/incoming/tools/capture" "$ROOT/capture"
    ditto "$ROOT/incoming/tools/probes" "$ROOT/probes"
    cp "$ROOT/incoming/candidate/evidence.json" "$ROOT/evidence.json"
    session_tree_permissions "$ROOT" sealed || die 'Cannot normalize extracted stage permissions.'
    for name in components capture probes; do
        session_tree_permissions "$ROOT/$name" readable || die "Cannot make $name readable without following links."
    done
    chmod 644 "$ROOT/evidence.json"
    chmod 700 "$ROOT/incoming"
    if [ -d "$ROOT/incoming/reference-efi" ]; then
        chmod 700 "$ROOT/incoming/reference-efi"
        chmod 600 "$ROOT/incoming/reference-efi/"*.plist
    fi
    chmod 755 "$ROOT/capture/collector.sh" "$ROOT/probes/run-probe.sh"
    if ! isolated_kc; then
        printf 'stage=kc-preflight-failed\ndriver_installed=false\ngpu_executed=false\n' > "$ROOT/stage-state.txt"
        die "Target KC preflight failed. Original drivers unchanged; keep $ROOT for analysis."
    fi
    printf 'stage=offline-ready\ndriver_installed=false\ntrust_verified=false\ngpu_executed=false\n' > "$ROOT/stage-state.txt"
    printf 'Private staging and temporary KC checks passed. No driver installed or enabled.\n'
}

install_recorder() {
    safe_directory "$ROOT"
    safe_directory "$ROOT/capture"
    safe_directory /Library/LaunchDaemons
    for path in /private /private/var /private/var/log; do safe_directory "$path"; done
    if [ ! -e "$LOGROOT" ] && [ ! -L "$LOGROOT" ]; then mkdir -m 700 "$LOGROOT"; fi
    safe_directory "$LOGROOT"
    [ ! -e "$PLIST" ] && [ ! -L "$PLIST" ] || die 'Recorder plist already exists; inspect/remove it explicitly first.'
    [ -f "$ROOT/capture/collector.sh" ] && [ ! -L "$ROOT/capture/collector.sh" ] || die 'Missing staged collector.'
    plutil -lint "$ROOT/capture/$LABEL.plist"
    install -o root -g wheel -m 644 "$ROOT/capture/$LABEL.plist" "$PLIST"
    if ! launchctl bootstrap system "$PLIST"; then
        die 'launchctl bootstrap failed; keep its plist and inspect recorder-status. No driver was enabled.'
    fi
    printf 'Read-only recorder registered and started for 300 seconds; future boots also record. No reboot required.\n'
}

export_reports() {
    local output
    output=$(mktemp -d /Users/Shared/UHD770MVP-reports.XXXXXX)
    if [ -d "$LOGROOT" ] && [ ! -L "$LOGROOT" ]; then ditto "$LOGROOT" "$output/boot-capture"; fi
    if [ -d "$ROOT" ] && [ ! -L "$ROOT" ]; then
        for name in stage-state.txt package-verification.txt runtime-verification.txt evidence.json; do
            if [ -f "$ROOT/$name" ] && [ ! -L "$ROOT/$name" ]; then cp "$ROOT/$name" "$output/"; fi
        done
        if [ -d "$ROOT/kc-preflight" ] && [ ! -L "$ROOT/kc-preflight" ]; then
            mkdir "$output/kc-preflight"
            find "$ROOT/kc-preflight" -maxdepth 1 -type f -name '*.txt' -exec cp '{}' "$output/kc-preflight/" \;
        fi
    fi
    printf 'export_only=true\ngpu_executed_by_export=false\n' > "$output/export.txt"
    case "${SUDO_UID:-}:${SUDO_GID:-}" in *[!0-9:]*|:*|*:) ;; *) chown -hR "$SUDO_UID:$SUDO_GID" "$output" ;; esac
    printf 'Reports exported to: %s\n' "$output"
}

[ "$#" -eq 1 ] || { usage; exit 64; }
case "$1" in --help|help) usage; exit 0 ;; stage|install-recorder|recorder-status|remove-recorder|export) ;; *) usage >&2; exit 64 ;; esac
[ "$(uname -s)" = Darwin ] || die 'Run this only in macOS.'
[ "$EUID" -eq 0 ] || die 'Run with sudo /bin/bash -p.'
case $- in *p*) ;; *) die 'Use /bin/bash -p to ignore inherited shell initialization.' ;; esac
[ "$(uname -m)" = x86_64 ] || die 'Native x86_64 macOS is required.'
case "$(sw_vers -productVersion)" in 15.*) ;; *) die 'This candidate targets macOS 15 only.' ;; esac
case "$1" in
    stage) stage ;;
    install-recorder) install_recorder ;;
    recorder-status) launchctl print "system/$LABEL" ;;
    remove-recorder)
        load_staged_helpers
        safe_directory /Library/LaunchDaemons
        declare -F session_stop_recorder >/dev/null || die 'The stage lacks the verified recorder-stop helper.'
        stop_report=$(mktemp -d "$ROOT/recorder-stop.XXXXXX")
        printf 'Recorder stop diagnostics: %s\n' "$stop_report"
        stop_code=0
        session_stop_recorder "$LABEL" "$PLIST" "$ROOT/capture/collector.sh" "$stop_report" || stop_code=$?
        printf 'helper_exit=%s\n' "$stop_code" > "$stop_report/helper-exit.txt"
        [ "$stop_code" -eq 0 ] || die "Recorder stop was not verified; registration and logs preserved: $stop_report"
        printf 'Recorder stop verified. Logs and drivers unchanged.\n' ;;
    export) export_reports ;;
esac
