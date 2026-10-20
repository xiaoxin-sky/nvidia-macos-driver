Intel ANV compute/readback probe (opt-in, no installation)

Purpose
  Establish the first acceleration milestone below Metal: an Intel ANV device
  consumes uploaded data, executes a compute dispatch, completes its fence, and
  returns every expected output word. Creating a Vulkan device alone cannot pass.
  This does not test Metal, image rendering, HDMI scanout or WindowServer.

Build only (safe for GitHub Actions; never run GPU work there)
  Required: CMake >= 3.20, C++17 compiler, Threads, Vulkan-Headers, and a pinned
  glslangValidator executable. No SDK loader library is linked at build time.

  cmake -S experimental/uhd770/acceleration/probe -B build/uhd770-probe \
    -DVULKAN_INCLUDE_DIR=/absolute/Vulkan-Headers/include \
    -DGLSLANG_VALIDATOR=/absolute/bin/glslangValidator
  cmake --build build/uhd770-probe --config Release

  Outputs: uhd770-compute-probe and verify.comp.spv (multi-config generators put
  the executable in Release/). The .comp source is compiled as Vulkan 1.1 SPIR-V
  at build time; the shader binary must be kept with the matching executable.
  There is deliberately no CTest registration or post-build invocation.

Target-machine run (ONLY after the matched ANV/kernel package is reviewed)
  ./uhd770-compute-probe \
    --loader /absolute/path/libvulkan.1.dylib \
    --icd /absolute/path/intel_icd.json \
    --shader /absolute/path/verify.comp.spv

  These are placeholders, not paths to an already complete driver package.
  The ICD JSON must name the intended native Intel ANV library. Environment
  selectors are scoped to this process. Explicit/implicit Vulkan layers are
  disabled where supported by the selected loader.

Selection and result interpretation
  Default: vendor 8086, device 4680, integrated GPU, and Intel open-source Mesa
  driver ID. Software/CPU ICDs, MoltenVK, NVIDIA/AMD, and missing driver identity
  are rejected. --device-id permits another Intel integrated device explicitly;
  that result must not be reported as UHD 770 success.
  The selected ICD and driver-reported name/version/PCI IDs are logged; BDF is
  logged when VK_EXT_pci_bus_info exists. Metadata can be spoofed by a bad ICD:
  correlate a pass with kernel submission/completion evidence and the package
  provenance before claiming real hardware success. This tool cannot attest it.

  Default: 3 changing seeds x 4099 words, including a partial workgroup. Every
  output is checked. HOST_VISIBLE buffer memory may be coherent or noncoherent;
  noncoherent memory is explicitly flushed/invalidated over the full allocation.
  Each submission has a 10-second fence timeout. A 45-second overall watchdog
  also covers blocked driver calls and teardown; --deadline accepts 5..120 s.
  --count accepts 1..1048576; --iterations accepts 1..32.

  Exit 0: all dispatch/readback checks and normal cleanup completed.
  Exit 2: identity, Vulkan, shader, or output verification failure.
  Exit 124: fence/overall timeout. In-flight failures terminate without unsafe
  teardown, intentionally leaving context cleanup to the OS. A wedged kernel
  may still defeat a user-space deadline; these are experimental GPU tests.

  COMPUTE_READBACK_VERIFIED is printed after readback verification; the process
  must also exit 0 (teardown can still fail or time out after that line).
  --help and invalid/missing arguments do not open a loader or submit GPU work.
