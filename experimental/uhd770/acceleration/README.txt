Intel acceleration MVP: reproducible diagnostic components
========================================================

This work targets one Alder Lake-S UHD 770 (8086:4680), x86_64 macOS 15 and
application GPU execution. It is under source/build review. Hardware-test
readiness remains false: these files do not authorize or automate installation.

The userland job builds pinned Darwin libdrm, real Mesa ANV, a Vulkan loader
and a compute/readback diagnostic. The Metal job builds NMXAccel, the existing
NVMTL frontend and its Rust translator. The kernel NMXGPU build is a separate
workflow. Source archives are digest-checked and staged fresh; the source cache
never restores patched trees or finished binaries.

Mesa repairs route i915 BO mappings through the NMX node ioctl, preserving exact
slice ownership for full unmap. Ordinary shmem WB/WC/UC mappings are the intended
subset. Placed/reserved mappings and unimplemented external-FD/modifier paths
must not be advertised as available. Non-FD internal syncobjs remain separate.
The matching kernel page-pin lifecycle repair has passed its source/build
gates. A CPU mapping alone is not a pinned GEM object; real memory visibility
and GPU completion are still separate hardware gates.

The compute diagnostic requires known varying GPU results, a matching real Intel
device/driver, a finite fence wait and a complete readback comparison. CI only
compiles the program and its shader; it never opens a GPU or runs the probe.
Creating a Vulkan/Metal device or compiling with a noop driver is not success.

Metal application rendering and WindowServer composition are separate gates.
The current frontend deliberately denies Intel WindowServer. Desktop composition,
hardware VBL delivery, full sleep/wake and video codecs are outside this first
application MVP. No claim of working Metal, desktop acceleration or 4K60 follows
from a successful component build.

The node-identity repair requires a matched new kernel and libdrm. XNU's dynamic
published/clone minors differ from logical DRM indices. libdrm-nmx-node.patch
uses real node paths and NMX_DRM_IOCTL_NODE_INFO instead of treating those IDs as
renderD suffixes. The native interposed-inventory test opens only /dev/null;
it verifies the compiled library's discovery contract, not GPU execution.

XNU creates a fresh clone vnode/minor on every lookup of these nodes, including
stat (xnu-11417.140.69 bsd/miscfs/devfs/devfs_tree.c: devfs_dntovn). Discovery
therefore opens canonical candidates and queries NODE_INFO/PCIINFO on each fd;
it never compares dev_t values from separate lookups. Bare-dev_t lookup APIs
return ENOTSUP on Darwin. The native test changes every stat ID and checks
failure cleanup, permissions and replaced nodes against the compiled library.
The manual Vulkan diagnostic enables NMX_DRM_DEBUG only in its own process.

The native node adapter owns a compatibility inode with each file, so
linux_iminor can resolve the logical DRM minor at the first open. XNU open
receives zero on a successful LinuxKPI file-operations handoff. The file and
inode retain a separate cdev reference when Linux keeps the file after devfs
close. Native fdrop decrements; Linux fput already decremented before _fdrop,
which must perform final cleanup without subtracting a second time. The kernel
job executes these actual functions with inert services before building a kext.

The r14 hardware panic reached linux_file_close -> synchronize_rcu -> the
thread registry spin lock (TLB/IPI timeout). The Darwin RCU override retains CK
grace periods and callback order, using a shared epoch record per RCU type with
short serialized begin/end updates. Readers can migrate/sleep without keeping
interrupts disabled; waiters yield to XNU instead of using unimplemented BSD
CPU binding. The registry masks local interrupts only while its lock is held.
CK must retain multiprocessor atomics even without FreeBSD's SMP define. Native
CI exercises the actual CK source, concurrent readers/waiters and deferred
callbacks. These host checks do not establish real GPU/IRQ stability.

The ordinary Metal buffer/texture/compute path uses ANV allocations. NMXAccel's
inherited family GPUVA/VRAM callbacks still depend on NVIDIA RM and are not an
Intel allocation implementation. Hardware resource pools, cross-process shared
texture handles and family-managed presentation are outside this MVP. Apple's
private MTLIOAccelDevice initialization remains a separate native runtime gate;
source compilation cannot prove that it avoids those unsupported callbacks.

Artifacts contain diagnostic files, not an installation command. Do not combine
arbitrary older kernel/userland versions. A later reviewed test kit must record
all source/binary identities, recovery steps and the exact test scope.

The 2026-10-20 offline candidate checkpoint is recorded in audit.json. Kernel
run 39362467512 and userland/Metal run 39363536141 passed; the kernel sources
match across their separate source commits. kit/assemble.py checks all input
digests/evidence and produces a candidate with hardware_ready=false. It does
not install/activate anything. NMXGPU and the probes are unsigned; this is not
a fully signed, directly installable package. The separate installation plan
must address trust, independent recovery and automatic persistent logs.

deployment/ now provides Windows-side digest-pinned firmware/tool packaging and
Mac-side read-only inventory, private staging/temporary KC checks, a bounded
launchd recorder, and explicit separate compute runners. Run 39367028209 at
defaef1 passed the targeted Python, system Bash, mocked lifecycle/timeout/UUID
and plist checks on Ubuntu and Intel macOS. No launchd job or driver was installed
there, and no GPU was accessed. Start with the target-machine preflight only;
transactional live driver installation and recovery-EFI validation are pending.
