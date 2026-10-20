#!/bin/bash -p
# Explicit opt-in compute diagnostic. This entry point never installs/loads a
# driver or changes EFI/NVRAM. Installed bytes and loaded kext UUIDs are checked
# before a single caller-selected probe can enumerate or submit GPU work.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH GLOBIGNORE
umask 077

usage() {
    printf '%s\n' 'Usage: run-probe.sh vulkan|metal [--output ABSOLUTE_EXISTING_DIRECTORY]' \
        'Runs ONLY the explicitly selected 45-second compute diagnostic.' \
        'Execute the installed script directly as your normal macOS user; never use sudo.' \
        'No driver loading/installation, NVRAM/EFI edits, or automatic next stage.'
}
fail() { printf 'REFUSED: %s\n' "$*" >&2; exit 64; }
[ "${1:-}" != --help ] || { usage; exit 0; }
[ "$#" -ge 1 ] || { usage >&2; exit 64; }
phase=$1
shift
case "$phase" in vulkan|metal) ;; *) fail 'Choose exactly vulkan or metal.' ;; esac
output=
if [ "$#" -ne 0 ]; then
    [ "$#" -eq 2 ] && [ "$1" = --output ] || fail 'Invalid arguments.'
    output=$2
fi
[ "$(uname -s)" = Darwin ] || fail 'macOS is required; no diagnostic was started.'
[ "$EUID" -ne 0 ] || fail 'Run directly as a normal user, without sudo.'
case $- in *p*) ;; *) fail 'Execute the installed script directly, using its privileged-mode Bash shebang.' ;; esac
[ "$(uname -m)" = x86_64 ] || fail 'This candidate is for native x86_64 macOS.'

ROOT='/Library/Application Support/UHD770MVP'
COMPONENTS="$ROOT/components"
SELF="$ROOT/probes/run-probe.sh"
[ ! -L "$0" ] && [ "$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")" = "$SELF" ] || \
    fail "Use the root-owned installed entry point: $SELF"

# Refuse writable ancestors or staged payloads, including unsafe symlinks. The
# deployment installer must strip ACLs on this dedicated root and set root:wheel.
check_owned() {
    local path=$1 owner mode
    owner=$(stat -f '%u' "$path") || fail "Cannot inspect $path"
    [ "$owner" = 0 ] || fail "Not root owned: $path"
    if [ ! -L "$path" ]; then
        mode=$(stat -f '%Lp' "$path") || fail "Cannot inspect mode: $path"
        [ $((8#$mode & 0022)) -eq 0 ] || fail "Writable by group/others: $path"
    fi
}
for ancestor in /Library '/Library/Application Support' "$ROOT" "$ROOT/probes"; do
    [ -d "$ancestor" ] && [ ! -L "$ancestor" ] || fail "Unsafe ancestor: $ancestor"
    check_owned "$ancestor"
done
check_owned "$SELF"
[ -f "$ROOT/probes/runner-lib.sh" ] && [ ! -L "$ROOT/probes/runner-lib.sh" ] || fail 'Missing regular helper library.'
check_owned "$ROOT/probes/runner-lib.sh"
[ -d "$COMPONENTS" ] && [ ! -L "$COMPONENTS" ] || fail 'Missing regular components directory.'
while IFS= read -r -d '' entry; do
    check_owned "$entry"
    if [ -L "$entry" ]; then
        # These are the only two symlinks in the matched candidate. Refuse
        # additional chains instead of resolving arbitrary untrusted paths.
        case "${entry#"$COMPONENTS/"}" in
            Library/GPUBundles/nvmtl/libvulkan.dylib)
                [ "$(readlink "$entry")" = libvulkan.1.dylib ] || fail 'Unexpected loader link.' ;;
            Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime)
                [ "$(readlink "$entry")" = ../../../nvmtl ] || fail 'Unexpected AIR runtime link.' ;;
            *) fail "Unexpected staged symlink: $entry" ;;
        esac
    fi
done < <(find "$COMPONENTS" -print0)
. "$ROOT/probes/runner-lib.sh"

# Resolve the actual user home from the local account, rather than an inherited
# HOME override. An explicit output must already exist, be private and user owned.
account=$(id -un)
user_home=$(dscl . -read "/Users/$account" NFSHomeDirectory | sed 's/^NFSHomeDirectory: //')
case "$user_home" in /*) ;; *) fail 'Cannot determine the account home.' ;; esac
[ -d "$user_home" ] || fail 'The account home is unavailable.'
if [ -z "$output" ]; then
    output="$user_home/Library/Logs/UHD770MVP"
    mkdir -p "$output"
    chmod 700 "$output"
fi
case "$output" in /*) ;; *) fail '--output must be an absolute path.' ;; esac
[ -d "$output" ] && [ ! -L "$output" ] || fail 'Output must be an existing regular directory.'
output=$(cd "$output" && pwd -P)
[ "$(stat -f '%u' "$output")" = "$EUID" ] || fail 'Output must belong to the current user.'
mode=$(stat -f '%Lp' "$output")
[ $((8#$mode & 0077)) -eq 0 ] || fail 'Output directory must be private (chmod 700).'
case "$output" in /Volumes/*) fail 'Keep evidence on the system disk, not removable media.' ;; esac
session=$(mktemp -d "$output/$(date -u '+%Y%m%dT%H%M%SZ')-$phase.XXXXXX")
mkdir "$session/tmp"
printf 'PREPARING\nphase=%s\ncreated_utc=%s\n' "$phase" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "$session/session.marker"
sync
printf 'Evidence directory: %s\n' "$session"
# Any preparation failure leaves the session marker; no success is inferred.
trap 'printf "state=preparation-failed\n" > "$session/result.txt"; sync' EXIT

{
    printf 'phase=%s\nuid=%s\naccount=%s\n' "$phase" "$EUID" "$account"
    printf 'boot_session_uuid='; sysctl -n kern.bootsessionuuid
    printf 'kernel_boot_time='; sysctl -n kern.boottime
    uname -a
    sw_vers
    printf 'candidate_root=%s\n' "$ROOT"
    printf 'probe_internal_deadline_s=45\nrunner_outer_deadline_s=55\n'
} > "$session/system.txt"
shasum -a 256 "$SELF" "$ROOT/probes/runner-lib.sh" > "$session/runner-SHA256SUMS"
[ -f "$ROOT/evidence.json" ] && [ ! -L "$ROOT/evidence.json" ] || fail 'Missing candidate evidence.'
check_owned "$ROOT/evidence.json"
cp "$ROOT/evidence.json" "$session/candidate-evidence.json"
shasum -a 256 "$ROOT/evidence.json" > "$session/candidate-evidence-SHA256SUMS"

require_loaded() {
    local bundle=$1 executable=$2 expected line actual
    [ -f "$executable" ] && [ ! -L "$executable" ] || fail "Missing kext image: $executable"
    expected=$(uhd_macho_uuid "$executable") || fail "No x86_64 LC_UUID: $executable"
    [ "${#expected}" -eq 32 ] || fail 'Malformed staged Mach-O UUID.'
    kextstat -l -b "$bundle" > "$session/$bundle-loaded.txt" 2>&1 || fail "Cannot inspect loaded $bundle"
    line=$(awk -v name="$bundle" '{for (i=1;i<=NF;i++) if ($i==name) print}' "$session/$bundle-loaded.txt")
    [ "$(printf '%s\n' "$line" | grep -c .)" = 1 ] || fail "Expected exactly one loaded $bundle."
    actual=$(printf '%s\n' "$line" | grep -Eo '[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}' | tr '[:upper:]' '[:lower:]' | tr -d '-')
    [ "$actual" = "$expected" ] || fail "Loaded $bundle UUID differs from the candidate."
    printf '%s %s\n' "$bundle" "$expected" >> "$session/loaded-UUIDs.txt"
    shasum -a 256 "$executable" >> "$session/payload-SHA256SUMS"
}
require_loaded com.nullmoth.NMXGPU "$COMPONENTS/Library/Extensions/NMXGPU.kext/Contents/MacOS/NMXGPU"

runtime="$COMPONENTS/Library/GPUBundles/nvmtl"
[ -d "$runtime" ] && [ ! -L "$runtime" ] || fail 'Missing native userland runtime.'
while IFS= read -r -d '' entry; do
    shasum -a 256 "$entry" >> "$session/payload-SHA256SUMS"
done < <(find "$runtime" -type f -print0)

if [ "$phase" = vulkan ]; then
    binary="$COMPONENTS/probe/uhd770-compute-probe"
    shader="$COMPONENTS/probe/verify.comp.spv"
    loader="$runtime/libvulkan.1.dylib"
    [ -x "$binary" ] && [ -f "$shader" ] && [ -f "$loader" ] && [ -f "$runtime/libvulkan_intel.dylib" ] || fail 'Incomplete Vulkan payload.'
    # The original candidate JSON is relative to its own directory. A session
    # copy names the exact staged ICD absolutely; no global driver search occurs.
    printf '{"file_format_version":"1.0.0","ICD":{"library_path":"%s/libvulkan_intel.dylib","api_version":"1.3.0"}}\n' "$runtime" > "$session/intel_icd.absolute.json"
    shasum -a 256 "$binary" "$shader" "$session/intel_icd.absolute.json" >> "$session/payload-SHA256SUMS"
    command=("$binary" --loader "$loader" --icd "$session/intel_icd.absolute.json" --shader "$shader" --device-id 0x4680 --count 4099 --iterations 3 --deadline 45)
    verified=COMPUTE_READBACK_VERIFIED
else
    require_loaded com.nullmoth.NMXAccel "$COMPONENTS/Library/Extensions/NMXAccel.kext/Contents/MacOS/NMXAccel"
    binary="$COMPONENTS/probe/uhd770-metal-probe"
    shader="$COMPONENTS/probe/smoke.metallib"
    [ -x "$binary" ] && [ -f "$shader" ] || fail 'Incomplete Metal payload.'
    # The frontend directly opens /Library/GPUBundles/nvmtl and the probe rejects
    # override variables. Match installed bytes/links before its first API call.
    for tree in nvmtl NVMTLDriver.bundle; do
        stage="$COMPONENTS/Library/GPUBundles/$tree"
        installed="/Library/GPUBundles/$tree"
        [ -d "$stage" ] && [ -d "$installed" ] && [ ! -L "$installed" ] || fail "Missing installed $tree"
        for parent in /Library/GPUBundles "$installed"; do
            [ -d "$parent" ] && [ ! -L "$parent" ] || fail "Unsafe installed parent: $parent"
            check_owned "$parent"
        done
        while IFS= read -r -d '' entry; do
            target="$installed${entry#"$stage"}"
            [ -e "$target" ] || fail "Missing installed file: $target"
            check_owned "$target"
            if [ -L "$entry" ]; then
                [ -L "$target" ] && [ "$(readlink "$entry")" = "$(readlink "$target")" ] || fail "Installed link differs: $target"
            elif [ -f "$entry" ]; then
                [ -f "$target" ] && [ ! -L "$target" ] && cmp -s "$entry" "$target" || fail "Installed bytes differ: $target"
                shasum -a 256 "$target" >> "$session/installed-SHA256SUMS"
            else
                [ -d "$target" ] && [ ! -L "$target" ] || fail "Installed directory differs: $target"
            fi
        done < <(find "$stage" -print0)
        # Extra files may change load behavior; deployment must install a clean tree.
        [ "$(find "$stage" -print | wc -l | tr -d ' ')" = "$(find "$installed" -print | wc -l | tr -d ' ')" ] || fail "Installed $tree has extra entries."
    done
    shasum -a 256 "$binary" "$shader" >> "$session/payload-SHA256SUMS"
    command=("$binary" --metallib "$shader" --deadline 45)
    verified=METAL_COMPUTE_READBACK_VERIFIED
fi
printf '%s\n' "${command[@]}" > "$session/argv.txt"
printf 'PREPARATION_COMPLETE\n' > "$session/preparation-complete.marker"
sync
trap - EXIT
# This applies only to the child. No launchctl/setenv, shell profile, or system
# Metal preference changes are made. The Metal probe sets NVMTL_ENABLE internally.
code=0
uhd_run_bounded "$session" "$verified" 55 \
    /usr/bin/env -i PATH="$PATH" HOME="$user_home" USER="$account" LOGNAME="$account" TMPDIR="$session/tmp/" \
    "${command[@]}" || code=$?
exit "$code"
