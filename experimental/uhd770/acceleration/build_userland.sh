#!/bin/bash
# Build the pinned real Intel ICD and a diagnostic; never run a GPU on CI.
set -euo pipefail
ROOT=${1:?fresh staged root}
OUT=${2:?artifact output}
REPO=$(cd "$(dirname "$0")/../../.." && pwd)
S=$ROOT/src
B=$ROOT/build
P=$ROOT/prefix
LLVM=${LLVM_PREFIX:?LLVM 18 prefix required}
mkdir -p "$B" "$P" "$OUT/logs" "$OUT/Library/GPUBundles/nvmtl" "$OUT/probe"
export MACOSX_DEPLOYMENT_TARGET=15.0
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export CFLAGS="-isysroot $SDKROOT -mmacosx-version-min=15.0"
export CXXFLAGS="$CFLAGS" LDFLAGS="$CFLAGS"
export CC="$(xcrun --find clang)" CXX="$(xcrun --find clang++)"
export PATH="$P/bin:$LLVM/bin:$PATH"
export PKG_CONFIG_PATH="$P/lib/pkgconfig:$LLVM/lib/pkgconfig"
export CMAKE_PREFIX_PATH="$P:$LLVM"
xcrun clang -std=c11 -Wall -Wextra -Werror -I"$S/mesa/src/intel/vulkan" \
  "$REPO/experimental/uhd770/acceleration/tests/nmx-mmap-fixture.c" \
  -o "$ROOT/build/nmx-mmap-test"
"$ROOT/build/nmx-mmap-test" | tee "$OUT/logs/nmx-mmap-test.txt"
COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64
  -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_INSTALL_PREFIX="$P"
  -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON)
cmake -S "$S/vulkan-headers" -B "$B/vulkan-headers" "${COMMON[@]}"
cmake --install "$B/vulkan-headers"
CC="ccache $CC" CXX="ccache $CXX" meson setup "$B/libdrm" "$S/libdrm" --prefix="$P" --libdir=lib \
  -Dauto_features=disabled -Dbuildtype=release -Dtests=false \
  -Dinstall-test-programs=false -Dudev=false
meson compile -C "$B/libdrm" -j 3
meson install -C "$B/libdrm"
cmake -S "$S/spirv-tools" -B "$B/spirv-tools" "${COMMON[@]}" \
  -DSPIRV-Headers_SOURCE_DIR="$S/spirv-headers" -DSPIRV_SKIP_TESTS=ON \
  -DSPIRV_SKIP_EXECUTABLES=ON -DSPIRV_WERROR=OFF
cmake --build "$B/spirv-tools" -j 3
cmake --install "$B/spirv-tools"
cmake -S "$S/glslang" -B "$B/glslang" "${COMMON[@]}" -DCMAKE_PREFIX_PATH="$P" \
  -DBUILD_EXTERNAL=OFF -DGLSLANG_TESTS=OFF -DGLSLANG_ENABLE_INSTALL=ON \
  -DALLOW_EXTERNAL_SPIRV_TOOLS=ON -DENABLE_OPT=ON -DENABLE_PCH=OFF
cmake --build "$B/glslang" -j 3
cmake --install "$B/glslang"
if [[ ! -x "$P/bin/glslangValidator" && -x "$P/bin/glslang" ]]; then
  ln -s glslang "$P/bin/glslangValidator"
fi
cmake -S "$S/spirv-llvm-translator" -B "$B/spirv-llvm" "${COMMON[@]}" \
  -DCMAKE_PREFIX_PATH="$P;$LLVM" -DLLVM_DIR="$LLVM/lib/cmake/llvm" \
  -DLLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR="$S/translator-spirv-headers" \
  -DLLVM_SPIRV_INCLUDE_TESTS=OFF -DBUILD_SHARED_LIBS=ON -DLLVM_LINK_LLVM_DYLIB=ON
cmake --build "$B/spirv-llvm" -j 3
cmake --install "$B/spirv-llvm"
CC="ccache $CC" CXX="ccache $CXX" meson setup "$B/mesa" "$S/mesa" --prefix="$P" --libdir=lib \
  -Dauto_features=disabled -Dbuildtype=release -Dvulkan-drivers=intel \
  -Dgallium-drivers= -Dplatforms= -Dopengl=false -Dgles1=disabled -Dgles2=disabled \
  -Degl=disabled -Dglx=disabled -Dgbm=disabled -Dglvnd=disabled \
  -Dshared-glapi=disabled -Dllvm=enabled -Dshared-llvm=enabled -Dmesa-clc=enabled \
  -Dintel-rt=disabled -Dbuild-tests=false -Dtools= -Dvulkan-layers= \
  -Dspirv-tools=enabled -Dxmlconfig=disabled -Dexpat=disabled -Dzstd=disabled \
  -Dlibunwind=disabled -Dvalgrind=disabled -Dlmsensors=disabled \
  -Dxlib-lease=disabled -Dgallium-rusticl=false
ninja -C "$B/mesa" -j 3 src/intel/vulkan/libvulkan_intel.dylib
cmake -S "$S/vulkan-loader" -B "$B/loader" "${COMMON[@]}" \
  -DVULKAN_HEADERS_INSTALL_DIR="$P" -DBUILD_TESTS=OFF -DBUILD_WSI_METAL_SUPPORT=OFF
cmake --build "$B/loader" -j 3
cmake --install "$B/loader"
cmake -S "$REPO/experimental/uhd770/acceleration/probe" -B "$B/probe" \
  "${COMMON[@]}" -DVULKAN_INCLUDE_DIR="$P/include"
cmake --build "$B/probe" -j 3
cp "$B/mesa/src/intel/vulkan/libvulkan_intel.dylib" "$OUT/Library/GPUBundles/nvmtl/"
cp "$B/probe/uhd770-compute-probe" "$B/probe/verify.comp.spv" "$OUT/probe/"
python3 "$REPO/experimental/uhd770/acceleration/relocate.py" \
  --destination "$OUT/Library/GPUBundles/nvmtl" --search "$P/lib" --search "$LLVM/lib" \
  --report dependency-closure-userland.json \
  --input "$P/lib/libvulkan.1.dylib" \
  --input "$B/mesa/src/intel/vulkan/libvulkan_intel.dylib"
cp "$ROOT/sources.json" "$OUT/logs/acceleration-sources.json"
cp "$B/mesa/meson-logs/meson-log.txt" "$OUT/logs/mesa-configure.txt"
cp "$B/libdrm/meson-logs/meson-log.txt" "$OUT/logs/libdrm-configure.txt"
python3 - "$OUT/Library/GPUBundles/nvmtl/intel_icd.json" <<'PY'
import json, sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({"file_format_version":"1.0.0", "ICD":{
    "library_path":"./libvulkan_intel.dylib", "api_version":"1.3.0"}}, indent=2) + "\n")
PY
ln -s libvulkan.1.dylib "$OUT/Library/GPUBundles/nvmtl/libvulkan.dylib"
echo "Real Intel ICD and compute diagnostic compiled; no GPU executed."
