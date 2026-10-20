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
ROOT="$FIXTURE/protected-stage"
RUNTIME="$TREE/Library/GPUBundles/nvmtl"
BUNDLE="$TREE/Library/GPUBundles/NVMTLDriver.bundle"
MACOS="$BUNDLE/Contents/MacOS"
OUTSIDE="$FIXTURE/outside"
/bin/mkdir -p "$RUNTIME" "$MACOS" "$OUTSIDE" "$ROOT/incoming"
printf 'int fixture_value(void) { return 17; }\n' > "$FIXTURE/inert.c"
/usr/bin/clang -dynamiclib "$FIXTURE/inert.c" -o "$RUNTIME/libvulkan.1.dylib"
/bin/cp "$RUNTIME/libvulkan.1.dylib" "$RUNTIME/libvulkan_intel.dylib"
/bin/cp "$RUNTIME/libvulkan.1.dylib" "$RUNTIME/libnvmtl_translate.dylib"
/usr/bin/clang -bundle "$FIXTURE/inert.c" -o "$RUNTIME/NVMTLDriver"
printf 'int main(void) { return 0; }\n' > "$FIXTURE/cli.c"
/usr/bin/clang "$FIXTURE/cli.c" -o "$RUNTIME/air-opt"
printf 'original external runtime metadata\n' > "$RUNTIME/runtime-metadata.txt"
/bin/cp "$RUNTIME/NVMTLDriver" "$MACOS/NVMTLDriver"
cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.fixture.UHD770PermissionLayout</string>
<key>CFBundleExecutable</key><string>NVMTLDriver</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
PLIST
/bin/ln -s libvulkan.1.dylib "$RUNTIME/libvulkan.dylib"
/bin/ln -s ../../../nvmtl "$MACOS/air-runtime"
/bin/ln -s missing-fixture-library "$TREE/dangling-library"
printf 'preserve external target\n' > "$OUTSIDE/sentinel"
/bin/chmod 600 "$OUTSIDE/sentinel"
/bin/chmod +a 'everyone allow read,readattr,readextattr,readsecurity' "$OUTSIDE/sentinel"
/bin/ln -s "$OUTSIDE/sentinel" "$TREE/external-sentinel"
printf 'non-executable metadata\n' > "$TREE/notes.txt"

# These are genuine ad-hoc signatures over inert compiled Mach-O content and the
# original relative bundle link. Permission normalization must preserve them.
printf 'phase=sign-runtime\n'
for path in "$RUNTIME/"*.dylib "$RUNTIME/NVMTLDriver" "$RUNTIME/air-opt"; do
    [ ! -L "$path" ] || continue
    /usr/bin/codesign --force --sign - "$path"
done
printf 'phase=sign-bundle\n'
/usr/bin/codesign --force --sign - "$BUNDLE"
printf 'phase=verify-runtime-before\n'
/usr/bin/codesign --verify --strict "$RUNTIME/libvulkan.1.dylib"
printf 'phase=verify-bundle-seal-before\n'
/usr/bin/codesign --verify "$BUNDLE"

# Exercise the real production check without executing session.sh's entry
# point or any driver API. The protected manifest closes the external runtime
# bytes that an ordinary bundle seal (which seals link text) does not cover.
/usr/bin/awk '/^check_runtime\(\) \{/ {copy=1} copy {print} copy && /^\}/ {exit}' "$HERE/session.sh" > "$FIXTURE/runtime-check.sh"
. "$FIXTURE/runtime-check.sh"
type check_runtime >/dev/null 2>&1
: > "$ROOT/incoming/runtime-SHA256SUMS"
while IFS= read -r -d '' path; do
    digest=$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}')
    printf '%s  %s\n' "$digest" "${path#"$TREE/"}" >> "$ROOT/incoming/runtime-SHA256SUMS"
done < <(/usr/bin/find -P "$RUNTIME" "$BUNDLE" -type f -print0)
/bin/chmod 700 "$ROOT" "$ROOT/incoming"
/bin/chmod 600 "$ROOT/incoming/runtime-SHA256SUMS"
printf 'phase=verify-runtime-contract-before\n'
check_runtime "$TREE/Library/GPUBundles" "$FIXTURE/contract-before"

acl_entries() { /bin/ls -lde "$1" | /usr/bin/sed -n '/^[[:space:]]*[0-9][0-9]*:/p'; }
sentinel_mode=$(/usr/bin/stat -f '%u:%g:%Lp' "$OUTSIDE/sentinel")
sentinel_acl=$(acl_entries "$OUTSIDE/sentinel")
[ -n "$sentinel_acl" ]
sentinel_hash=$(/usr/bin/shasum -a 256 "$OUTSIDE/sentinel" | /usr/bin/awk '{print $1}')
runtime_hash=$(/usr/bin/shasum -a 256 "$RUNTIME/libvulkan.1.dylib" | /usr/bin/awk '{print $1}')
bundle_hash=$(/usr/bin/shasum -a 256 "$MACOS/NVMTLDriver" | /usr/bin/awk '{print $1}')

# Seed ACLs on directories and real files only; links include a dangling alias
# and an external sentinel specifically to detect accidental traversal.
while IFS= read -r -d '' path; do
    /bin/chmod +a 'everyone allow read,readattr,readextattr,readsecurity' "$path"
done < <(/usr/bin/find -P "$TREE" \( -type d -o -type f \) -print0)
/bin/chmod 770 "$TREE" "$MACOS/NVMTLDriver" "$RUNTIME/libvulkan.1.dylib"
/bin/chmod 660 "$TREE/notes.txt"
[ -n "$(acl_entries "$TREE")" ] && [ -n "$(acl_entries "$TREE/notes.txt")" ]
printf 'phase=normalize-sealed\n'
session_tree_permissions "$TREE" sealed
[ "$(/usr/bin/stat -f '%Lp' "$TREE")" = 750 ]
[ "$(/usr/bin/stat -f '%Lp' "$TREE/notes.txt")" = 640 ]
printf 'phase=normalize-readable\n'
session_tree_permissions "$TREE" readable
[ "$(/usr/bin/stat -f '%Lp' "$TREE")" = 755 ]
[ "$(/usr/bin/stat -f '%Lp' "$TREE/notes.txt")" = 644 ]
[ "$(/usr/bin/stat -f '%Lp' "$MACOS/NVMTLDriver")" = 755 ]
while IFS= read -r -d '' path; do [ -z "$(acl_entries "$path")" ]; done < <(/usr/bin/find -P "$TREE" \( -type d -o -type f \) -print0)

[ "$(/usr/bin/readlink "$MACOS/air-runtime")" = ../../../nvmtl ]
[ "$(/usr/bin/readlink "$RUNTIME/libvulkan.dylib")" = libvulkan.1.dylib ]
[ "$(/usr/bin/readlink "$TREE/dangling-library")" = missing-fixture-library ]
[ "$(/usr/bin/readlink "$TREE/external-sentinel")" = "$OUTSIDE/sentinel" ]
[ "$MACOS/air-runtime" -ef "$RUNTIME" ] && [ "$RUNTIME/libvulkan.dylib" -ef "$RUNTIME/libvulkan.1.dylib" ]
[ -L "$TREE/dangling-library" ] && [ ! -e "$TREE/dangling-library" ]
[ "$(/usr/bin/stat -f '%u:%g:%Lp' "$OUTSIDE/sentinel")" = "$sentinel_mode" ]
[ "$(acl_entries "$OUTSIDE/sentinel")" = "$sentinel_acl" ]
[ "$(/usr/bin/shasum -a 256 "$OUTSIDE/sentinel" | /usr/bin/awk '{print $1}')" = "$sentinel_hash" ]
[ "$(/usr/bin/shasum -a 256 "$RUNTIME/libvulkan.1.dylib" | /usr/bin/awk '{print $1}')" = "$runtime_hash" ]
[ "$(/usr/bin/shasum -a 256 "$MACOS/NVMTLDriver" | /usr/bin/awk '{print $1}')" = "$bundle_hash" ]
printf 'phase=verify-runtime-after\n'
/usr/bin/codesign --verify --strict "$RUNTIME/libvulkan.1.dylib"
printf 'phase=verify-bundle-seal-after\n'
/usr/bin/codesign --verify "$BUNDLE"
printf 'phase=verify-runtime-contract-after\n'
check_runtime "$TREE/Library/GPUBundles" "$FIXTURE/contract-after"

# The shared runtime is outside the bundle seal. Tampering it must fail the
# candidate hash gate even though ordinary bundle verification still succeeds.
/bin/cp "$RUNTIME/runtime-metadata.txt" "$FIXTURE/runtime-metadata.original"
printf 'changed external bytes\n' > "$RUNTIME/runtime-metadata.txt"
printf 'phase=reject-external-runtime-tamper\n'
/usr/bin/codesign --verify "$BUNDLE"
if check_runtime "$TREE/Library/GPUBundles" "$FIXTURE/contract-tampered"; then
    printf 'FAIL external runtime tamper was accepted\n' >&2; exit 1
fi
/usr/bin/grep -q 'FAILED' "$FIXTURE/contract-tampered.hashes.txt"
/bin/cp "$FIXTURE/runtime-metadata.original" "$RUNTIME/runtime-metadata.txt"
check_runtime "$TREE/Library/GPUBundles" "$FIXTURE/contract-restored"
printf 'PASS native macOS permissions: ACL removal, non-following links, unchanged bundle seals/standalone signatures, exact candidate hashes and external-runtime tamper rejection; no GPU accessed.\n'
