"""Exercise the production session entry points with fake macOS services.

The copied entry points redirect only platform paths, identity and command
adapters into one temporary tree. Their preparation, EXIT recovery and user
coordinator bodies are unchanged. No real disk inventory or GPU is accessed.
"""

import json
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

import prepare_kit


DISPATCHER = r'''#!/usr/bin/env python3
import os, pathlib, plistlib, shutil, subprocess, sys
root = pathlib.Path(os.environ['SESSION_FIXTURE'])
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
failure = os.environ.get('SESSION_FAIL', '')
if name == 'uname': print('Darwin' if args == ['-s'] else 'x86_64')
elif name == 'sw_vers': print('15.7.9')
elif name == 'id': print('fixture' if args[0] in ('-nu', '-un') else '20')
elif name == 'dscl': print('NFSHomeDirectory: ' + str(root / 'mac/Users/fixture'))
elif name == 'sysctl':
    boot = os.environ.get('SESSION_BOOT', 'BASE')
    if args == ['-n', 'kern.bootsessionuuid']: print(boot)
    elif args == ['-n', 'kern.bootargs']:
        print('-v -nvoff' if boot == 'BASE' else '-v nmxintel=1 nmxdiagdelay=180')
    else: print('fixture boot identity')
elif name == 'stat':
    path = pathlib.Path(args[-1])
    if args[1] == '%u': print('501' if '/Users/fixture' in str(path) else '0')
    elif args[1] == '%z': print(path.lstat().st_size)
    elif args[1] == '%Lp': print('700' if path.is_dir() else '600')
    else: sys.exit(93)
elif name == 'csrutil': print('Kext Signing: disabled')
elif name == 'nvram':
    print('data was not found', file=sys.stderr); sys.exit(1)
elif name == 'ioreg':
    if 'IGPU' in args: print('"device-id" = <80460000>\n"vendor-id" = <86800000>')
    elif os.environ.get('SESSION_BOOT') == 'TEST':
        print('"nullmoth-gpu-state" = "failed: port attach; guard retained"' if failure == 'init' else
              '"nmxdiag-stage" = "attach.complete ret=0"\nclass NMXGPUFB')
elif name == 'diskutil':
    if failure == 'usb-recovery' and os.environ.get('SESSION_BOOT') == 'TEST': sys.exit(25)
    sys.stdout.buffer.write(plistlib.dumps({'MountPoint': str(root / 'mac/Volumes/1401'),
        'VolumeUUID': 'FIXTURE-UUID', 'VolumeName': '1401', 'BusProtocol': 'USB'}))
elif name == 'plutil':
    path = pathlib.Path(args[-1]); data = plistlib.loads(path.read_bytes())
    if args[0] == '-extract': print(data[args[1]])
    elif args[0] == '-insert':
        data[args[1]] = int(args[3]) if args[2] == '-integer' else args[3]
        path.write_bytes(plistlib.dumps(data))
    else: sys.exit(91)
elif name == 'ditto':
    source, target = map(pathlib.Path, args)
    if source.is_dir(): shutil.copytree(source, target, symlinks=True, dirs_exist_ok=True)
    else: shutil.copy2(source, target)
elif name == 'kmutil':
    if args[0] == 'create':
        if failure == 'kc': sys.exit(29)
        pathlib.Path(args[args.index('-A')+1]).write_bytes(b'candidate KC')
    else: print('com.fixture.other\ncom.nullmoth.NMXGPU\ncom.nullmoth.NMXAccel')
elif name == 'launchctl':
    if failure == 'bootstrap' and args[0] == 'bootstrap': sys.exit(28)
    if args[0] == 'bootstrap':
        installed = root / 'mac/Library/Application Support/UHD770MVP'
        command = ['/bin/bash', '-p', str(installed / 'incoming/tools/session.sh'), 'boot'] if args[1] == 'system' else \
                  ['/bin/bash', '-p', str(installed / 'session-tools/session-user.sh')]
        sys.exit(subprocess.run(command, timeout=60).returncode)
    if args == ['bootout', 'system/com.uhd770.mvp.capture']:
        with (root / 'flow-events').open('a') as stream: stream.write('capture-stop\n')
        if failure == 'capture-stop': sys.exit(26)
        report = root / 'mac/private/var/log/UHD770MVP/session-test'
        report.mkdir(exist_ok=True)
        (report / 'boot-identity.txt').write_text('kern.bootsessionuuid: TEST\n')
        with (report / 'stages.txt').open('a') as stream:
            stream.write('elapsed_s=7 collector_end reason=deadline_or_termination\n')
elif name == 'sudo':
    if args[:3] != ['-n', '-u', '#501']: sys.exit(94)
    # The real fixture already owns every temporary file; emulate only the
    # bounded selected-user head read, never an actual privilege transition.
    if args[3:6] != ['/usr/bin/head', '-c', '513']: sys.exit(95)
    sys.exit(subprocess.run(args[3:], timeout=5).returncode)
elif name == 'dmesg': print('fixture final kernel snapshot')
elif name == 'codesign':
    if failure == 'signature': sys.exit(27)
elif name in ('sync', 'sleep', 'chown', 'chmod', 'PlistBuddy'): pass
else: sys.exit(92)
'''

MANAGER = r'''#!/bin/bash
set -eu
base="$SESSION_FIXTURE/mac"
root="$base/Library/Application Support/UHD770MVP"
case "$1" in
 stage)
   cp -R "$SESSION_FIXTURE/seed" "$root"
   mkdir "$root/incoming"
   cp -R "$SESSION_FIXTURE/kit/." "$root/incoming/"
   ;;
 install-recorder)
   report="$base/private/var/log/UHD770MVP/session-fixture"
   mkdir -p "$report"
   printf 'kern.bootsessionuuid: BASE\n' > "$report/boot-identity.txt"
   printf '%s\n' 'elapsed_s=1 heartbeat stream_alive=1' 'elapsed_s=275 heartbeat stream_alive=1' \
       'elapsed_s=300 collector_end reason=duration_complete' > "$report/stages.txt"
   for name in dmesg-0 ioreg-NMXGPU-0 ioreg-NMXAccel-0; do
       printf 'collector_command_exit=0\n' > "$report/$name.txt"
   done
   cp "$SESSION_FIXTURE/kit/tools/capture/com.uhd770.mvp.capture.plist" "$base/Library/LaunchDaemons/"
   ;;
 export)
   output=$(mktemp -d "$base/Users/Shared/UHD770MVP-reports.XXXXXX")
   cp -R "$base/private/var/log/UHD770MVP" "$output/boot-capture"
   printf 'export\n' >> "$SESSION_FIXTURE/flow-events"
   printf 'Reports exported to: %s\n' "$output"
   ;;
 *) exit 91 ;;
esac
'''


@unittest.skipIf(os.name == "nt", "Native POSIX shell fixture runs in Ubuntu/macOS CI")
class SessionFlowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uhd770-flow-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.mac = self.root / "mac"
        self.kit = self.root / "kit"
        self.installed = self.mac / "Library/Application Support/UHD770MVP"
        self.usb = self.mac / "Volumes/1401/EFI/OC/config.plist"
        self.env = dict(os.environ, SESSION_FIXTURE=str(self.root), SUDO_UID="501", SUDO_GID="20")
        source = pathlib.Path(__file__).parent
        mock = self.root / "mock-bin"
        mock.mkdir()
        dispatcher = mock / "dispatcher"
        dispatcher.write_text(DISPATCHER, encoding="utf-8")
        dispatcher.chmod(0o700)
        for name in ("uname", "sw_vers", "id", "dscl", "sysctl", "stat", "csrutil", "nvram", "ioreg",
                     "diskutil", "plutil", "ditto", "kmutil", "launchctl", "codesign", "sync", "sleep",
                     "chown", "chmod", "PlistBuddy", "sudo", "dmesg"):
            (mock / name).symlink_to(dispatcher)
        shutil.copytree(source, self.kit / "tools", ignore=shutil.ignore_patterns("__pycache__"))
        # Only platform adapters differ in these copies. All literal filesystem
        # destinations, including rollback, are verified below to stay here.
        for name in ("session.sh", "session-user.sh"):
            path = self.kit / "tools" / name
            text = path.read_text(encoding="utf-8")
            text = re.sub(r"(?<![A-Za-z0-9_$])/(Library|private|System|Volumes|Users)(?=/)",
                          lambda match: str(self.mac / match[1]), text)
            text = text.replace("PATH=/usr/bin:/bin:/usr/sbin:/sbin", f"PATH={mock}:/usr/bin:/bin:/usr/sbin:/sbin")
            text = text.replace('"$EUID"', '"501"' if name == "session-user.sh" else '"0"')
            text = text.replace("/usr/libexec/PlistBuddy", str(mock / "PlistBuddy"))
            text = text.replace("/usr/bin/sudo", str(mock / "sudo"))
            self.assertIsNone(re.search(r"[\"'= ]/(Library|private|System|Volumes|Users)/",
                                       text.replace(str(self.root), "$FIXTURE")))
            path.write_text(text, encoding="utf-8")
        (self.kit / "tools/manage.sh").write_text(MANAGER, encoding="utf-8")
        for name in ("Library/Application Support", "Library/Extensions", "Library/LaunchDaemons",
                     "Library/LaunchAgents", "Library/KernelCollections", "private/var/run",
                     "private/var/log/UHD770MVP", "Users/Shared", "Users/fixture",
                     "System/Library/KernelCollections", "Volumes/1401/EFI/OC"):
            (self.mac / name).mkdir(parents=True, exist_ok=True)
        self.guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
        self.safe = plistlib.dumps({"NVRAM": {"Add": {self.guid: {"boot-args": "-v -nvoff"}},
                                             "Delete": {self.guid: ["boot-args"]}}})
        self.usb.write_bytes(self.safe)
        for name, data in prepare_kit.session_payload(self.safe, "1401").items():
            path = self.kit / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        seed = self.root / "seed"
        for prefix in (seed / "components/Library/Extensions", seed / "kc-preflight/repository",
                       self.mac / "Library/Extensions"):
            for name in ("NMXGPU", "NMXAccel"):
                self.kext(prefix / f"{name}.kext", f"com.nullmoth.{name}",
                          b"original" if prefix == self.mac / "Library/Extensions" else b"candidate")
        self.kext(self.mac / "Library/Extensions/Other.kext", "com.fixture.other", b"unrelated")
        for name, data in {
            "components/firmware/i915/test.bin": b"firmware",
            "components/firmware/LICENSES/LICENSE.i915": b"license",
            "components/Library/GPUBundles/nvmtl/runtime": b"runtime",
            "components/Library/GPUBundles/NVMTLDriver.bundle/frontend": b"frontend",
            "components/probe/uhd770-compute-probe": b"cli",
            "components/probe/uhd770-metal-probe": b"cli",
            "stage-state.txt": b"stage=offline-ready\n",
            "probes/run-probe.sh": b'#!/bin/bash\nprintf "%s\\n" "$1" >> "$SESSION_FIXTURE/probe-calls"\n[ "${SESSION_FAIL:-}" != vulkan ]\n',
        }.items():
            path = seed / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (seed / "probes/run-probe.sh").chmod(0o755)
        (self.mac / "Library/KernelCollections/AuxiliaryKernelExtensions.kc").write_bytes(b"original KC")
        (self.mac / "System/Library/KernelCollections/BootKernelExtensions.kc").write_bytes(b"Boot KC")

    @staticmethod
    def kext(path, identifier, binary):
        """Prepare tiny inert bundle data for the actual install/restore operations."""
        (path / "Contents/MacOS").mkdir(parents=True)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": identifier}))
        (path / "Contents/MacOS" / path.stem).write_bytes(binary)

    def run_session(self, mode, **extra):
        """Run the copied entry point with only temporary filesystem destinations."""
        return subprocess.run(["/bin/bash", "-p", str(self.kit / "tools/session.sh"), mode],
                              env=dict(self.env, **extra), capture_output=True, timeout=120)

    def run_user(self, **extra):
        """Run the actual selected-user coordinator after preparation."""
        return subprocess.run(["/bin/bash", "-p", str(self.installed / "session-tools/session-user.sh")],
                              env=dict(self.env, SESSION_BOOT="TEST", **extra),
                              capture_output=True, timeout=120)

    def prepare_test_boot(self):
        """Model only publication/launch timing around the real boot entry points."""
        prepared = self.run_session("prepare")
        self.assertEqual(prepared.returncode, 0, prepared.stderr.decode())
        public = self.installed / "session-public"
        (public / "recovery-TEST.txt").write_text("next_boot_optout=verified\n")
        report = self.mac / "private/var/log/UHD770MVP/session-test"
        report.mkdir()
        (report / "boot-identity.txt").write_text("kern.bootsessionuuid: TEST\n")
        (report / "stages.txt").write_text("elapsed_s=1 heartbeat stream_alive=1\n")
        return public

    def automatic_reports(self):
        """Enumerate final aggregate reports, excluding manage.sh subreports."""
        return list((self.mac / "Users/Shared").glob("UHD770MVP-session-reports.*"))

    def use_zero_deadline(self):
        """Keep production control flow while reducing only its wait budget."""
        path = self.kit / "tools/session.sh"
        text = path.read_text(encoding="utf-8")
        self.assertEqual(text.count("session_wait_terminal 600 "), 1)
        path.write_text(text.replace("session_wait_terminal 600 ", "session_wait_terminal 0 "), encoding="utf-8")

    def test_prepare_and_next_boot_restore_use_actual_flow(self):
        prepared = self.run_session("prepare")
        self.assertEqual(prepared.returncode, 0, prepared.stderr.decode())
        self.assertIn(b"PREPARED", prepared.stdout)
        self.assertEqual(self.usb.read_bytes(), (self.kit / "session-target/config.test.plist").read_bytes())
        # Model the interval after the root boot job verified recovery but
        # before its ten-minute export, when the ordinary login agent runs.
        public = self.installed / "session-public"
        (public / "recovery-TEST.txt").write_text("next_boot_optout=verified\n")
        user = self.run_user()
        self.assertEqual(user.returncode, 0, user.stderr.decode())
        self.assertEqual((self.root / "probe-calls").read_text().splitlines(), ["vulkan", "metal"])
        boot = self.run_session("boot", SESSION_BOOT="TEST")
        self.assertEqual(boot.returncode, 0, boot.stderr.decode())
        self.assertEqual(self.usb.read_bytes(), self.safe)
        self.assertIn("trigger=coordinator-ended", (self.installed / "session-private/export-trigger-TEST.txt").read_text())
        self.assertTrue((public / "exported-TEST.txt").is_file())
        reports = self.automatic_reports()
        self.assertEqual(len(reports), 1)
        exported_stages = reports[0] / "system/boot-capture/session-test/stages.txt"
        self.assertIn("collector_end", exported_stages.read_text())
        self.assertIn("capture_finalization=closed", (self.installed / "session-private/capture-finalization-TEST.txt").read_text())
        self.assertTrue((reports[0] / "preparation/final-dmesg-TEST.txt").is_file())
        self.assertEqual((self.root / "flow-events").read_text().splitlines(), ["capture-stop", "export"])
        # Root and user launchd retries must not repeat an export or GPU work.
        duplicate = self.run_session("boot", SESSION_BOOT="TEST")
        self.assertEqual(duplicate.returncode, 0, duplicate.stderr.decode())
        self.assertEqual(len(self.automatic_reports()), 1)
        self.assertEqual(self.run_user().returncode, 0)
        self.assertEqual((self.root / "probe-calls").read_text().splitlines(), ["vulkan", "metal"])
        restored = self.run_session("restore")
        self.assertEqual(restored.returncode, 0, restored.stderr.decode())
        self.assertEqual((self.mac / "Library/KernelCollections/AuxiliaryKernelExtensions.kc").read_bytes(), b"original KC")

    def test_failed_probe_ends_wait_without_running_metal(self):
        self.prepare_test_boot()
        user = self.run_user(SESSION_FAIL="vulkan")
        self.assertNotEqual(user.returncode, 0)
        terminal = self.mac / "Users/fixture/Library/Logs/UHD770MVP/automatic-TEST/terminal.txt"
        self.assertIn("coordinator_exit=1\n", terminal.read_text())
        self.assertEqual((self.root / "probe-calls").read_text().splitlines(), ["vulkan"])
        boot = self.run_session("boot", SESSION_BOOT="TEST")
        self.assertEqual(boot.returncode, 0, boot.stderr.decode())
        self.assertIn("trigger=coordinator-ended", (self.installed / "session-private/export-trigger-TEST.txt").read_text())
        self.assertEqual(len(self.automatic_reports()), 1)

    def test_initialization_failure_publishes_terminal_without_gpu_submission(self):
        self.prepare_test_boot()
        user = self.run_user(SESSION_FAIL="init")
        self.assertEqual(user.returncode, 66, user.stderr.decode())
        self.assertFalse((self.root / "probe-calls").exists())
        terminal = self.mac / "Users/fixture/Library/Logs/UHD770MVP/automatic-TEST/terminal.txt"
        self.assertIn("coordinator_exit=66\n", terminal.read_text())
        boot = self.run_session("boot", SESSION_BOOT="TEST")
        self.assertEqual(boot.returncode, 0, boot.stderr.decode())
        self.assertIn("trigger=coordinator-ended", (self.installed / "session-private/export-trigger-TEST.txt").read_text())

    def test_missing_terminal_exports_at_deadline(self):
        self.prepare_test_boot()
        self.use_zero_deadline()
        boot = self.run_session("boot", SESSION_BOOT="TEST")
        self.assertEqual(boot.returncode, 0, boot.stderr.decode())
        self.assertIn("trigger=deadline", (self.installed / "session-private/export-trigger-TEST.txt").read_text())
        self.assertEqual(len(self.automatic_reports()), 1)
        self.assertFalse((self.root / "probe-calls").exists())

    def test_capture_stop_failure_still_exports_partial_report(self):
        self.prepare_test_boot()
        self.assertEqual(self.run_user().returncode, 0)
        boot = self.run_session("boot", SESSION_BOOT="TEST", SESSION_FAIL="capture-stop")
        self.assertEqual(boot.returncode, 0, boot.stderr.decode())
        self.assertEqual(len(self.automatic_reports()), 1)
        self.assertEqual((self.root / "flow-events").read_text().splitlines(), ["capture-stop", "export"])
        self.assertIn("capture_finalization=partial", (self.installed / "session-private/capture-finalization-TEST.txt").read_text())

    def test_recovery_failure_exports_once_per_boot(self):
        self.prepare_test_boot()
        for _ in range(2):
            boot = self.run_session("boot", SESSION_BOOT="TEST", SESSION_FAIL="usb-recovery")
            self.assertNotEqual(boot.returncode, 0)
        self.assertEqual(len(self.automatic_reports()), 1)
        self.assertFalse((self.root / "probe-calls").exists())

    def test_failures_before_and_after_live_writes_restore_originals(self):
        for failure in ("kc", "bootstrap"):
            with self.subTest(failure=failure):
                if failure == "bootstrap":
                    # Fresh fixture after the first intentionally failed session.
                    self.temporary.cleanup()
                    self.setUp()
                result = self.run_session("prepare", SESSION_FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.usb.read_bytes(), self.safe)
                self.assertEqual((self.mac / "Library/Extensions/NMXGPU.kext/Contents/MacOS/NMXGPU").read_bytes(), b"original")
                self.assertEqual((self.mac / "Library/KernelCollections/AuxiliaryKernelExtensions.kc").read_bytes(), b"original KC")
                self.assertFalse((self.mac / "private/var/run/com.uhd770.mvp.prepare.lock").exists())
                self.assertIn(b"Report:", result.stdout)


if __name__ == "__main__":
    unittest.main()
