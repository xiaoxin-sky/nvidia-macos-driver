#!/bin/bash -p
# Retire a failed preparation with an empty or fully restored journal.
# This preserves the complete stage and all reports. It never restores/replaces
# live drivers, edits EFI, starts preparation, or submits GPU work.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH GLOBIGNORE
umask 077
ROOT='/Library/Application Support/UHD770MVP'
PARENT='/Library/Application Support'
LOCK="$PARENT/.com.uhd770.mvp.prepare.lock"
CAPTURE=com.uhd770.mvp.capture
OWN_LOCK=0

stop() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
usage() {
    printf '%s\n' 'Usage: sudo /bin/bash -p Archive-UHD770-Failed.command' \
      'Archive only a failed preparation with an empty or fully restored installation journal.' \
      'Export evidence, stop this kit recorder, and preserve the stage in a unique root-only sibling.' \
      'No deletion of reports, EFI change, driver installation, GPU test, or reboot.' \
      'After ARCHIVED, run the newer kit Start-UHD770.command yourself.'
}
[ "${1:-}" != --help ] || { usage; exit 0; }
[ "$#" -eq 0 ] || { usage >&2; exit 64; }
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = x86_64 ] || stop 'Native x86_64 macOS required.'
[ "$EUID" -eq 0 ] || stop 'Use sudo /bin/bash -p.'
case $- in *p*) ;; *) stop 'Use /bin/bash -p.' ;; esac
case "$(sw_vers -productVersion)" in 15.*) ;; *) stop 'macOS 15 required.' ;; esac

# Every trusted file component must be root-owned, non-writable by other users,
# and unlinked. These checks do not change any existing file permissions.
trusted_path() {
    local path=$1 current='' part uid mode metadata parts=()
    case "$path" in /Library|/Library/*) ;; *) stop 'Unexpected protected path.' ;; esac
    IFS=/ read -r -a parts <<< "$path"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || continue
        current="$current/$part"
        [ -e "$current" ] && [ ! -L "$current" ] || stop "Missing/linked path: $current"
        metadata=$(stat -f '%u %Lp' "$current")
        IFS=' ' read -r uid mode <<< "$metadata"
        case "$uid:$mode" in *[!0-7:]*|:*|*:) stop 'Invalid protected metadata.' ;; esac
        [ "$uid" = 0 ] && [ $((8#$mode & 0022)) -eq 0 ] || stop "Unsafe owner/mode: $current"
    done
}
absent() { [ ! -e "$1" ] && [ ! -L "$1" ]; }

# Keep this list synchronized with session.sh targets()/legacy restoration.
# Unknown future targets fail closed. Journal contents never supply a filesystem
# operation or new path, including the retired user-agent entry.
journal_targets() {
    printf '%s\n' \
      'nmxgpu|/Library/Extensions/NMXGPU.kext|directory' \
      'nmxaccel|/Library/Extensions/NMXAccel.kext|directory' \
      'cachegpu|/Library/NullMoth/kexts/15/NMXGPU.kext|directory' \
      'cacheaccel|/Library/NullMoth/kexts/15/NMXAccel.kext|directory' \
      'firmware|/Library/NullMoth/firmware/i915|directory' \
      'license|/Library/NullMoth/firmware/LICENSES/LICENSE.i915|file' \
      'runtime|/Library/GPUBundles/nvmtl|directory' \
      'frontend|/Library/GPUBundles/NVMTLDriver.bundle|directory' \
      'auxkc|/Library/KernelCollections/AuxiliaryKernelExtensions.kc|file' \
      'rootjob|/Library/LaunchDaemons/com.uhd770.mvp.session.plist|file' \
      'userjob|/Library/LaunchAgents/com.uhd770.mvp.session.plist|file'
}

# Require a protected regular receipt/control file before reading any bytes.
# Replaced candidate trees may contain sealed relative links and are preserved
# without walking, chmodding or resolving their descendants.
journal_control() {
    local metadata uid mode
    [ -f "$1" ] && [ ! -L "$1" ] || stop "Missing/linked journal control: $1"
    # The journal and its ancestors were already checked before this scan.
    metadata=$(stat -f '%u %Lp' "$1")
    IFS=' ' read -r uid mode <<< "$metadata"
    case "$uid:$mode" in *[!0-7:]*|:*|*:) stop 'Invalid journal control metadata.' ;; esac
    [ "$uid" = 0 ] && [ $((8#$mode & 0022)) -eq 0 ] || stop "Unsafe journal control owner/mode: $1"
}

validate_journal() {
    local journal="$ROOT/session-private/journal" entry name key suffix known
    local expected kind recorded original receipt found=0
    # Scan hidden members too; no unknown entry can silently leave an unresolved
    # transaction behind. Only top-level evidence is interpreted.
    for entry in "$journal"/* "$journal"/.[!.]* "$journal"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        name=${entry##*/}; key=${name%.*}; suffix=${name##*.}
        known=0
        while IFS='|' read -r expected recorded kind; do
            [ "$key" != "$expected" ] || { known=1; break; }
        done < <(journal_targets)
        [ "$known" -eq 1 ] || stop "Unknown journal key: $name"
        case "$suffix" in
            target|original|restored) journal_control "$entry" ;;
            replaced)
                [ ! -L "$entry" ] && { [ -d "$entry" ] || [ -f "$entry" ]; } || \
                    stop "Linked/unsupported replaced candidate: $name"
                # Candidate descendants, including signed relative symlinks,
                # stay opaque evidence rather than restoration instructions.
                ;;
            *) stop "Unresolved or unknown journal member: $name" ;;
        esac
    done
    while IFS='|' read -r key expected kind; do
        if absent "$journal/$key.target" && absent "$journal/$key.original" && \
            absent "$journal/$key.restored" && absent "$journal/$key.replaced"; then
            continue
        fi
        for suffix in target original restored; do
            [ -f "$journal/$key.$suffix" ] && [ ! -L "$journal/$key.$suffix" ] || \
                stop "Missing/linked journal control: $journal/$key.$suffix"
        done
        recorded=$(cat "$journal/$key.target")
        [ "$recorded" = "$expected" ] || stop "Journal target is not the fixed destination: $key"
        original=$(cat "$journal/$key.original")
        receipt="$journal/$key.restored"
        [ ! -s "$receipt" ] || stop "Invalid restoration receipt: $key"
        case "$original" in
            present)
                [ -e "$expected" ] && [ ! -L "$expected" ] || stop "Restored original is missing/linked: $key"
                case "$kind" in
                    directory) [ -d "$expected" ] || stop "Restored original has the wrong type: $key" ;;
                    file) [ -f "$expected" ] || stop "Restored original has the wrong type: $key" ;;
                esac ;;
            absent)
                absent "$expected" || stop "Originally absent target still exists: $key" ;;
            *) stop "Unknown original-state receipt: $key" ;;
        esac
        found=$((found + 1))
    done < <(journal_targets)
    JOURNAL_ENTRIES=$found
    if [ "$found" -eq 0 ]; then JOURNAL_STATE=empty; else JOURNAL_STATE=fully-restored; fi
}

cleanup() { if [ "$OWN_LOCK" -eq 1 ]; then rmdir "$LOCK" || :; fi; }
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
trusted_path "$PARENT"
mkdir -m 700 "$LOCK" || stop 'Another preparation or interrupted lock exists; preserved.'
OWN_LOCK=1
for path in "$ROOT" "$ROOT/incoming/tools/session.sh" "$ROOT/incoming/tools/manage.sh" \
    "$ROOT/session-private/journal" "$ROOT/session-private/failure.txt" \
    "$ROOT/session-public/state.txt" "$ROOT/session-public/plan.plist" \
    "$ROOT/stage-state.txt" "$ROOT/kc-preflight/result.txt"; do trusted_path "$path"; done
[ -d "$ROOT/session-private/journal" ] || stop 'Missing installation journal.'
validate_journal
[ "$(cat "$ROOT/session-public/state.txt")" = failed ] || stop 'Only failed preparations can be archived.'
grep -Fxq 'stage=offline-ready' "$ROOT/stage-state.txt" || stop 'Stage was not offline-ready.'
grep -Fxq 'driver_installed=false' "$ROOT/stage-state.txt" || stop 'Driver installation status is not clean.'
grep -Fxq 'gpu_executed=false' "$ROOT/stage-state.txt" || stop 'GPU execution status is not clean.'
grep -Fxq 'temporary_KC_linkage=passed' "$ROOT/kc-preflight/result.txt" || stop 'Temporary KC check did not pass.'
grep -Fxq 'installed=false' "$ROOT/kc-preflight/result.txt" || stop 'Temporary KC installation status is not clean.'
for field in optout_restore_exit file_restore_exit; do
    grep -Fxq "$field=0" "$ROOT/session-private/failure.txt" || stop 'Earlier recovery did not report success.'
done
args=$(sysctl -n kern.bootargs)
case " $args " in *' -nvoff '*) ;; *) stop 'Current boot must contain -nvoff.' ;; esac
case " $args " in *' nmxintel='*|*' nmxdiagdelay='*) stop 'Test boot arguments are still present.' ;; esac
owner=$(ioreg -r -c NMXGPU -l -w0) || stop 'Cannot inspect current GPU ownership.'
case "$owner" in *'class NMXGPU'*) stop 'A GPU service is attached; stage preserved.' ;; esac
gpu=$(ioreg -r -n IGPU -l -w0) || stop 'Cannot inspect Intel hardware.'
printf '%s\n' "$gpu" | grep -Eq '"device-id"[[:space:]]*=[[:space:]]*<80460000>' || stop 'UHD 770 4680 required.'
printf '%s\n' "$gpu" | grep -Eq '"vendor-id"[[:space:]]*=[[:space:]]*<86800000>' || stop 'Intel 8086 required.'
if guard=$(nvram nullmoth-gpu-attaching 2>&1); then stop 'Attach guard is present; preserved.'; fi
case "$guard" in *'data was not found'*) ;; *) stop 'Attach guard query failed unexpectedly.' ;; esac

# No recovery/session jobs may still depend on the stage being moved.
for path in /Library/LaunchDaemons/com.uhd770.mvp.session.plist \
    /Library/LaunchAgents/com.uhd770.mvp.session.plist; do
    absent "$path" || stop 'A session job is installed; use recovery instead.'
done
launchctl print system >/dev/null || stop 'Cannot inspect launchd system domain.'
if launchctl print system/com.uhd770.mvp.session >/dev/null 2>&1; then stop 'A system session job is registered.'; fi
uid=$(plutil -extract user_uid raw -o - "$ROOT/session-public/plan.plist")
case "$uid" in ''|*[!0-9]*) stop 'Invalid selected-user identity.' ;; esac
if launchctl print "gui/$uid/com.uhd770.mvp.session" >/dev/null 2>&1; then stop 'A user session job is registered.'; fi

# Resolve the saved UUID independently and require the exact opt-out EFI bytes.
plan="$ROOT/session-public/plan.plist"
uuid=$(plutil -extract volume_uuid raw -o - "$plan")
safe=$(plutil -extract safe_hash raw -o - "$plan")
label=$(plutil -extract volume_label raw -o - "$plan")
case "$uuid" in ''|*[!a-zA-Z0-9-]*) stop 'Invalid saved USB identity.' ;; esac
[ "${#safe}" -eq 64 ] && [ -z "$(printf '%s' "$safe" | tr -d '0-9a-f')" ] || stop 'Invalid saved EFI hash.'
info=$(diskutil info -plist "$uuid") || stop 'Cannot inspect the selected USB.'
mount=$(printf '%s' "$info" | plutil -extract MountPoint raw -o - -- -)
bus=$(printf '%s' "$info" | plutil -extract BusProtocol raw -o - -- -)
actual_uuid=$(printf '%s' "$info" | plutil -extract VolumeUUID raw -o - -- -)
actual_label=$(printf '%s' "$info" | plutil -extract VolumeName raw -o - -- -)
case "$mount" in /Volumes/*) ;; *) stop 'Selected USB is not mounted.' ;; esac
[ "$bus" = USB ] && [ "$actual_uuid" = "$uuid" ] && [ "$actual_label" = "$label" ] || stop 'USB identity changed.'
for path in /Volumes "$mount" "$mount/EFI" "$mount/EFI/OC" "$mount/EFI/OC/config.plist"; do
    [ -e "$path" ] && [ ! -L "$path" ] || stop 'Missing/linked USB path.'
done
actual=$(shasum -a 256 "$mount/EFI/OC/config.plist" | awk '{print $1}')
[ "$actual" = "$safe" ] || stop 'USB is not the exact safe opt-out configuration.'

printf 'Verified failed preparation; journal=%s entries=%s. Exporting existing evidence...\n' "$JOURNAL_STATE" "$JOURNAL_ENTRIES"
if [ "$JOURNAL_ENTRIES" -gt 0 ]; then
    printf 'Restoration receipts and current presence/types were checked. Original byte hashes were not recorded; byte equality cannot be verified.\n'
fi
/bin/bash -p "$ROOT/incoming/tools/session.sh" export
/bin/bash -p "$ROOT/incoming/tools/manage.sh" remove-recorder
launchctl print system >/dev/null || stop 'Cannot verify launchd after recorder removal.'
if launchctl print "system/$CAPTURE" >/dev/null 2>&1; then stop 'Recorder is still registered; stage preserved.'; fi
absent "/Library/LaunchDaemons/$CAPTURE.plist" || stop 'Recorder registration file remains; stage preserved.'
count=0
while :; do
    processes=$(ps -axo command=) || stop 'Cannot verify recorder process termination.'
    case "$processes" in *"$ROOT/capture/collector.sh"*)
        [ "$count" -lt 10 ] || stop 'Recorder process has not stopped; stage preserved.'
        sleep 1; count=$((count + 1)) ;;
        *) break ;;
    esac
done
# Same-filesystem rename into a newly created root-only parent never overwrites
# another archive and keeps the old journal, scripts and signatures together.
archive=$(mktemp -d "$PARENT/UHD770MVP-retired.XXXXXX")
[ -d "$archive" ] && [ ! -L "$archive" ] || stop 'Cannot create protected archive.'
printf 'journal=%s\njournal_entries=%s\nlive_driver_files_modified=false\noriginal_byte_hashes=not-recorded\nrestored_byte_equality=not-verified\n' \
    "$JOURNAL_STATE" "$JOURNAL_ENTRIES" > "$archive/retirement-verification.txt"
mv "$ROOT" "$archive/stage"
printf 'ARCHIVED: %s\nAll original reports and /private/var/log/UHD770MVP were retained.\nRun the newer kit Start-UHD770.command when ready; this helper did not start preparation.\n' "$archive"
