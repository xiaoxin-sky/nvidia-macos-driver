"""Run the real bootstrap wrapper against inert children and fake mounted USBs.

Only the wrapper's platform paths, identity and command adapters are redirected
to a temporary tree. No real EFI, mounted volume, driver or GPU is accessed.
"""

import hashlib
import os
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest


DISPATCHER = r'''#!/usr/bin/env python3
import os, pathlib, plistlib, shutil, sys
root = pathlib.Path(os.environ['BOOTSTRAP_FIXTURE'])
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
if name == 'uname':
    print(os.environ.get('BOOTSTRAP_OS', 'Darwin') if args == ['-s'] else 'x86_64')
elif name == 'mktemp':
    requested = pathlib.Path(args[-1])
    if args[0] != '-d' or requested.parent != root / 'mac/Users/Shared' or requested.name != 'UHD770MVP-bootstrap.XXXXXX': sys.exit(91)
    target = requested.with_name('UHD770MVP-bootstrap.FIXTURE')
    target.mkdir(mode=0o700)
    print(target)
elif name == 'plutil':
    data = plistlib.loads(pathlib.Path(args[-1]).read_bytes())
    print(data[args[1]])
elif name == 'ditto':
    source, target = map(pathlib.Path, args)
    if source.parent != root / 'mac/Users/Shared' or not target.is_relative_to(root / 'mac/Volumes'): sys.exit(92)
    shutil.copytree(source, target, dirs_exist_ok=True)
elif name == 'tee':
    if os.environ.get('BOOTSTRAP_TEE_FAIL'):
        data = sys.stdin.buffer.read()
        pathlib.Path(args[0]).write_bytes(data[:16])
        sys.stdout.buffer.write(data)
        sys.exit(29)
    os.execv('/usr/bin/tee', ['/usr/bin/tee', *args])
elif name in ('stat', 'ls'):
    print('fixture diagnostic: root-owned native ancestor; var/run mode=775')
else: sys.exit(93)
'''


@unittest.skipIf(os.name == "nt", "Native wrapper fixture runs in Ubuntu/macOS CI")
class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="uhd770-bootstrap-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()
        self.mac, self.kit = self.root / "mac", self.root / "kit"
        self.shared = self.mac / "Users/Shared"
        self.usb = self.mac / "Volumes/1401"
        self.report = self.shared / "UHD770MVP-bootstrap.FIXTURE"
        self.env = dict(os.environ, BOOTSTRAP_FIXTURE=str(self.root))
        mock = self.root / "mock-bin"
        mock.mkdir()
        dispatcher = mock / "dispatcher"
        dispatcher.write_text(DISPATCHER.replace("#!/usr/bin/env python3", "#!" + sys.executable, 1), encoding="utf-8")
        dispatcher.chmod(0o700)
        for name in ("uname", "mktemp", "plutil", "ditto", "tee", "stat", "ls"):
            (mock / name).symlink_to(dispatcher)
        self.shared.mkdir(parents=True)
        (self.kit / "tools").mkdir(parents=True)
        (self.kit / "session-target").mkdir()
        self.efi = self.usb / "EFI/OC/config.plist"
        self.efi.parent.mkdir(parents=True)
        self.safe = b"unchanged fixture EFI"
        self.efi.write_bytes(self.safe)
        identity = {"safe_hash": hashlib.sha256(self.safe).hexdigest(),
                    "test_hash": hashlib.sha256(b"fixture test EFI").hexdigest()}
        (self.kit / "session-target/identity.plist").write_bytes(plistlib.dumps(identity))
        source = pathlib.Path(__file__).parent / "Start-UHD770.command"
        text = source.read_text(encoding="utf-8")
        text = re.sub(r"(?<![A-Za-z0-9_$])/(Library|private|System|Volumes|Users)(?=/|[ \t'\";]|$)",
                      lambda match: str(self.mac / match[1]), text)
        text = text.replace("PATH=/usr/bin:/bin:/usr/sbin:/sbin", f"PATH={mock}:/usr/bin:/bin:/usr/sbin:/sbin")
        text = re.sub(r"\$EUID\b", "0", text)
        self.assertIsNone(re.search(r"[\"'= ]/(Library|private|System|Volumes|Users)(?:/|[ \t'\";]|$)",
                                   text.replace(str(self.root), "$FIXTURE")))
        self.wrapper = self.kit / "Start-UHD770.command"
        self.wrapper.write_text(text, encoding="utf-8")
        (self.kit / "tools/session.sh").write_text(
            '#!/bin/bash\n[ "$#" -eq 1 ] && [ "$1" = prepare ] || exit 91\n'
            'printf "called\\n" > "$BOOTSTRAP_FIXTURE/child-called"\n'
            'printf "fixture preparation stdout\\n"\n'
            'printf "STOP: inert preparation boundary\\n" >&2\n'
            'exit "${BOOTSTRAP_CHILD_EXIT:-23}"\n', encoding="utf-8")

    def run_wrapper(self, *arguments, **extra):
        """Run the copied foreground wrapper; all destinations remain temporary."""
        return subprocess.run(["/bin/bash", "-p", str(self.wrapper), *arguments],
                              env=dict(self.env, **extra), capture_output=True, timeout=30)

    def test_stop_exit_and_complete_transcript_are_copied_to_unique_usb(self):
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 23, result.stderr.decode())
        transcript = (self.report / "prepare.txt").read_text()
        self.assertIn("bootstrap_utc=", transcript)
        self.assertIn("fixture preparation stdout\n", transcript)
        self.assertIn("STOP: inert preparation boundary\n", transcript)
        completion = (self.report / "bootstrap-result.txt").read_text()
        self.assertEqual(completion, "child_exit=23\ntee_exit=0\nbootstrap_exit=23\n")
        copied = self.usb / "UHD770-prepare-logs" / self.report.name
        self.assertEqual((copied / "prepare.txt").read_bytes(), (self.report / "prepare.txt").read_bytes())
        self.assertEqual((copied / "bootstrap-result.txt").read_text(), completion)
        self.assertEqual(self.report.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.efi.read_bytes(), self.safe)

    def test_successful_child_with_failed_tee_reports_evidence_failure(self):
        result = self.run_wrapper(BOOTSTRAP_CHILD_EXIT="0", BOOTSTRAP_TEE_FAIL="1")
        self.assertEqual(result.returncode, 74, result.stderr.decode())
        self.assertEqual((self.report / "bootstrap-result.txt").read_text(),
                         "child_exit=0\ntee_exit=29\nbootstrap_exit=74\n")
        self.assertEqual(self.efi.read_bytes(), self.safe)

    def test_child_failure_code_is_retained_when_tee_also_fails(self):
        result = self.run_wrapper(BOOTSTRAP_TEE_FAIL="1")
        self.assertEqual(result.returncode, 23, result.stderr.decode())
        self.assertEqual((self.report / "bootstrap-result.txt").read_text(),
                         "child_exit=23\ntee_exit=29\nbootstrap_exit=23\n")

    def test_no_matching_volume_keeps_local_report_without_usb_copy(self):
        self.efi.write_bytes(b"unrelated EFI bytes")
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 23)
        self.assertTrue((self.report / "bootstrap-result.txt").is_file())
        self.assertFalse((self.usb / "UHD770-prepare-logs").exists())
        self.assertEqual(self.efi.read_bytes(), b"unrelated EFI bytes")

    def test_two_matching_volumes_do_not_choose_a_copy_target(self):
        second = self.mac / "Volumes/another-USB/EFI/OC/config.plist"
        second.parent.mkdir(parents=True)
        second.write_bytes(self.safe)
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 23)
        self.assertFalse((self.usb / "UHD770-prepare-logs").exists())
        self.assertFalse((self.mac / "Volumes/another-USB/UHD770-prepare-logs").exists())
        self.assertEqual(second.read_bytes(), self.safe)

    def test_existing_usb_report_is_preserved(self):
        existing = self.usb / "UHD770-prepare-logs" / self.report.name
        existing.mkdir(parents=True)
        sentinel = existing / "preserve.txt"
        sentinel.write_bytes(b"earlier evidence")
        result = self.run_wrapper()
        self.assertEqual(result.returncode, 23)
        self.assertEqual(sorted(path.name for path in existing.iterdir()), ["preserve.txt"])
        self.assertEqual(sentinel.read_bytes(), b"earlier evidence")
        self.assertTrue((self.report / "prepare.txt").is_file())

    def test_help_bad_arguments_and_nonmac_do_not_start_or_write(self):
        for arguments, environment, expected in ((["--help"], {}, 0),
                                                   (["bad-argument"], {}, 64),
                                                   ([], {"BOOTSTRAP_OS": "Linux"}, 64)):
            result = self.run_wrapper(*arguments, **environment)
            self.assertEqual(result.returncode, expected, result.stderr.decode())
            self.assertFalse((self.root / "child-called").exists())
            self.assertEqual(list(self.shared.iterdir()), [])
            self.assertFalse((self.usb / "UHD770-prepare-logs").exists())
            self.assertEqual(self.efi.read_bytes(), self.safe)


if __name__ == "__main__":
    unittest.main()
