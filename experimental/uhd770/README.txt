UHD 770 experimental display bring-up
====================================

This fork's current main branch does not contain the historical Intel port.
sources.json pins that port, drm-kmod and FreeBSD. The Actions workflow stages
those exact inputs and applies the readable patches in patches/. No driver code
is loaded on the GitHub runner. Executable checks use mock IOKit objects and a
small userspace compiler-cache probe.

Current scope
-------------
Basic display on Alder Lake-S and macOS 15, with enough evidence and recovery
to debug a failed attempt. This is not a complete Metal/desktop acceleration
package. Passing compilation or seeing "claimed" does not establish acceleration.

The repair batch includes:
- consistent DP tunnel configuration;
- native PCI class discovery, so the LPC/PCH is not hidden by a GPU-only cache;
- HPD null/bounds protection and bounded stage diagnostics;
- Intel scan-out via the existing i915 GGTT framebuffer pinning implementation,
  explicitly requesting a CPU-mappable aperture instead of generic GEM vmap;
- balanced mapping pins/references and framebuffer range validation;
- preserving the boot guard on probe/publication failure and removing a failed
  display claim;
- initializing buffer bounds before registration's synchronous hotplug callback;
- disabling FBC on Alder Lake-S until CPU writes have a damage/flush protocol;
- rejecting a framebuffer that cannot allocate its required VBL timer;
- real software interrupt disable/unregister and timer/target lifetime handling;
- bounded initial-mode retries with mapping cleanup and atomic configuration checks;
- registration-failure ownership and attach/stop/power-operation synchronization.
- packed gamma conversion and real DRM color commits, retained IRQ-drain work
  loops, and checked DMA/physical-map arithmetic.
- real EDID/DDC snapshots, stable progressive mode IDs, fixed-allocation mode
  switching with atomic checks/rollback, and queued connector notifications.

audit.json maps the reviewed call chain and separates hardware-proven results,
candidate repairs, known simplified
interfaces and unverified paths. In particular, hardware VBL pacing,
native runtime behavior, hardware VBL pacing, sleep/wake and the complete
ANV/Metal path still require work; this batch must not be advertised as a stable,
complete graphics driver. A missing Metal plugin in the Intel test package is
not repaired by the display mapping patch.
ACCELERATION-GAPS.txt traces the userland boundary and the current plugin's
explicit refusal to create an Intel WindowServer Metal device. Public plugin
source exists; its presence and a working framebuffer do not complete that path.

Display protocol scope
----------------------
The snapshot ABI supports one active connector. EDID is copied from DRM's actual
blob only when every declared 128-byte block has a valid checksum and the complete
blob fits 4096 bytes. Modes are progressive connector timings with stable IDs,
bounded by the original scanout width/height. Switching preserves the physical
mapping and pitch, atomically checks/commits the mode and restores the old mode on
failure. Failure to restore is reported explicitly. Mode catalogs are bounded to
64 distinct timings per framebuffer lifetime; old IDs are never reused.

DRM hotplug updates the bridge snapshot. A separate native worker polls only this
snapshot (no I2C probe in VBL), queues a connection interrupt and retains pending
changes while that interrupt is disabled. IOFramebuffer configuration probing
applies the new catalog, preventing asynchronous resize during mode enumeration.
Native DDC reads use one-based EDID blocks. Multi-output, interlaced/doublescan/
3D modes and allocation growth are explicitly unsupported by this implementation.
These source implementations do not establish HiDPI, 4K60 or Metal acceleration.

Validation
----------
The native PCI lookup is extracted from the patched source and tested by the
12-case host fixture. All kernel translation units must compile, required symbols
and stage markers must be defined/present, and the source/configuration evidence is kept
in the Actions artifact. Builds are not hardware tests.
An isolated auxiliary kernel collection preflight checks native symbol/provider
resolution using the runner's boot/system collections. It writes temporary files
only, installs/loads nothing and does not distribute that KC as a live boot image.
The actual callback/lifecycle helpers and bridge bodies also run in host fixtures
covering concurrency, cancellation, mode fallback and injected allocation/map/
commit/registration failures. Mocked services cannot verify kernel lock ordering
or actual hardware state. Windows host checks do not replace macOS compilation.

Build caches
------------
The dependency cache contains a checksum-verified drm-kmod archive and a clean
FreeBSD checkout at the pinned commit. Each build stages fresh copies, reapplies
the patches and regenerates flags. Patched source trees are not cached.

ccache covers all five active C/C++ compiler launchers. The GitHub cache is
isolated by macOS/architecture and Xcode/Clang/SDK/ccache identity. ccache uses
preprocessor mode, compiler content checking and no sloppiness, so source,
included-header and argument changes still invalidate the relevant object.
Output directories and final kexts are never restored; every source is accounted
for and the kext is linked and checked again. Compiler cache saves occur only
after the build gates pass. A disposable userspace test checks an actual cache
hit plus header, flag and source invalidation. Statistics and configuration are
included in the artifact; a first cold run is not evidence of a speedup.

For an independent diagnostic build, choose Run workflow with clean_build=true.
That skips dependency/compiler cache restore/save and bypasses ccache for the
kernel build. The disposable cache self-test still runs in its own temp folder.

Recovery contract
-----------------
Do not rely solely on "Start once without GPU driver": OpenCore configurations
that refresh boot-args can overwrite a tool's temporary argument changes. Keep a
backed-up EFI configuration that removes nmxintel/nmxdiagdelay and contains -nvoff.
Failed framebuffer publication retains the original driver's attach guard, but
the EFI opt-out is the independent recovery path. tools/disable_test.ps1 performs
that edit for an explicitly supplied config.plist, with backup and validation.
Never erase all NVRAM merely to retry an experiment. No personal machine logs or
fixed USB drive letters are committed here.

Hardware gate remains closed during source completeness review
-------------------------------------------------------------
The user requested code defects and incomplete contracts to be handled before
another boot test. audit.json records the remaining review work and readiness;
a passing build alone does not reopen that gate.

Verify actual runtime build/arguments, PCI/PCH/HPD initialization, GGTT placement
and aperture mapping, mode selection and atomic commit, IOFramebuffer publication,
then a visible desktop. Record mode/format and actual monitor signal. GPU command
execution/readback, ANV, Metal and accelerated WindowServer are separate gates.
