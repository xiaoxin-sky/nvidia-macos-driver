Explicit compute runner (prepared, NOT enabled)
==============================================

This directory supplies a future manual diagnostic entry point. This deployment
round only stages files and checks a temporary kernel collection; it does not
install or load NMXGPU/NMXAccel into the live system and does not submit GPU work.
Consequently these commands are NOT the user's next installation instructions.

The first opt-in hardware stage remains Vulkan compute/readback. Metal is a
separate, later explicit invocation after Vulkan results and kernel evidence
have been reviewed. A successful Vulkan test never starts Metal automatically.
Neither test proves WindowServer rendering or scanout acceleration.

The optional machine-specific single-session package supersedes that manual
sequence: session-user.sh runs these same guarded entry points in order after
the root job verifies next-boot recovery and NMXGPU reports attach.complete.
Only a successful Vulkan invocation proceeds to Metal. Neither runner itself
chains the next phase. See ../README-session.txt for installation/recovery.

Installer contract
------------------
Install these scripts as root:wheel, executable/readable, without group/other
write access, under:
  /Library/Application Support/UHD770MVP/probes/run-probe.sh
  /Library/Application Support/UHD770MVP/probes/runner-lib.sh
Strip inherited ACLs from the dedicated UHD770MVP tree. Ancestors and the full
components tree must remain root owned, not group/other writable, and ordinary
directories. No installer-provided environment can bypass production gates.

Keep candidate evidence.json at:
  /Library/Application Support/UHD770MVP/evidence.json
Merge the verified kernel, userland and Metal tar payloads under:
  /Library/Application Support/UHD770MVP/components/
The real archive paths are:
  components/Library/Extensions/NMXGPU.kext/Contents/MacOS/NMXGPU
  components/Library/Extensions/NMXAccel.kext/Contents/MacOS/NMXAccel
  components/Library/GPUBundles/nvmtl/libvulkan.1.dylib
  components/Library/GPUBundles/nvmtl/libvulkan_intel.dylib
  components/Library/GPUBundles/nvmtl/intel_icd.json
  components/Library/GPUBundles/NVMTLDriver.bundle/
  components/probe/uhd770-compute-probe
  components/probe/verify.comp.spv
  components/probe/uhd770-metal-probe
  components/probe/smoke.metallib
  components/probe/render.metallib
Preserve the signed air-runtime -> ../../../nvmtl and the loader's
libvulkan.dylib -> libvulkan.1.dylib links. Other staged links are refused.

For a FUTURE Metal activation stage, the frontend itself directly opens native
Intel libraries under /Library/GPUBundles/nvmtl. Its probe deliberately rejects
NVMTL_ICD_LIB and ICD/debug/injection overrides. A separate installer therefore
must place identical runtime and NVMTLDriver.bundle bytes/links in their real
/Library/GPUBundles destinations. The runner compares every installed entry with
the staged candidate and refuses missing/different/extra entries. This runner
does not perform that installation or make the bundle visible to Metal.

Manual invocation contract (future reviewed hardware session)
------------------------------------------------------------
Run the installed script directly as the ordinary logged-in macOS user. Do not
use sudo and do not invoke it with `bash script`: its #!/bin/bash -p shebang
avoids inherited BASH_ENV and exported shell functions.

  "/Library/Application Support/UHD770MVP/probes/run-probe.sh" vulkan

Only after that stage is independently reviewed:

  "/Library/Application Support/UHD770MVP/probes/run-probe.sh" metal

Optional --output requires an existing absolute user-owned private directory
(mode 700). Default sessions go to the account's actual system-disk home under
~/Library/Logs/UHD770MVP. /Volumes output is rejected to keep evidence off the
boot USB. Each invocation creates a separate unique session. Never run both
phases concurrently. The script does not activate a driver, change an EFI file,
write NVRAM, run vulkaninfo, enumerate extra devices, or edit any global env.

Before execution, the runner checks native x86_64 macOS, nonroot identity, fixed
installed script path, protected root-owned staged files, and loaded NMXGPU
UUID versus the candidate's actual Mach-O LC_UUID. Metal also requires the
loaded NMXAccel UUID and installed userland byte identity. kextstat output is
saved verbatim; no Xcode/otool/dwarfdump/Python dependency is needed. A UUID
match records loaded image identity, not cryptographic attestation of a kernel.

The Vulkan runner passes the exact staged loader path and writes a per-session
ICD JSON with an absolute libvulkan_intel.dylib path. It uses the real 8086:4680
probe's existing options: 4099 words, 3 iterations, --deadline 45. Metal uses
--metallib with the staged smoke.metallib and --deadline 45; it performs 3 rounds
of 4096 words. Both diagnostic children get a clean process-local environment.
The Metal probe enables NVMTL only inside its own process. The user's session
environment and global Metal settings are unchanged.

Evidence and failure contract
-----------------------------
session.marker is written and synced at preparation time. System/boot UUID,
raw loaded-driver identity, hashes of scripts, candidate evidence, diagnostic,
shader and runtime libraries, plus one argument per line, are recorded BEFORE
the probe-start.marker is written and synced. The diagnostic writes unbuffered
stdout/stderr directly to probe.log; tail displays a live copy, so the log does
not depend on an unread shell pipe. Best effort sync occurs every two seconds.

The diagnostic has its own 45-second watchdog, including initialization and
cleanup. A separate shell watchdog permits at most 55 seconds, then TERM and
after two seconds KILL, with a fallback TERM to the waiting runner if its child
cannot be reaped. Exit 124 means a deadline. No macOS `timeout` command or
Homebrew dependency is assumed. User-space deadlines cannot recover a kernel
hang, system panic or dead display; a missing completion marker is unresolved,
not success. Persistent logging in the separate recorder is still required.

Success requires BOTH exit zero and the phase-specific start-of-line marker:
  COMPUTE_READBACK_VERIFIED:
  METAL_COMPUTE_READBACK_VERIFIED:
result.txt records only a compute readback verdict; correlate it with kernel
GPU submission and completion evidence. Any nonzero exit, wrong/missing marker,
or preparation failure is a failed/unresolved session. Initialization alone,
a larger VRAM number, or reaching the desktop is not a verified result.

Offline validation
------------------
  bash -n run-probe.sh
  bash -n runner-lib.sh
  bash test-runner.sh

The fixtures run on Git Bash as well as macOS. They source only inert lifecycle
helpers and execute fake shell children. They test marker ordering, nonzero exit,
wrong-phase/missing marker rejection, bounded TERM-resistant timeout and native
Mach-O UUID parsing. The real entry point has no mock mode and non-macOS calls
are refused. These fixtures do not emulate or claim target Mac hardware success.
