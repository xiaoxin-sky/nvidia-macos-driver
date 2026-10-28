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
import sys
import tempfile
import unittest

import prepare_kit


DISPATCHER = r'''#!/usr/bin/env python3
import json, os, pathlib, plistlib, shutil, subprocess, sys
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
    else:
        values = {'kern.bootsessionuuid': boot,
                  'kern.bootargs': '-v -nvoff' if boot == 'BASE' else '-v nmxintel=1 nmxdiagdelay=180'}
        print('\n'.join(key + ': ' + values[key] for key in args))
elif name == 'stat':
    path = pathlib.Path(args[-1])
    if args[1] == '%u':
        print('501' if '/Users/fixture' in str(path) or
              (failure == 'authorization-owner' and path.name.startswith('manual-authorization-')) else '0')
    elif args[1] == '%u %Lp': print('0 ' + ('700' if path.is_dir() else '600'))
    elif args[1] == '%z': print(path.lstat().st_size)
    elif args[1] == '%Lp':
        print(os.environ['SESSION_VAR_RUN_MODE'] if path == root / 'mac/private/var/run' and
              os.environ.get('SESSION_VAR_RUN_MODE') else
              '666' if failure == 'authorization-mode' and path.name.startswith('manual-authorization-') else
              ('700' if path.is_dir() else '600'))
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
    if args[0] == '-extract':
        value = data
        for part in args[1].split('.'):
            value = value[int(part)] if isinstance(value, list) else value[part]
        print(value)
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
        repo = pathlib.Path(args[args.index('--repository')+1])
        installed = repo == root / 'mac/Library/Extensions'
        if failure == 'kc' or (installed and failure == 'installed-kc'): sys.exit(29)
        entries = []
        for bundle in sorted(repo.glob('*.kext')):
            data = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
            entries.append({'id': data['CFBundleIdentifier'], 'path': str(bundle),
                            'payload': (bundle / 'Contents/MacOS' / bundle.stem).read_text()})
        with (root / 'kc-builds.jsonl').open('a') as stream:
            stream.write(json.dumps({'repo': str(repo), 'entries': entries}) + '\n')
        pathlib.Path(args[args.index('-A')+1]).write_text(json.dumps(entries))
    elif args[0] == 'inspect':
        entries = json.loads(pathlib.Path(args[args.index('-A')+1]).read_text())
        for entry in entries:
            installed = entry['path'].startswith(str(root / 'mac/Library/Extensions') + '/')
            if installed and failure == 'installed-kc-omit' and entry['id'] == 'com.fixture.other': continue
            path = entry['path']
            if installed and failure == 'installed-kc-path': path = str(root / 'wrong-repository' / pathlib.Path(path).name)
            print(entry['id'] + '\t1.0\t' + path + '\t')
    elif args[0] == 'showloaded':
        print('fixture loaded UUID TEST-CANDIDATE com.nullmoth.NMXGPU')
    else: sys.exit(98)
elif name == 'launchctl':
    with (root / 'launchctl-calls').open('a') as stream: stream.write(' '.join(args) + '\n')
    registered = root / 'root-job-registered'
    if args == ['print', 'system']: sys.exit(0)
    if args == ['print', 'gui/501']: sys.exit(0)
    if args == ['print', 'gui/501/com.uhd770.mvp.session']:
        print('Could not find service "com.uhd770.mvp.session" in domain for gui/501', file=sys.stderr)
        sys.exit(113)
    if args == ['print', 'system/com.uhd770.mvp.session']:
        if not registered.exists():
            print('Could not find service "com.uhd770.mvp.session" in domain for system', file=sys.stderr)
            sys.exit(113)
        script = root / 'mac/Library/Application Support/UHD770MVP/incoming/tools/session.sh'
        print('program = /bin/bash\narguments = {\n/bin/bash\n-p\n' + str(script) + '\nboot\n}')
        sys.exit(0)
    if args == ['bootout', 'system/com.uhd770.mvp.session']:
        if registered.exists(): registered.unlink()
    if args[0] == 'bootstrap':
        if args[1] != 'system': sys.exit(96)
        registered.write_text('fixture registration')
        if failure == 'bootstrap': sys.exit(28)
        installed = root / 'mac/Library/Application Support/UHD770MVP'
        command = ['/bin/bash', '-p', str(installed / 'incoming/tools/session.sh'), 'boot']
        sys.exit(subprocess.run(command, timeout=60).returncode)
    if args == ['kickstart', '-k', 'system/com.uhd770.mvp.capture']:
        report = root / 'mac/private/var/log/UHD770MVP/session-manual-test'
        report.mkdir(exist_ok=True)
        (report / 'boot-identity.txt').write_text('kern.bootsessionuuid: TEST\n')
        (report / 'stages.txt').write_text('startup_failed\n' if failure == 'capture-startup' else
                                          'elapsed_s=1 heartbeat stream_alive=1\n')
    if args == ['bootout', 'system/com.uhd770.mvp.capture']:
        with (root / 'flow-events').open('a') as stream: stream.write('capture-stop\n')
        if failure == 'capture-stop': sys.exit(26)
        # Close only the newly started manual recorder. An older interrupted
        # boot recorder remains partial evidence and must not taint this close.
        for report in (root / 'mac/private/var/log/UHD770MVP').glob('session-manual-*'):
            if (report / 'boot-identity.txt').read_text() != 'kern.bootsessionuuid: TEST\n': continue
            with (report / 'stages.txt').open('a') as stream:
                stream.write('elapsed_s=7 collector_end reason=deadline_or_termination\n')
elif name == 'sudo':
    if args[:3] != ['-n', '-u', '#501']: sys.exit(94)
    # The fixture owns every temporary file. Only bounded report reads or the
    # exact copied selected-user entry point are allowed; no privilege change.
    selected = str(root / 'mac/Library/Application Support/UHD770MVP/session-tools/session-user.sh')
    read_gate = 'for item do [ -r "$item" ] || exit 64; done; [ -x "$1" ] && [ -x "$2" ]'
    allowed_read_gate = args[3:8] == ['/bin/bash', '-p', '-c', read_gate, '_'] and len(args[8:]) == 7 and \
                        all(pathlib.Path(value).is_relative_to(root) for value in args[8:])
    allowed = args[3:6] == ['/usr/bin/head', '-c', '513'] or \
              (args[3:6] == ['/bin/bash', '-p', selected] and args[6:] in (['preflight'], ['manual'])) or allowed_read_gate
    if not allowed: sys.exit(95)
    with (root / 'sudo-calls').open('a') as stream: stream.write(' '.join(args) + '\n')
    # This is the fixture's process-launch budget, not a GPU/API deadline.
    # Native macOS may legitimately take longer than Linux for many short mocks.
    sys.exit(subprocess.run(args[3:], timeout=30).returncode)
elif name == 'dmesg': print('fixture final kernel snapshot')
elif name == 'ps': print('')
elif name == 'codesign':
    if failure == 'signature': sys.exit(27)
elif name == 'chmod':
    paths = [pathlib.Path(value) for value in args if value.startswith(str(root) + '/')]
    if any('R' in value for value in args if value.startswith('-')):
        if any(path.is_symlink() or (path.is_dir() and any(child.is_symlink() for child in path.rglob('*'))) for path in paths):
            print('fixture refuses recursive chmod over an alias', file=sys.stderr); sys.exit(35)
    if '-N' in args:
        for path in paths:
            if path.is_symlink():
                print('fixture refuses ACL operations on a symlink', file=sys.stderr); sys.exit(36)
            if '/session-private/prepared/' in str(path):
                with (root / 'prepare-events.jsonl').open('a') as stream:
                    stream.write(json.dumps({'kind': 'normalize', 'path': str(path)}) + '\n')
                if failure == 'normalize-late' and path.name == 'rootjob': sys.exit(37)
elif name == 'mv':
    arguments = [pathlib.Path(value) for value in args if not value.startswith('-')]
    if not arguments or any(not path.is_absolute() or not path.is_relative_to(root) for path in arguments): sys.exit(97)
    target = arguments[-1]
    live = root / 'mac/Library'
    if target.is_relative_to(live) and not target.is_relative_to(live / 'Application Support'):
        with (root / 'prepare-events.jsonl').open('a') as stream:
            stream.write(json.dumps({'kind': 'live-replace', 'path': str(target)}) + '\n')
    os.execv('/bin/mv', ['/bin/mv', *args])
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
   (cd "$root/components" && find -P Library/GPUBundles -type f -exec /usr/bin/shasum -a 256 '{}' +) \
       > "$root/incoming/runtime-SHA256SUMS"
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
        # Production deliberately uses a system-only PATH. Keep this test's
        # interpreter rather than accidentally invoking macOS's CLT launcher
        # for every mocked command (hundreds of processes per full flow).
        dispatcher.write_text(DISPATCHER.replace("#!/usr/bin/env python3", "#!" + sys.executable, 1), encoding="utf-8")
        dispatcher.chmod(0o700)
        for name in ("uname", "sw_vers", "id", "dscl", "sysctl", "stat", "csrutil", "nvram", "ioreg",
                     "diskutil", "plutil", "ditto", "kmutil", "launchctl", "codesign", "sync", "sleep",
                     "chown", "chmod", "PlistBuddy", "sudo", "dmesg", "mv", "ps"):
            (mock / name).symlink_to(dispatcher)
        # Pure no-op adapters need no interpreter startup. Retain a short real
        # polling tick so a bounded read can schedule its sibling mock process;
        # actual deadline/process-group behavior has separate real-clock tests.
        for name in ("chown", "sync", "PlistBuddy", "sleep"):
            path = mock / name
            path.unlink()
            path.write_text("#!/bin/sh\n" + ("exec /bin/sleep 0.01\n" if name == "sleep" else "exit 0\n"), encoding="utf-8")
            path.chmod(0o700)
        shutil.copytree(source, self.kit / "tools", ignore=shutil.ignore_patterns("__pycache__"))
        # Preserve the native plist protocol while redirecting its absolute
        # launchd arguments once; the temporary root may itself start /private.
        template = self.kit / "tools/com.uhd770.mvp.session-root.plist"
        job = plistlib.loads(template.read_bytes())
        for key in ("ProgramArguments", "StandardOutPath", "StandardErrorPath"):
            values = job[key] if isinstance(job[key], list) else [job[key]]
            redirected = [re.sub(r"^/(Library|private|System|Volumes|Users)(?=/|$)",
                                 lambda match: str(self.mac / match[1]), value) for value in values]
            job[key] = redirected if isinstance(job[key], list) else redirected[0]
        template.write_bytes(plistlib.dumps(job))
        # Only platform adapters differ in these copies. All literal filesystem
        # destinations, including rollback, are verified below to stay here.
        for name in ("session.sh", "session-user.sh"):
            path = self.kit / "tools" / name
            text = path.read_text(encoding="utf-8")
            text = re.sub(r"(?<![A-Za-z0-9_$])/(Library|private|System|Volumes|Users)(?=/)",
                          lambda match: str(self.mac / match[1]), text)
            text = text.replace("PATH=/usr/bin:/bin:/usr/sbin:/sbin", f"PATH={mock}:/usr/bin:/bin:/usr/sbin:/sbin")
            # Identity interpolation also appears inside authorization lines;
            # adapt every exact builtin reference, not only standalone quotes.
            text = re.sub(r"\$EUID\b", "501" if name == "session-user.sh" else "0", text)
            text = text.replace("/usr/libexec/PlistBuddy", str(mock / "PlistBuddy"))
            text = text.replace("/usr/bin/sudo", str(mock / "sudo"))
            # Delay semantics are exercised by the inert helper fixture. Only
            # the observation durations are compressed in full-flow adapters; a
            # missing anchor would silently make every flow wait the full 180 s.
            if name == "session.sh":
                self.assertEqual(text.count("\nMANUAL_OBSERVE_LIMIT=180\n"), 1)
                text = text.replace("\nMANUAL_OBSERVE_LIMIT=180\n", "\nMANUAL_OBSERVE_LIMIT=2\n")
                self.assertEqual(text.count("\nMANUAL_OBSERVE_SHORT_LIMIT=15\n"), 1)
                text = text.replace("\nMANUAL_OBSERVE_SHORT_LIMIT=15\n", "\nMANUAL_OBSERVE_SHORT_LIMIT=1\n")
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
            "components/Library/GPUBundles/nvmtl/libvulkan.1.dylib": b"inert real library version",
            "components/Library/GPUBundles/nvmtl/libvulkan_intel.dylib": b"inert ANV",
            "components/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib": b"inert translator",
            "components/Library/GPUBundles/nvmtl/air-opt": b"inert AIR reader",
            "components/Library/GPUBundles/nvmtl/NVMTLDriver": b"inert runtime frontend",
            "components/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver": b"frontend",
            "components/probe/uhd770-compute-probe": b"cli",
            "components/probe/uhd770-metal-probe": b"cli",
            "components/probe/render.metallib": b"render shaders",
            "components/probe/suite.metallib": b"suite shaders",
            "stage-state.txt": b"stage=offline-ready\n",
            "probes/run-probe.sh": b'#!/bin/bash\nprintf "%s\\n" "$1" >> "$SESSION_FIXTURE/probe-calls"\n'
                                   b'[ "${SESSION_FAIL:-}" != vulkan-dispatched ] || { printf "dispatch 1: seed=0 words=1\\n"; exit 1; }\n'
                                   b'[ "${SESSION_FAIL:-}" != vulkan ]\n',
        }.items():
            path = seed / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        (seed / "probes/run-probe.sh").chmod(0o755)
        for name in ("uhd770-compute-probe", "uhd770-metal-probe"):
            (seed / "components/probe" / name).chmod(0o755)
        bundles = seed / "components/Library/GPUBundles"
        (bundles / "nvmtl/libvulkan.dylib").symlink_to("libvulkan.1.dylib")
        (bundles / "NVMTLDriver.bundle/Contents/MacOS/air-runtime").symlink_to("../../../nvmtl")
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

    def run_user(self, mode="manual", **extra):
        """Call the copied helper explicitly or simulate a legacy login call."""
        command = ["/bin/bash", "-p", str(self.installed / "session-tools/session-user.sh")]
        if mode is not None:
            command.append(mode)
        environment = dict(self.env, SESSION_BOOT="TEST")
        environment.update(extra)
        return subprocess.run(command, env=environment, capture_output=True, timeout=120)

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

    def preparation_events(self):
        """Read inert normalization/live-rename observations in execution order."""
        source = self.root / "prepare-events.jsonl"
        return [json.loads(line) for line in source.read_text().splitlines()] if source.exists() else []

    def test_all_prepared_permissions_precede_first_live_replacement(self):
        """Model symlink layout and transaction order, not Darwin ACL behavior."""
        prepared = self.run_session("prepare")
        self.assertEqual(prepared.returncode, 0, prepared.stderr.decode())
        events = self.preparation_events()
        first_live = next(index for index, event in enumerate(events) if event["kind"] == "live-replace")
        expected = ["nmxgpu", "nmxaccel", "cachegpu", "cacheaccel", "firmware", "license",
                    "Library/GPUBundles/nvmtl", "Library/GPUBundles/NVMTLDriver.bundle", "auxkc", "rootjob"]
        work = self.installed / "session-private/prepared"
        normalized = {event["path"] for event in events[:first_live] if event["kind"] == "normalize"}
        self.assertTrue({str(work / name) for name in expected} <= normalized)
        # Only the final KC is generated after kext publication. Every other
        # payload still passes all permission checks before any live change.
        late = [event["path"] for event in events[first_live:] if event["kind"] == "normalize"]
        self.assertEqual(late, [str(work / "auxkc-installed")])
        self.assertFalse(any(path.endswith(("/air-runtime", "/libvulkan.dylib")) for path in normalized))
        bundles = self.mac / "Library/GPUBundles"
        air = bundles / "NVMTLDriver.bundle/Contents/MacOS/air-runtime"
        alias = bundles / "nvmtl/libvulkan.dylib"
        self.assertTrue(air.is_symlink())
        self.assertEqual(os.readlink(air), "../../../nvmtl")
        self.assertEqual(air.resolve(strict=True), bundles / "nvmtl")
        self.assertTrue(alias.is_symlink())
        self.assertEqual(os.readlink(alias), "libvulkan.1.dylib")
        self.assertEqual(alias.resolve(strict=True), bundles / "nvmtl/libvulkan.1.dylib")

    def test_final_kc_uses_installed_paths_after_kext_replacement(self):
        """A linkable staging KC must never be published as the boot collection.

        The fake builder retains its inputs so this checks the production order,
        final paths, new kext bytes and preservation of unrelated extensions. It
        does not claim that macOS loaded the resulting collection.
        """
        prepared = self.run_session("prepare")
        self.assertEqual(prepared.returncode, 0, prepared.stderr.decode())
        builds = [json.loads(line) for line in (self.root / "kc-builds.jsonl").read_text().splitlines()]
        self.assertEqual([build["repo"] for build in builds], [
            str(self.installed / "session-private/repository"), str(self.mac / "Library/Extensions")])
        live = json.loads((self.mac / "Library/KernelCollections/AuxiliaryKernelExtensions.kc").read_text())
        self.assertEqual(live, builds[-1]["entries"])
        self.assertEqual({entry["id"]: entry["payload"] for entry in live}, {
            "com.nullmoth.NMXGPU": "candidate", "com.nullmoth.NMXAccel": "candidate", "com.fixture.other": "unrelated"})
        self.assertTrue(all(pathlib.Path(entry["path"]).parent == self.mac / "Library/Extensions" for entry in live))
        self.assertEqual((self.installed / "session-private/journal/auxkc.backup").read_bytes(), b"original KC")

    def test_late_permission_failure_occurs_before_any_live_replacement(self):
        """A last-target normalization error must leave originals unjournaled."""
        prepared = self.run_session("prepare", SESSION_FAIL="normalize-late")
        self.assertNotEqual(prepared.returncode, 0)
        events = self.preparation_events()
        self.assertTrue(any(event["kind"] == "normalize" and event["path"].endswith("/rootjob") for event in events))
        self.assertFalse(any(event["kind"] == "live-replace" for event in events))
        self.assertEqual(list((self.installed / "session-private/journal").iterdir()), [])
        self.assertEqual((self.mac / "Library/Extensions/NMXGPU.kext/Contents/MacOS/NMXGPU").read_bytes(), b"original")
        self.assertEqual((self.mac / "Library/Extensions/NMXAccel.kext/Contents/MacOS/NMXAccel").read_bytes(), b"original")
        self.assertEqual((self.mac / "Library/KernelCollections/AuxiliaryKernelExtensions.kc").read_bytes(), b"original KC")
        # Parent validation may create the empty installation directory before
        # normalization; neither candidate payload may be published there.
        self.assertFalse((self.mac / "Library/GPUBundles/nvmtl").exists())
        self.assertFalse((self.mac / "Library/GPUBundles/NVMTLDriver.bundle").exists())
        self.assertEqual(self.usb.read_bytes(), self.safe)

    def test_refused_existing_stage_cannot_roll_back_an_older_plan(self):
        """The failing invocation owns its lock, never the earlier transaction."""
        prepared = self.run_session("prepare")
        self.assertEqual(prepared.returncode, 0, prepared.stderr.decode())
        (self.kit / "SHA256SUMS").write_bytes(b"new mismatched package\n")
        (self.installed / "incoming/SHA256SUMS").write_bytes(b"old staged package\n")

        def snapshot():
            result = {}
            for path in self.installed.rglob("*"):
                if path.is_symlink():
                    value = ("link", os.readlink(path))
                elif path.is_file():
                    value = ("file", path.read_bytes())
                else:
                    value = ("directory",)
                result[path.relative_to(self.installed).as_posix()] = value
            return result

        original = snapshot()
        armed_usb = self.usb.read_bytes()
        event_count = len(self.preparation_events())
        refused = self.run_session("prepare")
        self.assertNotEqual(refused.returncode, 0)
        self.assertEqual(snapshot(), original)
        self.assertEqual(self.usb.read_bytes(), armed_usb)
        self.assertEqual(len(self.preparation_events()), event_count)
        self.assertEqual((self.mac / "Library/Extensions/NMXGPU.kext/Contents/MacOS/NMXGPU").read_bytes(), b"candidate")

    def test_export_preserves_early_root_bootstrap_without_prepared_plan(self):
        """Retrieve a complete STOP transcript even before staging created PLAN."""
        bootstrap = self.mac / "Users/Shared/UHD770MVP-bootstrap.sample"
        bootstrap.mkdir(mode=0o700)
        transcript = (b"STOP: Unsafe owner/mode: /private/var/run\n" +
                      b"early ancestor diagnostic\n" * 400 + b"final child_exit=23\n")
        (bootstrap / "prepare.txt").write_bytes(transcript)
        reviewed = self.installed / "session-private/reviewed-fbfix.example"
        reviewed.mkdir(parents=True, mode=0o700)
        guard_snapshot = b"nullmoth-gpu-attaching\t1\n"
        (reviewed / "guard-before.txt").write_bytes(guard_snapshot)
        self.assertFalse((self.installed / "session-public/plan.plist").exists())
        exported = self.run_session("export")
        self.assertEqual(exported.returncode, 0, exported.stderr.decode())
        reports = self.automatic_reports()
        self.assertEqual(len(reports), 1)
        saved = reports[0] / "bootstrap/UHD770MVP-bootstrap.sample/prepare.txt"
        self.assertEqual(saved.read_bytes(), transcript)
        self.assertEqual((bootstrap / "prepare.txt").read_bytes(), transcript)
        self.assertEqual((reports[0] / "recorder-stop/reviewed-fbfix.example/guard-before.txt").read_bytes(),
                         guard_snapshot)
        self.assertFalse((self.installed / "session-public/plan.plist").exists())
        self.assertEqual(self.usb.read_bytes(), self.safe)
        self.assertFalse((self.root / "probe-calls").exists())

    def test_native_group_writable_var_run_is_not_a_preparation_lock_parent(self):
        """Keep Darwin's native /private/var/run ownership and mode untouched.

        A directory timestamp also detects a temporary lock that was created
        and removed, which a final file listing alone would fail to reveal.
        """
        native_run = self.mac / "private/var/run"
        native_run.chmod(0o775)
        sentinel = native_run / "existing-system-marker"
        sentinel.write_bytes(b"preserve unrelated system data")

        def snapshot():
            result = {}
            for path in (native_run, *native_run.rglob("*")):
                info = path.lstat()
                result[path.relative_to(native_run).as_posix()] = (
                    info.st_mode, info.st_mtime_ns, info.st_ctime_ns,
                    path.read_bytes() if path.is_file() else None)
            return result

        before = snapshot()
        prepared = self.run_session("prepare", SESSION_VAR_RUN_MODE="775")
        self.assertEqual(prepared.returncode, 0, prepared.stderr.decode())
        self.assertIn(b"PREPARED", prepared.stdout)
        self.assertEqual(snapshot(), before)
        self.assertFalse((self.mac / "Library/Application Support/.com.uhd770.mvp.prepare.lock").exists())
        self.assertFalse((self.root / "probe-calls").exists())
        self.assertEqual(self.usb.read_bytes(), (self.kit / "session-target/config.test.plist").read_bytes())

    def test_prepare_and_next_boot_restore_use_actual_flow(self):
        prepared = self.run_session("prepare")
        self.assertEqual(prepared.returncode, 0, prepared.stderr.decode())
        self.assertIn(b"PREPARED", prepared.stdout)
        self.assertEqual(self.usb.read_bytes(), (self.kit / "session-target/config.test.plist").read_bytes())
        self.assertFalse((self.root / "probe-calls").exists())
        self.assertFalse((self.mac / "Library/LaunchAgents/com.uhd770.mvp.session.plist").exists())
        self.assertNotIn("gui/", (self.root / "launchctl-calls").read_text())
        # Boot recovery restores opt-out without authorizing GPU work. Only the
        # separately invoked manual command may run the ordinary-user probes.
        public = self.installed / "session-public"
        boot = self.run_session("boot", SESSION_BOOT="TEST")
        self.assertEqual(boot.returncode, 0, boot.stderr.decode())
        self.assertEqual(self.usb.read_bytes(), self.safe)
        self.assertFalse((self.root / "probe-calls").exists())
        self.assertFalse((self.installed / "session-private/export-trigger-TEST.txt").exists())
        self.assertFalse((public / "deadline-TEST.txt").exists())
        self.assertEqual(self.automatic_reports(), [])
        manual = self.run_session("test", SESSION_BOOT="TEST")
        self.assertEqual(manual.returncode, 0, manual.stderr.decode())
        self.assertEqual((self.root / "probe-calls").read_text().splitlines(),
                         ["vulkan", "metal", "metal-render", "metal-suite"])
        reports = self.automatic_reports()
        self.assertEqual(len(reports), 1)
        exported_stages = reports[0] / "system/boot-capture/session-manual-test/stages.txt"
        self.assertIn("collector_end", exported_stages.read_text())
        self.assertIn("capture_finalization=closed", (self.installed / "session-private/capture-finalization-TEST.txt").read_text())
        self.assertTrue((reports[0] / "preparation/final-dmesg-TEST.txt").is_file())
        observation = (reports[0] / "preparation/post-test-observation-TEST.txt").read_text()
        self.assertIn("compute=stopped", observation)
        self.assertIn("observation_elapsed_s=2", observation)
        for when in ("before", "after"):
            loaded = reports[0] / f"preparation/manual-loaded-{when}-TEST.txt"
            self.assertIn("TEST-CANDIDATE com.nullmoth.NMXGPU", loaded.read_text())
        self.assertEqual((self.root / "flow-events").read_text().splitlines(), ["capture-stop", "export"])
        # Repeated boot recovery and a repeated manual command must not submit
        # another compute sequence on the same test boot.
        duplicate = self.run_session("boot", SESSION_BOOT="TEST")
        self.assertEqual(duplicate.returncode, 0, duplicate.stderr.decode())
        self.assertEqual(len(self.automatic_reports()), 1)
        self.run_session("test", SESSION_BOOT="TEST")
        self.assertEqual((self.root / "probe-calls").read_text().splitlines(),
                         ["vulkan", "metal", "metal-render", "metal-suite"])
        restored = self.run_session("restore")
        self.assertEqual(restored.returncode, 0, restored.stderr.decode())
        self.assertEqual((self.mac / "Library/KernelCollections/AuxiliaryKernelExtensions.kc").read_bytes(), b"original KC")

    def test_failed_probe_ends_wait_without_running_metal(self):
        self.prepare_test_boot()
        manual = self.run_session("test", SESSION_BOOT="TEST", SESSION_FAIL="vulkan")
        self.assertNotEqual(manual.returncode, 0)
        terminal = self.mac / "Users/fixture/Library/Logs/UHD770MVP/manual-TEST/terminal.txt"
        self.assertIn("coordinator_exit=1\n", terminal.read_text())
        self.assertEqual((self.root / "probe-calls").read_text().splitlines(), ["vulkan"])
        reports = self.automatic_reports()
        self.assertEqual(len(reports), 1)
        # Nothing was submitted, so the observation is the short one.
        observation = (reports[0] / "preparation/post-test-observation-TEST.txt").read_text()
        self.assertIn("observation_limit_s=1\n", observation)

    def test_failure_after_dispatch_keeps_the_full_observation(self):
        self.prepare_test_boot()
        manual = self.run_session("test", SESSION_BOOT="TEST", SESSION_FAIL="vulkan-dispatched")
        self.assertNotEqual(manual.returncode, 0)
        self.assertEqual((self.root / "probe-calls").read_text().splitlines(), ["vulkan"])
        reports = self.automatic_reports()
        self.assertEqual(len(reports), 1)
        observation = (reports[0] / "preparation/post-test-observation-TEST.txt").read_text()
        self.assertIn("observation_limit_s=2\n", observation)

    def test_initialization_failure_publishes_terminal_without_gpu_submission(self):
        self.prepare_test_boot()
        manual = self.run_session("test", SESSION_BOOT="TEST", SESSION_FAIL="init")
        self.assertEqual(manual.returncode, 66, manual.stderr.decode())
        self.assertFalse((self.root / "probe-calls").exists())
        terminal = self.mac / "Users/fixture/Library/Logs/UHD770MVP/manual-TEST/terminal.txt"
        self.assertIn("coordinator_exit=66\n", terminal.read_text())
        self.assertEqual(len(self.automatic_reports()), 1)

    def test_manual_recorder_failure_exports_same_boot_context_without_compute(self):
        """Keep failure evidence before the selected-user coordinator starts."""
        self.prepare_test_boot()
        result = self.run_session("test", SESSION_BOOT="TEST", SESSION_FAIL="capture-startup")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"The new recorder did not confirm startup", result.stderr)
        self.assertFalse((self.root / "probe-calls").exists())
        reports = self.automatic_reports()
        self.assertEqual(len(reports), 1)
        self.assertIn("mode=test", (reports[0] / "export-context.txt").read_text())
        self.assertIn("kern.bootsessionuuid: TEST", (reports[0] / "boot-identity.txt").read_text())
        self.assertIn("com.nullmoth.NMXGPU", (reports[0] / "loaded-kexts.txt").read_text())

    def test_boot_and_legacy_login_never_start_gpu_or_probe_deadline(self):
        self.prepare_test_boot()
        for _ in range(2):
            boot = self.run_session("boot", SESSION_BOOT="TEST")
            self.assertEqual(boot.returncode, 0, boot.stderr.decode())
            login = self.run_user(mode=None)
            self.assertFalse((self.root / "probe-calls").exists(), login.stderr.decode())
        self.assertEqual(self.automatic_reports(), [])
        self.assertFalse((self.installed / "session-public/deadline-TEST.txt").exists())
        self.assertFalse((self.installed / "session-private/export-trigger-TEST.txt").exists())
        self.assertFalse((self.mac / "Users/fixture/Library/Logs/UHD770MVP/manual-TEST").exists())

    def test_explicit_preflight_never_starts_gpu_on_either_boot(self):
        self.prepare_test_boot()
        checked = self.run_user(mode="preflight", SESSION_BOOT="BASE")
        self.assertEqual(checked.returncode, 0, checked.stderr.decode())
        checked = self.run_user(mode="preflight", SESSION_BOOT="TEST")
        self.assertNotEqual(checked.returncode, 0)
        self.assertFalse((self.root / "probe-calls").exists())
        self.assertFalse((self.mac / "Users/fixture/Library/Logs/UHD770MVP/manual-TEST").exists())

    def test_manual_mode_on_preparation_boot_refuses_gpu(self):
        self.prepare_test_boot()
        checked = self.run_session("test", SESSION_BOOT="BASE")
        self.assertNotEqual(checked.returncode, 0)
        self.assertFalse((self.root / "probe-calls").exists())

    def test_unverified_recovery_never_allows_explicit_manual_gpu(self):
        public = self.prepare_test_boot()
        (public / "recovery-TEST.txt").write_text("next_boot_optout=NOT_VERIFIED\n")
        (public / "manual-authorization-TEST.txt").write_text(
            "manual_authorization=active\nboot=TEST\nuid=501\n")
        user = self.run_user()
        self.assertEqual(user.returncode, 65, user.stderr.decode())
        self.assertFalse((self.root / "probe-calls").exists())

    def test_direct_user_helper_requires_current_active_root_authorization(self):
        public = self.prepare_test_boot()
        authorization = public / "manual-authorization-TEST.txt"
        # Missing, stale, closed or other-user markers cannot bypass fresh
        # capture startup by invoking the internal helper directly.
        cases = (None, "manual_authorization=closed\nboot=TEST\nuid=501\n",
                 "manual_authorization=active\nboot=OLD\nuid=501\n",
                 "manual_authorization=active\nboot=TEST\nuid=502\n")
        for data in cases:
            if data is not None:
                authorization.write_text(data)
            user = self.run_user()
            self.assertEqual(user.returncode, 64, user.stderr.decode())
            self.assertFalse((self.root / "probe-calls").exists())
            self.assertFalse((self.mac / "Users/fixture/Library/Logs/UHD770MVP/manual-TEST").exists())
        authorization.write_text("manual_authorization=active\nboot=TEST\nuid=501\n")
        for failure in ("authorization-owner", "authorization-mode"):
            user = self.run_user(SESSION_FAIL=failure)
            self.assertEqual(user.returncode, 64, user.stderr.decode())
            self.assertFalse((self.root / "probe-calls").exists())
        linked = public / "saved-authorization.txt"
        authorization.rename(linked)
        authorization.symlink_to(linked)
        user = self.run_user()
        self.assertEqual(user.returncode, 64, user.stderr.decode())
        self.assertFalse((self.root / "probe-calls").exists())

    def test_only_explicit_manual_command_owns_the_compute_deadline(self):
        self.prepare_test_boot()
        path = self.kit / "tools/session.sh"
        text = path.read_text(encoding="utf-8")
        marker = 'session_bounded_group "$MANUAL_COORDINATOR_LIMIT" "$PRIVATE/manual-coordinator-$current.txt"'
        self.assertEqual(text.count(marker), 1)
        self.assertEqual(text.count("\nMANUAL_COORDINATOR_LIMIT=600\n"), 1)
        # Shrink only the explicit manual watchdog. Boot recovery must not
        # consume it, publish its failure marker or initiate the coordinator.
        path.write_text(text.replace("\nMANUAL_COORDINATOR_LIMIT=600\n", "\nMANUAL_COORDINATOR_LIMIT=0\n"),
                        encoding="utf-8")
        boot = self.run_session("boot", SESSION_BOOT="TEST")
        self.assertEqual(boot.returncode, 0, boot.stderr.decode())
        deadline = self.installed / "session-public/deadline-TEST.txt"
        self.assertFalse(deadline.exists())
        self.assertFalse((self.root / "probe-calls").exists())
        manual = self.run_session("test", SESSION_BOOT="TEST")
        self.assertEqual(manual.returncode, 124, manual.stderr.decode())
        self.assertIn("trigger=manual-timeout", deadline.read_text())
        self.assertEqual(len(self.automatic_reports()), 1)
        self.assertFalse((self.root / "probe-calls").exists())

    def test_capture_stop_failure_still_exports_partial_report(self):
        self.prepare_test_boot()
        manual = self.run_session("test", SESSION_BOOT="TEST", SESSION_FAIL="capture-stop")
        self.assertEqual(manual.returncode, 0, manual.stderr.decode())
        self.assertEqual(len(self.automatic_reports()), 1)
        self.assertEqual((self.root / "flow-events").read_text().splitlines(), ["capture-stop", "export"])
        self.assertIn("capture_finalization=partial", (self.installed / "session-private/capture-finalization-TEST.txt").read_text())

    def test_fresh_capture_closes_even_when_old_boot_capture_was_interrupted(self):
        self.prepare_test_boot()
        old_stages = self.mac / "private/var/log/UHD770MVP/session-test/stages.txt"
        self.assertNotIn("collector_end", old_stages.read_text())
        manual = self.run_session("test", SESSION_BOOT="TEST")
        self.assertEqual(manual.returncode, 0, manual.stderr.decode())
        self.assertNotIn("collector_end", old_stages.read_text())
        self.assertIn("capture_finalization=closed",
                      (self.installed / "session-private/capture-finalization-TEST.txt").read_text())
        self.assertIn("manual_authorization=closed",
                      (self.installed / "session-public/manual-authorization-TEST.txt").read_text())

    def test_recovery_failure_exports_once_per_boot(self):
        self.prepare_test_boot()
        for _ in range(2):
            boot = self.run_session("boot", SESSION_BOOT="TEST", SESSION_FAIL="usb-recovery")
            self.assertNotEqual(boot.returncode, 0)
        self.assertEqual(len(self.automatic_reports()), 1)
        self.assertFalse((self.root / "probe-calls").exists())

    def test_manual_entrypoint_refuses_failed_recovery_before_gpu(self):
        self.prepare_test_boot()
        manual = self.run_session("test", SESSION_BOOT="TEST", SESSION_FAIL="usb-recovery")
        self.assertNotEqual(manual.returncode, 0)
        self.assertFalse((self.root / "probe-calls").exists())

    def test_failures_before_and_after_live_writes_restore_originals(self):
        for failure in ("kc", "installed-kc", "installed-kc-path", "installed-kc-omit", "bootstrap"):
            with self.subTest(failure=failure):
                if failure != "kc":
                    # Fresh fixture after the first intentionally failed session.
                    self.temporary.cleanup()
                    self.setUp()
                result = self.run_session("prepare", SESSION_FAIL=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.usb.read_bytes(), self.safe)
                self.assertEqual((self.mac / "Library/Extensions/NMXGPU.kext/Contents/MacOS/NMXGPU").read_bytes(), b"original")
                self.assertEqual((self.mac / "Library/KernelCollections/AuxiliaryKernelExtensions.kc").read_bytes(), b"original KC")
                self.assertFalse((self.mac / "private/var/run/com.uhd770.mvp.prepare.lock").exists())
                self.assertFalse((self.mac / "Library/Application Support/.com.uhd770.mvp.prepare.lock").exists())
                self.assertIn(b"Report:", result.stdout)


if __name__ == "__main__":
    unittest.main()
