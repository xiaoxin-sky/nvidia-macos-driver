Offline compiler and translator checks (no GPU)

The text fixture and the real Apple compiler path establish different facts.
Do not report a passing hand-authored fixture as successful Apple AIR decoding.
Neither path loads ANV, opens a DRM device, submits GPU work or installs a driver.

1. Translator ABI independently of Apple's compiler/bitcode reader

  SMOKE="$GITHUB_WORKSPACE/experimental/uhd770/acceleration/compiler-smoke"
  LIB="$OUT/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib"
  mkdir -p "$OUT/logs/compiler-smoke"
  python3 "$SMOKE/translate.py" --library "$LIB" \
    --input "$SMOKE/text-air.ll" \
    --output "$OUT/logs/compiler-smoke/text-air.spv" --kind text-air

This calls the actual built Rust cdylib, validates SPIR-V framing plus compute
entry/store instructions, saves the result and frees the native boxed slice using
the exported Rust free function with its original length. The child has a finite
deadline; a Rust abort or native crash fails the check. Full SPIR-V validation is
still a separate spirv-val check when that tool has been built.

2. Real Apple Metal source -> AIR bitcode -> LLVM reader -> translator

  xcrun --sdk macosx --find metal
  xcrun --sdk macosx metal -std=metal2.4 -mmacosx-version-min=15.0 -O1 \
    -c "$SMOKE/smoke.metal" -o "$OUT/logs/compiler-smoke/apple.air"
  "$OUT/Library/GPUBundles/nvmtl/air-opt" -S \
    "$OUT/logs/compiler-smoke/apple.air" \
    -o "$OUT/logs/compiler-smoke/apple.ll"
  python3 "$SMOKE/translate.py" --library "$LIB" \
    --input "$OUT/logs/compiler-smoke/apple.ll" \
    --output "$OUT/logs/compiler-smoke/apple-air.spv" --kind decoded-apple-air

Use the relocated artifact's air-opt so this checks its packaged dylib closure,
not an unrelated system LLVM. Keep compiler versions and all three intermediates
as evidence. This covers the opt-based fallback reader; an in-process libLLVM
smoke check remains distinct.

Some Xcode runner images have a metal stub without the downloadable Metal
Toolchain. --find alone is not proof of availability: the compile command must
succeed. If unavailable, explicitly mark the Apple AIR step unverified, or make
it a required failing gate until the toolchain is provisioned. Never silently
substitute text-air.ll for an Apple compilation/reader pass.

The --kind value labels caller-supplied provenance; it is not an attestation.
Keep the commands/artifacts together so decoded-apple-air has verifiable evidence.
