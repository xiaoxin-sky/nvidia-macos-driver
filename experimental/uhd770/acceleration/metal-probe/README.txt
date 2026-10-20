UHD 770 Metal compute/readback diagnostic

Build only on CI; do not execute GPU work there. This executable installs nothing,
changes no boot arguments, and does not authorize a hardware test. Use it only
after a matching kernel/ANV/frontend test package and recovery path are reviewed.

Compile (macOS 15+, x86_64)
  xcrun clang++ -arch x86_64 -mmacosx-version-min=15.0 -std=c++17 \
    -fobjc-arc -fobjc-arc-exceptions -Wall -Wextra -Werror \
    experimental/uhd770/acceleration/metal-probe/main.mm \
    -framework Foundation -framework Metal -framework IOKit \
    -framework CoreFoundation -o uhd770-metal-probe

Compile the already-produced compiler-smoke/apple.air into an Apple container:
  xcrun --sdk macosx metallib /absolute/compiler-smoke/apple.air \
    -o /absolute/compiler-smoke/smoke.metallib
Its source is compiler-smoke/smoke.metal; the entry point must be "smoke".
Building or linking this tool/metallib does not submit GPU work.

Later explicit target-machine usage
  ./uhd770-metal-probe --metallib /absolute/compiler-smoke/smoke.metallib

--help and rejected/missing arguments do not enumerate Metal devices or I/O
Registry. On an explicit normal run only, NVMTL_ENABLE=1 is set in this process,
allowing the existing frontend to offer a Metal device to this diagnostic.
Known ICD/software/debug/injection override variables are rejected; only their
names are printed. There is no fallback to another Metal device or CPU renderer.

Selection requires NVMTLDevice and an NMXAccel with a display-class PCI ancestor
8086:4680. The Metal device.registryID must equal either that accelerator's ID
or its PCI device's ID. Ambiguous matches or incomplete identity fail. Device
name, Objective-C class, both registry IDs and PCI identity are logged.

The kernel reads changing shared-buffer input and writes
  output[i] = (input[i] ^ 0x13579bdfu) + i * 17u
for all 4096 words, using 64 threadgroups x 64 threads. Three varying input rounds
check every output and verify input remains intact. Completed command status and
correct readback are required; creating a Metal device/pipeline cannot pass.
No nonuniform threadgroup path, drawable, IOSurface or WindowServer is exercised.

Each command has a 10-second status-poll deadline. A separate watchdog covers
blocking API calls and cleanup (45 seconds default, --deadline 5..120). Timeout
uses _Exit(124), avoiding unsafe waits/destruction of in-flight resources; the OS
reclaims the process context. A wedged kernel can still defeat user-space bounds.
Exit 2 means identity, environment, Metal, exception or readback failure; exit 0
and METAL_COMPUTE_READBACK_VERIFIED mean the offscreen checks and cleanup passed.

Names, registry metadata and user-space libraries are not hardware attestation.
Correlate a pass with matching kernel GPU submission/completion evidence and
record exact package hashes. A pass does not prove rendered graphics, HDMI
output, video codecs, sleep/wake or accelerated WindowServer composition.
