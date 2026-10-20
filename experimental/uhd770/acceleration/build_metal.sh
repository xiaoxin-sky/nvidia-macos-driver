#!/bin/bash
# Build the Intel accelerator/frontend; no loading or driver activation.
set -euo pipefail
ROOT=${1:?staged root}
OUT=${2:?artifact output}
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
S=$ROOT/src
N=$S/kexts/NVRM
A=$N/accel
G=$S/nvidia-headers
SDK=$(xcrun --sdk macosx --show-sdk-path)
K=$SDK/System/Library/Frameworks/Kernel.framework/Headers
mkdir -p "$ROOT/build" "$OUT/logs" "$OUT/Library/GPUBundles/nvmtl" \
  "$OUT/Library/Extensions/NMXAccel.kext/Contents/MacOS"
export MACOSX_DEPLOYMENT_TARGET=15.0
export CARGO_TARGET_DIR="$ROOT/build/rust"
export RUSTFLAGS="--remap-path-prefix=$ROOT=/src --remap-path-prefix=$HOME=/build"
python3 - "$A/nmx/Info.plist" "$OUT/Library/Extensions/NMXAccel.kext/Contents/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
data = plistlib.loads(Path(sys.argv[1]).read_bytes())
personality = data['IOKitPersonalities']['NVAccel']
personality['IOPCIPrimaryMatch'] = '0x46808086'
Path(sys.argv[2]).write_bytes(plistlib.dumps(data))
PY
INCLUDES=("$N" "$A" "$A/iofam" "$A/re" "$G/src/common/sdk/nvidia/inc"
  "$G/src/common/inc" "$G/src/common/inc/swref" "$G/src/common/inc/swref/published"
  "$G/src/nvidia-modeset/kapi/interface" "$G/src/nvidia-modeset/kapi/include"
  "$G/src/nvidia-modeset/interface" "$G/src/nvidia-modeset/include"
  "$G/src/nvidia-modeset/os-interface/include" "$G/src/common/modeset"
  "$G/src/common/unix/common/inc" "$G/src/common/unix/nvidia-push/interface"
  "$G/src/nvidia/arch/nvalloc/unix/include" "$G/src/nvidia/arch/nvalloc/common/inc"
  "$G/src/nvidia/arch/nvalloc/common/inc/gsp" "$G/src/common/sdk/nvidia/inc/hw"
  "$G/src/common/shared/inc" "$G/src/nvidia/inc" "$G/src/nvidia/inc/os"
  "$G/src/nvidia/inc/kernel" "$G/src/nvidia/kernel/inc" "$G/src/nvidia/interface"
  "$G/src/common/nvlink/interface" "$G/src/nvidia/inc/libraries"
  "$G/src/nvidia/src/libraries" "$G/src/nvidia/generated" "$G/src/nvidia/src/mm/uvm/interface"
  "$G/src/common/uproc/os/libos-v2.0.0/include" "$G/src/common/uproc/os/common/include"
  "$G/src/common/inc/displayport" "$G/src/common/nvlink/inband/interface")
ARGS=()
for directory in "${INCLUDES[@]}"; do ARGS+=(-I"$directory"); done
ccache "$(xcrun --find clang++)" -arch x86_64 -mmacosx-version-min=15.0 -fapple-kext -mkernel \
  -nostdinc -I"$K" "${ARGS[@]}" -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE \
  -DAPPLE -DNeXT -DNMX_ACCEL \
  -std=c++17 -fno-rtti -fno-exceptions -fno-builtin -fno-common -O2 \
  -Wall -Wno-unused-parameter -Wno-inconsistent-missing-override -Wno-unused-function \
  -c "$A/nvrm-accel.cpp" -o "$ROOT/build/nmx-accel.o"
xcrun clang++ -arch x86_64 -fapple-kext -nostdlib -Xlinker -kext \
  -L"$SDK/usr/lib" -lkmodc++ -lkmod -lcc_kext "$ROOT/build/nmx-accel.o" \
  -o "$OUT/Library/Extensions/NMXAccel.kext/Contents/MacOS/NMXAccel"
codesign --force --sign - "$OUT/Library/Extensions/NMXAccel.kext"
bash "$REPO/experimental/uhd770/tools/check_kernel_collection.sh" \
  "$OUT/Library/Extensions/NMXAccel.kext" "$OUT/logs" NMXAccel
cargo build --locked --release --manifest-path "$S/translator/wrapper/Cargo.toml"
python3 "$REPO/experimental/uhd770/acceleration/compiler-smoke/translate.py" \
  --library "$CARGO_TARGET_DIR/release/libnvmtl_translate.dylib" \
  --input "$REPO/experimental/uhd770/acceleration/compiler-smoke/text-air.ll" \
  --output "$ROOT/build/text-air.spv" --kind text-air \
  2>&1 | tee "$OUT/logs/translator-smoke.txt"
ccache "$(xcrun --find clang)" -arch x86_64 -isysroot "$SDK" \
  -mmacosx-version-min=15.0 -fobjc-arc -fPIC -O1 \
  -DNVMTL_RELEASE=1 -Wno-protocol -Wno-incomplete-implementation \
  -Werror=unguarded-availability-new -I"$S/vulkan-headers/include" \
  -c "$S/plugin/NVMTLDevice.m" -o "$ROOT/build/NVMTLDevice.o"
xcrun clang -arch x86_64 -mmacosx-version-min=15.0 -bundle \
  "$ROOT/build/NVMTLDevice.o" -o "$ROOT/build/NVMTLDriver" \
  -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation -lobjc
xcrun clang -arch x86_64 -mmacosx-version-min=15.0 -std=c11 -Wall -Wextra -Werror \
  -I"$LLVM_PREFIX/include" "$REPO/experimental/uhd770/acceleration/compiler-smoke/air_reader.c" \
  "$LLVM_PREFIX/lib/libLLVM.dylib" -Wl,-headerpad_max_install_names -o "$ROOT/build/air-opt"
python3 "$REPO/experimental/uhd770/acceleration/relocate.py" \
  --destination "$OUT/Library/GPUBundles/nvmtl" --search "${LLVM_PREFIX:?}/lib" \
  --report dependency-closure-metal.json \
  --input "$ROOT/build/NVMTLDriver" \
  --input "$CARGO_TARGET_DIR/release/libnvmtl_translate.dylib" \
  --input "$LLVM_PREFIX/lib/libLLVM.dylib" --input "$ROOT/build/air-opt"
PLUGIN="$OUT/Library/GPUBundles/NVMTLDriver.bundle/Contents"
mkdir -p "$PLUGIN/MacOS"
cp "$OUT/Library/GPUBundles/nvmtl/NVMTLDriver" "$PLUGIN/MacOS/NVMTLDriver"
ln -s ../../../nvmtl "$PLUGIN/MacOS/air-runtime"
python3 - "$PLUGIN/Info.plist" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleExecutable':'NVMTLDriver', 'CFBundleIdentifier':'com.nullmoth.NVMTLDriver',
    'CFBundleName':'NVMTLDriver', 'CFBundlePackageType':'BNDL',
    'CFBundleVersion':'0.1', 'CFBundleShortVersionString':'0.1'}))
PY
codesign --force --sign - "$OUT/Library/GPUBundles/NVMTLDriver.bundle"
SMOKE=$REPO/experimental/uhd770/acceleration/compiler-smoke
xcrun --sdk macosx metal -std=macos-metal2.4 -mmacosx-version-min=15.0 -O1 \
  -c "$SMOKE/smoke.metal" -o "$ROOT/build/apple.air"
"$OUT/Library/GPUBundles/nvmtl/air-opt" -S "$ROOT/build/apple.air" -o "$ROOT/build/apple.ll"
python3 "$SMOKE/translate.py" \
  --library "$OUT/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib" \
  --input "$ROOT/build/apple.ll" --output "$ROOT/build/apple-air.spv" --kind decoded-apple-air \
  2>&1 | tee "$OUT/logs/apple-air-smoke.txt"
mkdir -p "$OUT/probe"
xcrun clang++ -arch x86_64 -mmacosx-version-min=15.0 -std=c++17 \
  -fobjc-arc -fobjc-arc-exceptions -Wall -Wextra -Werror \
  "$REPO/experimental/uhd770/acceleration/metal-probe/main.mm" \
  -framework Foundation -framework Metal -framework IOKit -framework CoreFoundation \
  -o "$OUT/probe/uhd770-metal-probe"
xcrun --sdk macosx metallib "$ROOT/build/apple.air" -o "$OUT/probe/smoke.metallib"
cp "$ROOT/sources.json" "$OUT/logs/acceleration-sources.json"

echo "Intel accelerator, translator and Metal frontend compiled; nothing installed or loaded."
