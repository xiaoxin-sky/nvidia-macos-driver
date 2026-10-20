#!/bin/bash
# Link the candidate against this runner's real kernel collections. Everything
# written is an isolated temporary copy/output; no kext is installed or loaded,
# and the temporary KC must never be used as a user's live boot collection.
set -euo pipefail
[[ "$(uname -s)" == Darwin ]] || { echo 'macOS runner required' >&2; exit 1; }
KEXT=${1:?candidate kext}
LOGS=${2:?log directory}
NAME=${3:-NMXGPU}
case "$NAME" in NMXGPU|NMXAccel) ;; *) echo 'unsupported candidate identity' >&2; exit 1;; esac
mkdir -p "$LOGS"
test -s "$KEXT/Contents/MacOS/$NAME"
BOOT=/System/Library/KernelCollections/BootKernelExtensions.kc
if [[ ! -s "$BOOT" ]]; then
    echo '::error::Runner has no boot kernel collection; native symbol resolution was not verified'
    exit 1
fi
WORK=$(mktemp -d /tmp/nmx-kc-check.XXXXXX)
cleanup() {
    case "$WORK" in /tmp/nmx-kc-check.*) sudo rm -rf "$WORK";; esac
}
trap cleanup EXIT
mkdir -p "$WORK/repo"
ditto "$KEXT" "$WORK/repo/$NAME.kext"
sudo chown -R root:wheel "$WORK/repo"
sudo chmod -R go-w "$WORK/repo"
ARGS=(--allow-missing-kdk -a x86_64)
if [[ -s /System/Library/KernelCollections/SystemKernelExtensions.kc ]]; then
    ARGS+=(-S /System/Library/KernelCollections/SystemKernelExtensions.kc)
fi
if [[ -f /System/Library/Kernels/kernel ]]; then
    ARGS+=(--kernel /System/Library/Kernels/kernel)
fi
if ! sudo kmutil create -n aux --volume-root / "${ARGS[@]}" -B "$BOOT" \
    --repository "$WORK/repo" -p "$WORK/repo/$NAME.kext" \
    -A "$WORK/AuxiliaryKernelExtensions.kc" -z > "$LOGS/kmutil-create.log" 2>&1; then
    tail -60 "$LOGS/kmutil-create.log"
    echo '::error::Candidate did not link into the temporary kernel collection'
    exit 1
fi
test -s "$WORK/AuxiliaryKernelExtensions.kc"
sudo kmutil inspect -a x86_64 -A "$WORK/AuxiliaryKernelExtensions.kc" \
    > "$LOGS/kmutil-inspect.txt" 2>&1
grep -Fq "com.nullmoth.$NAME" "$LOGS/kmutil-inspect.txt" || {
    echo "::error::Temporary collection omitted $NAME"; exit 1;
}
printf 'Native KC symbol/dependency preflight passed; nothing installed or loaded.\n' \
    | tee "$LOGS/kernel-collection-preflight.txt"
