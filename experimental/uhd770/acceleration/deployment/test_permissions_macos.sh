#!/bin/bash -p
# Native Darwin ACL/symlink regression for the real permission helper. Everything
# is compiled, signed and normalized inside one fresh temporary directory. This
# never uses live /Library, a boot config, a driver client or GPU commands.
set -euo pipefail
if [ "$(uname -s)" != Darwin ]; then
    printf 'SKIP native macOS permissions: Darwin /bin/chmod -N and ACL semantics are unavailable; no Mac validation claimed.\n'
    exit 0
fi
[ "$EUID" -eq 0 ] || { printf 'Native macOS permission fixture requires sudo /bin/bash -p.\n' >&2; exit 64; }
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/session-lib.sh"
type session_tree_permissions >/dev/null 2>&1 || { printf 'Missing production session_tree_permissions.\n' >&2; exit 1; }
PARENT=$(cd "${TMPDIR:-/private/tmp}" && pwd -P)
FIXTURE=$(mktemp -d "$PARENT/uhd770-native-permissions.XXXXXX")
case "$FIXTURE" in "$PARENT"/uhd770-native-permissions.*) ;; *) exit 1 ;; esac
cleanup() {
    local code=$?
    if [ "$code" -eq 0 ]; then /bin/rm -rf -- "$FIXTURE"; else printf 'Native permission evidence retained: %s\n' "$FIXTURE" >&2; fi
}
trap cleanup EXIT
TREE="$FIXTURE/prepared"
RUNTIME="$TREE/Library/GPUBundles/nvmtl"
BUNDLE="$TREE/Library/GPUBundles/NVMTLDriver.bundle"
MACOS="$BUNDLE/Contents/MacOS"
OUTSIDE="$FIXTURE/outside"
/bin/mkdir -p "$RUNTIME" "$MACOS" "$OUTSIDE"
printf 'int fixture_value(void) { return 17; }\n' > "$FIXTURE/inert.c"
/usr/bin/clang -dynamiclib "$FIXTURE/inert.c" -o "$RUNTIME/libvulkan_intel.1.dylib"
/usr/bin/clang -bundle "$FIXTURE/inert.c" -o "$MACOS/NVMTLDriver"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.fixture.UHD770PermissionLayout</string>
<key>CFBundleExecutable</key><string>NVMTLDriver</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
/bin/ln -s libvulkan_intel.1.dylib "$RUNTIME/libvulkan_intel.dylib"
/bin/ln -s ../../../nvmtl "$MACOS/air-runtime"
/bin/ln -s missing-fixture-library "$RUNTIME/dangling-library"
printf 'preserve external target\n' > "$OUTSIDE/sentinel"
/bin/chmod 600 "$OUTSIDE/sentinel"
/bin/chmod +a 'everyone allow read,readattr,readextattr,readsecurity' "$OUTSIDE/sentinel"
/bin/ln -s "$OUTSIDE/sentinel" "$TREE/external-sentinel"
printf 'non-executable metadata\n' > "$TREE/notes.txt"

# These are genuine ad-hoc signatures over inert compiled Mach-O content and the
# original relative bundle link. Permission normalization must preserve them.
/usr/bin/codesign --force --sign - "$RUNTIME/libvulkan_intel.1.dylib"
/usr/bin/codesign --force --sign - "$BUNDLE"
/usr/bin/codesign --verify --strict "$RUNTIME/libvulkan_intel.1.dylib"
/usr/bin/codesign --verify --strict "$BUNDLE"

acl_entries() { /bin/ls -lde "$1" | /usr/bin/sed -n '/^[[:space:]]*[0-9][0-9]*:/p'; }
sentinel_mode=$(/usr/bin/stat -f '%u:%g:%Lp' "$OUTSIDE/sentinel")
sentinel_acl=$(acl_entries "$OUTSIDE/sentinel")
[ -n "$sentinel_acl" ]
sentinel_hash=$(/usr/bin/shasum -a 256 "$OUTSIDE/sentinel" | /usr/bin/awk '{print $1}')
runtime_hash=$(/usr/bin/shasum -a 256 "$RUNTIME/libvulkan_intel.1.dylib" | /usr/bin/awk '{print $1}')
bundle_hash=$(/usr/bin/shasum -a 256 "$MACOS/NVMTLDriver" | /usr/bin/awk '{print $1}')

# Seed ACLs on directories and real files only; links include a dangling alias
# and an external sentinel specifically to detect accidental traversal.
while IFS= read -r -d '' path; do
    /bin/chmod +a 'everyone allow read,readattr,readextattr,readsecurity' "$path"
done < <(/usr/bin/find -P "$TREE" \( -type d -o -type f \) -print0)
/bin/chmod 770 "$TREE" "$MACOS/NVMTLDriver" "$RUNTIME/libvulkan_intel.1.dylib"
/bin/chmod 660 "$TREE/notes.txt"
[ -n "$(acl_entries "$TREE")" ] && [ -n "$(acl_entries "$TREE/notes.txt")" ]
session_tree_permissions "$TREE" sealed
[ "$(/usr/bin/stat -f '%Lp' "$TREE")" = 750 ]
[ "$(/usr/bin/stat -f '%Lp' "$TREE/notes.txt")" = 640 ]
session_tree_permissions "$TREE" readable
[ "$(/usr/bin/stat -f '%Lp' "$TREE")" = 755 ]
[ "$(/usr/bin/stat -f '%Lp' "$TREE/notes.txt")" = 644 ]
[ "$(/usr/bin/stat -f '%Lp' "$MACOS/NVMTLDriver")" = 755 ]
while IFS= read -r -d '' path; do [ -z "$(acl_entries "$path")" ]; done < <(/usr/bin/find -P "$TREE" \( -type d -o -type f \) -print0)

[ "$(/usr/bin/readlink "$MACOS/air-runtime")" = ../../../nvmtl ]
[ "$(/usr/bin/readlink "$RUNTIME/libvulkan_intel.dylib")" = libvulkan_intel.1.dylib ]
[ "$(/usr/bin/readlink "$RUNTIME/dangling-library")" = missing-fixture-library ]
[ "$(/usr/bin/readlink "$TREE/external-sentinel")" = "$OUTSIDE/sentinel" ]
[ "$MACOS/air-runtime" -ef "$RUNTIME" ] && [ "$RUNTIME/libvulkan_intel.dylib" -ef "$RUNTIME/libvulkan_intel.1.dylib" ]
[ -L "$RUNTIME/dangling-library" ] && [ ! -e "$RUNTIME/dangling-library" ]
[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$OUTSIDE/sentinel")" = "$sentinel_mode" ]
[ "$(acl_entries "$OUTSIDE/sentinel")" = "$sentinel_acl" ]
[ "$(/usr/bin/shasum -a 256 "$OUTSIDE/sentinel" | /usr/bin/awk '{print $1}')" = "$sentinel_hash" ]
[ "$(/usr/bin/shasum -a 256 "$RUNTIME/libvulkan_intel.1.dylib" | /usr/bin/awk '{print $1}')" = "$runtime_hash" ]
[ "$(/usr/bin/shasum -a 256 "$MACOS/NVMTLDriver" | /usr/bin/awk '{print $1}')" = "$bundle_hash" ]
/usr/bin/codesign --verify --strict "$RUNTIME/libvulkan_intel.1.dylib"
/usr/bin/codesign --verify --strict "$BUNDLE"
printf 'PASS native macOS permissions: ACL removal, non-following symlinks/dangling links, external target protection and real ad-hoc signatures; no GPU accessed.\n'
