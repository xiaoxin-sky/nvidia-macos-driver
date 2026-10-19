UHD 770 experimental display bring-up
====================================

This fork's current main branch does not contain the historical Intel port.
sources.json pins that port, drm-kmod and FreeBSD. The Actions workflow stages
those exact inputs and applies the readable patches in patches/. No code is
loaded on the GitHub runner; the only executable test uses mock IOKit objects.

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
- rejecting a framebuffer that cannot allocate its required VBL timer.

audit.json maps the reviewed call chain and separates hardware-proven results,
candidate repairs, known simplified
interfaces and unverified paths. In particular, the IOFramebuffer interrupt
disable/unregister implementation, gamma, hotplug, sleep/wake and the complete
ANV/Metal path still require work; this batch must not be advertised as a stable,
complete graphics driver. A missing Metal plugin in the Intel test package is
not repaired by the display mapping patch.

Validation
----------
The native PCI lookup is extracted from the patched source and tested by the
12-case host fixture. All kernel translation units must compile, required symbols
and stage markers must be present, and the source/configuration evidence is kept
in the Actions artifact. Builds are not hardware tests.

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

Next hardware gate (after review and CI)
---------------------------------------
Verify actual runtime build/arguments, PCI/PCH/HPD initialization, GGTT placement
and aperture mapping, mode selection and atomic commit, IOFramebuffer publication,
then a visible desktop. Record mode/format and actual monitor signal. GPU command
execution/readback, ANV, Metal and accelerated WindowServer are separate gates.
