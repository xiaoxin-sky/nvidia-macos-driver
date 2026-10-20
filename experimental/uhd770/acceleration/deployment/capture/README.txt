UHD770 MVP: finite boot-time evidence capture
===========================================

This folder prepares a launchd collector; nothing here installs, loads, or enables
a GPU driver. Do not run collector.sh in Windows or install the plist manually.
The deployment installer is responsible for validating and copying these files.

Fixed paths:
  /Library/Application Support/UHD770MVP/capture/collector.sh
  /Library/LaunchDaemons/com.uhd770.mvp.capture.plist
  /private/var/log/UHD770MVP/

The daemon runs as root when launchd loads it, including boot. It exits after
300 seconds by default. --duration accepts only 120..600 seconds. KeepAlive is
false, so it is not repeatedly restarted in the same boot. The independent
watchdog allows at most three further seconds before killing a stuck parent
that has not started cleanup. Controlled cleanup ignores repeat stop signals,
replaces that watchdog with an independent ten-second hard limit, and writes
the final marker before disarming its guard. This prevents the duration deadline
from killing normal cleanup. launchd's child-process cleanup is retained. Boot-time execution is
asynchronous and does not make login wait for collection.
The plist gives a stopped collector fifteen seconds, covering its ten-second
cleanup guard instead of independently killing valid cleanup after five seconds.

Permissions required before bootstrap:
  application directory and script: root:wheel, no group/other write access;
  log root: root:wheel 0700;
  launchd stdout/stderr files: root:wheel 0600, regular files without symlinks;
  plist: root:wheel 0644.
Existing symlinks must be rejected by the installer. The collector checks each
log-root ancestor, refuses writable/non-root directories, and atomically creates
a private 0700 session directory. It never overwrites another session. Metadata
includes the boot-session UUID and boot time from sysctl, macOS version, UTC
timestamps, elapsed seconds, and a random/pid session identity.

Every potentially stalled query has a stage marker written and a bounded sync
attempt before it runs. Snapshot children have a three-second limit; a failed
query disables further queries of that kind. Each query has a bounded output
file size. The kernel log stream runs only inside the finite collector window,
has its own output cap, and filters kernel messages for NMXGPU, NMXAccel,
NullMoth, i915, drm, or UHD770. Stream startup/early exit is marked explicitly.
The stream does not contain a full unified-log archive. dmesg's finite kernel
ring buffer may also contain unrelated kernel events; review it before sharing.

IORegistry snapshots query only NMXGPU and NMXAccel services, never a full-tree
dump. They read registry properties and do not open a GPU user client. There is
no Metal/Vulkan execution, system_profiler, log collect, network listener,
driver loading, EFI access, NVRAM change, display change, or automatic reboot.

Reports persist on the macOS system data volume. If HDMI loses signal and the
machine must be manually restarted, retain all session-* directories and copy
them out after recovery. A second boot creates another session rather than
replacing the interrupted session. Startup failures before a private session is
possible appear in launchd.stderr.txt. Interrupted capture can have partial
files; an absent end marker does not prove a kernel crash. A sync timeout or a
hard power cut can lose final writes. Spinning fans do not prove that the kernel
or collector is still running; use surviving heartbeat timestamps as evidence.

Old sessions are not automatically deleted. Uninstalling capture should unload
the job first and preserve reports. Installation/uninstallation belongs to the
separate deployment workflow; this folder deliberately has no such commands.

Host-only fixture (Git Bash on Windows or any Bash host):
  bash experimental/uhd770/acceleration/deployment/capture/test_capture.sh

The fixture substitutes mock commands, writes only its temporary directory,
never accesses /Library, and neither installs launchd nor opens a GPU. It checks
timeouts, stream-start failure, separate reports, marker order, snapshot data,
staged file creation, and shell syntax. The companion test_capture_finish.sh
exercises natural/deadline cleanup races and the independent cleanup hard limit.
Native launchd behavior and persistence
across an actual black-screen/reboot remain macOS hardware tests.
