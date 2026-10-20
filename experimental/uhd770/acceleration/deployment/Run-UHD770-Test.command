#!/bin/bash -p
# Manual test launcher. Always use the protected installed coordinator; root
# controls capture/export and drops to the selected user for both GPU probes.
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
unset CDPATH GLOBIGNORE
usage() {
    printf '%s\n' 'Usage: sudo /bin/bash -p Run-UHD770-Test.command' \
        'After PREPARED and the test reboot, explicitly run this command in Terminal.' \
        'Root starts bounded capture/export; the coordinator runs Vulkan and, only on success, Metal as the selected ordinary user.' \
        'Logging/recovery may run at boot; neither login nor reboot starts these compute tests.'
}
[ "${1:-}" != --help ] || { usage; exit 0; }
[ "$#" -eq 0 ] || { usage >&2; exit 64; }
[ "$(uname -s)" = Darwin ] || { printf 'REFUSED: macOS is required; no diagnostic was started.\n' >&2; exit 64; }
[ "$EUID" -eq 0 ] || { printf 'REFUSED: use sudo /bin/bash -p so the coordinator can start capture/export; GPU probes still run as your ordinary user.\n' >&2; exit 64; }
case $- in *p*) ;; *) printf 'REFUSED: use /bin/bash -p.\n' >&2; exit 64 ;; esac
TARGET='/Library/Application Support/UHD770MVP/incoming/tools/session.sh'
[ -f "$TARGET" ] && [ ! -L "$TARGET" ] || { printf 'REFUSED: complete preparation and reboot before using this launcher.\n' >&2; exit 64; }
exec /bin/bash -p "$TARGET" test
