Offline compiled-candidate kit assembler

This tool combines three explicitly chosen, independently checksum-verified
GitHub Actions artifacts. It never installs, activates, loads or tests a GPU.
Even a fully accepted kit has hardware_ready=false. Native device initialization,
real GPU execution, Metal and desktop acceleration remain separate gates.

Use Python 3.10 or newer on Windows or macOS. Create a JSON manifest:

{
  "components": {
    "kernel": {
      "zip": "D:/downloads/kernel-artifact.zip",
      "sha256": "<64 lowercase hexadecimal characters from trusted artifact metadata>",
      "run_url": "https://github.com/xiaoxin-sky/nvidia-macos-driver/actions/runs/<run-id>",
      "source_commit": "<full 40-character source commit>"
    },
    "userland": { "zip": "...", "sha256": "...", "run_url": "...", "source_commit": "..." },
    "metal": { "zip": "...", "sha256": "...", "run_url": "...", "source_commit": "..." }
  }
}

Paths may be absolute or relative to the manifest. Obtain the expected ZIP
digests and run/commit identity independently from GitHub artifact/run metadata.
The tool verifies those supplied claims, not GitHub itself. Kernel artifacts
currently lack an internal source-commit file; evidence explicitly labels that
commit as manifest-declared. Userland/Metal source-commit logs must match.

python experimental/uhd770/acceleration/kit/assemble.py --manifest inputs.json --output D:/UHD770-candidate

The output directory must not already exist. No existing files are removed or
overwritten. Every input ZIP digest and all evidence checks must pass before
the tool creates the directory. Filesystem errors during writing may leave an
incomplete directory; a subsequent attempt must use a new directory.

Optional --dependency-root points to the local directory containing pristine
mesa, libdrm, Vulkan-Loader, SPIRV-Tools and other dependency source directories.
Available license files are copied into source-and-licenses/dependencies. The
project LICENSE/NOTICE and translator LICENSE/COPYING are always included,
together with immutable dependency source manifests. This is a local diagnostic
kit, not a claim that all redistribution obligations have been audited.

Required evidence

- Kernel: 900 DRM/AMD + 274 i915 + 76 runtime compilation logs, no failed units,
  successful source summaries, mapping/workqueue lifecycle tests and native KC
  linkage preflight, plus the NMX node-identity kernel helper/ABI check.
  The native node open/identity/close fixture is also required, including a
  retained Linux file finalized by fput after its native descriptor was closed.
  Require the real CK/RCU concurrency fixture too; earlier node-open fixtures
  mocked synchronize_rcu and did not cover the r14 native-close panic path.
  The transitive fence-wait fixture now includes the actual Linux schedule/wake
  functions and actual native sleepqueue/condition adapter, with Mach primitives
  supplied by a host event model. Hardware IRQ delivery remains unverified.
  The ioctl fixture joins LinuxKPI's real buffer-remapping/copy helpers and DRM's
  real dispatch/permission logic around an inert query-layout handler. It checks
  native ABI sizes, nested user pointers, output direction and error propagation;
  it does not execute a real i915 command or validate GPU submission.
  The joined mm fixture compiles actual Linux ownership and native task/copy/wire
  code in separate C/C++ units and checks concurrent creators, cached-owner
  replacement, foreign-worker cleanup and allocation/prepare failures. IOKit
  descriptor/task primitives are host models; real GPU visibility is unproven.
- Userland: final real-ANV/probe build marker, ANV mapping fixture, clock boundary
  fixture and native CLOCK_UPTIME_RAW versus mach_absolute_time comparison.
  Earlier userland artifacts without native_clock_smoke.txt are rejected.
  The compiled-libdrm node/clone identity test is also required. Earlier kernel
  or libdrm artifacts without NMX_DRM_IOCTL_NODE_INFO evidence are rejected, so
  the new userspace cannot silently be combined with the r8 kernel.
  The changing-lookup discovery marker is required too: earlier tests assumed
  stable stat IDs and cannot validate XNU clone-node enumeration.
- Metal: final build marker, native KC preflight and actual decoded Apple AIR
  translated to a checksummed SPIR-V result with gpu_executed=false.

Outputs

- uhd770-acceleration-{kernel,userland,metal}.tar.gz
- evidence.json and raw evidence logs
- SHA256SUMS, README.txt, source pointers and available licenses

Keep these tar.gz files intact on Windows. Userland and Metal tar bytes are
copied verbatim so executable modes and signed bundle symlinks remain intact.
The signed bundle air-runtime -> ../../../nvmtl link is explicitly checked.
No Mach-O binary or symlink is extracted on Windows. The kernel ZIP has lost
Unix modes, so its NMXGPU.kext file bytes are repackaged as a tar with 755
directories/executable and 644 other files. Logs do not enter the kext tar.

Validation checks archive paths and link targets without extracting them. The
tool refuses duplicate paths, traversal, absolute/escaping/dangling/cyclic links,
members nested under links and privileged/device entries.

Targeted checks: python -m unittest discover -s experimental/uhd770/acceleration/kit -p "test_*.py"
