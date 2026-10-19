#!/bin/bash
# Stage pristine pinned inputs for the macOS runner. Only the drm archive and
# untouched FreeBSD checkout enter the dependency cache; patches apply to copies.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS runner required' >&2; exit 1; }
REPO=${GITHUB_WORKSPACE:?}
DEPS=${NMX_DEPENDENCY_CACHE:?}
S=/Volumes/MiniData/build/gpu-src
X=$S/xkpi
PIN_VALUES=$(python3 - "$REPO/experimental/uhd770/sources.json" <<'PY'
import json, re, sys
data = json.load(open(sys.argv[1]))
values = [data[key] for key in ('port', 'drm_kmod', 'freebsd', 'drm_kmod_archive_sha256')]
assert all(re.fullmatch(r'[0-9a-f]{40}', value) for value in values[:3])
assert re.fullmatch(r'[0-9a-f]{64}', values[3])
print(*values)
PY
)
read -r PORT_SHA DRM_SHA FBSD_SHA DRM_DIGEST <<< "$PIN_VALUES"
sudo mkdir -p "$S" /opt/homebrew/bin
sudo chown -R "$(id -u):$(id -g)" /Volumes/MiniData
sudo ln -sf "$(command -v python3)" /opt/homebrew/bin/python3
mkdir -p "$DEPS"
ARCHIVE=$DEPS/drm-$DRM_SHA.tgz
if [[ ! -f "$ARCHIVE" ]]; then
    curl --retry 3 -fsSL -o "$ARCHIVE.partial" "https://codeload.github.com/freebsd/drm-kmod/tar.gz/$DRM_SHA"
    mv "$ARCHIVE.partial" "$ARCHIVE"
fi
printf '%s  %s\n' "$DRM_DIGEST" "$ARCHIVE" | shasum -a 256 -c -
FBSD=$DEPS/freebsd-src
if [[ ! -d "$FBSD" ]]; then
    git init -q "$FBSD"
    git -C "$FBSD" remote add origin https://github.com/freebsd/freebsd-src
    git -C "$FBSD" fetch -q --depth 1 --filter=blob:none origin "$FBSD_SHA"
    git -C "$FBSD" sparse-checkout init --cone
    git -C "$FBSD" sparse-checkout set sys/compat/linuxkpi sys/contrib/ck sys/contrib/dev/acpica
    git -C "$FBSD" checkout -q --detach FETCH_HEAD
fi
[[ "$(git -C "$FBSD" rev-parse HEAD)" == "$FBSD_SHA" ]]
git -C "$FBSD" diff --exit-code HEAD --
[[ -z "$(git -C "$FBSD" ls-files --others --exclude-standard)" ]]
test -f "$FBSD/sys/contrib/dev/acpica/include/acpi.h"
# These are fixed disposable runner paths, never the cached input directories.
rm -rf "$X" "$S/kpi"
mkdir -p "$X" "$S/kpi/drm-kmod"
git -C "$REPO" archive "$PORT_SHA" gpu-port/xkpi | tar -x --strip-components=2 -C "$X"
tar -xzf "$ARCHIVE" --strip-components=1 -C "$S/kpi/drm-kmod"
cp -R "$FBSD" "$S/kpi/freebsd-src"
chmod +x "$X"/*.sh
python3 - "$X" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1], 'override/src/linux_pci.c')
source = path.read_text()
anchor = '#include "pcib_if.h"\n'
shim = '''
#include <linux/list.h>
#include <linux/spinlock.h>
/* The port replaces the new FreeBSD file; its shared globals still live in
 * override/src/linux_compat.c rather than the newer file's static lkpi_* set. */
extern struct list_head pci_drivers;
extern struct list_head pci_devices;
extern spinlock_t pci_lock;
'''
assert source.count(anchor) == 1
assert 'extern spinlock_t pci_lock;' not in source
path.write_text(source.replace(anchor, anchor + shim, 1))
PY
printf 'Pinned inputs staged: port=%s drm=%s freebsd=%s\n' "$PORT_SHA" "$DRM_SHA" "$FBSD_SHA"
du -sh "$S/kpi/drm-kmod" "$S/kpi/freebsd-src" "$X"
