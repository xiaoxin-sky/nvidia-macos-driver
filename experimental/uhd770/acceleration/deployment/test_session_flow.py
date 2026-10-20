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
    print('501' if args[1] == '%u' and '/Users/fixture/' in args[-1] else
          '0' if args[1] == '%u' else '755')
elif name == 'csrutil': print('Kext Signing: disabled')
elif name == 'nvram':
    print('data was not found', file=sys.stderr); sys.exit(1)
elif name == 'ioreg':
    if 'IGPU' in args: print('"device-id" = <80460000>\n"vendor-id" = <86800000>')
    elif os.environ.get('SESSION_BOOT') == 'TEST':
        print('"nmxdiag-stage" = "attach.complete ret=0"\nclass NMXGPUFB')
elif name == 'diskutil':
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
 export) echo 'fixture manager export' ;;
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
                     "chown", "chmod", "PlistBuddy"):
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

    def test_prepare_and_next_boot_restore_use_actual_flow(self):
        prepared = self.run_session("prepare")
        self.assertEqual(prepared.returncode, 0, prepared.stderr.decode())
        self.assertIn(b"PREPARED", prepared.stdout)
        self.assertEqual(self.usb.read_bytes(), (self.kit / "session-target/config.test.plist").read_bytes())
        # Model the interval after the root boot job verified recovery but
        # before its ten-minute export, when the ordinary login agent runs.
        public = self.installed / "session-public"
        (public / "recovery-TEST.txt").write_text("next_boot_optout=verified\n")
        user = subprocess.run(["/bin/bash", "-p", str(self.installed / "session-tools/session-user.sh")],
                              env=dict(self.env, SESSION_BOOT="TEST"), capture_output=True, timeout=120)
        self.assertEqual(user.returncode, 0, user.stderr.decode())
        self.assertEqual((self.root / "probe-calls").read_text().splitlines(), ["vulkan", "metal"])
        boot = self.run_session("boot", SESSION_BOOT="TEST")
        self.assertEqual(boot.returncode, 0, boot.stderr.decode())
        self.assertEqual(self.usb.read_bytes(), self.safe)
        restored = self.run_session("restore")
        self.assertEqual(restored.returncode, 0, restored.stderr.decode())
        self.assertEqual((self.mac / "Library/KernelCollections/AuxiliaryKernelExtensions.kc").read_bytes(), b"original KC")

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
