#!/bin/bash -p
# The machine-specific package places this entry point at its root. Preparation
# verifies all bytes and stages root-owned tools before touching any live file.
set -euo pipefail
KIT=$(cd "$(dirname "$0")" && pwd -P)
if [ "${1:-}" = --help ]; then
    printf '%s\n' 'Usage: sudo /bin/bash -p Start-UHD770.command' \
      'One preparation invocation; no automatic reboot. Read README-session.txt first.'
    exit 0
fi
[ "$#" -eq 0 ] || exit 64
exec /bin/bash -p "$KIT/tools/session.sh" prepare
