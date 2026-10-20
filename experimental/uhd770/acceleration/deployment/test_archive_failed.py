"""Exercise the actual one-time archive helper inside a temporary fake Mac.

Only platform paths, command adapters and the effective identity are redirected.
The production checks, order of operations and same-filesystem rename are run by
Bash. No real EFI, system directory, driver, launchd job or GPU is accessed.
"""

import hashlib
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest


DISPATCHER = r'''#!/bin/bash
set -eu
base="$ARCHIVE_FIXTURE"
name=${0##*/}
case "$name" in
 uname) [ "$1" != -s ] && printf 'x86_64\n' || printf 'Darwin\n' ;;
 sw_vers) printf '15.7.9\n' ;;
 stat) [ "$2" != %u ] && printf '700\n' || printf '0\n' ;;
 sysctl) printf '%s\n' "${ARCHIVE_BOOTARGS:--v -nvoff}" ;;
 ioreg)
   if [ "$3" = IGPU ]; then printf '"device-id" = <80460000>\n"vendor-id" = <86800000>\n';
   elif [ "${ARCHIVE_ATTACHED:-0}" = 1 ]; then printf 'class NMXGPU\n'; fi ;;
 nvram) printf 'data was not found\n' >&2; exit 1 ;;
 plutil)
   case "$2" in
     user_uid) printf '501\n' ;;
     volume_uuid|VolumeUUID) printf 'FIXTURE-UUID\n' ;;
     safe_hash) printf '%s\n' "$ARCHIVE_SAFE" ;;
     volume_label|VolumeName) printf '1401\n' ;;
     BusProtocol) printf 'USB\n' ;;
     MountPoint) printf '%s/mac/Volumes/1401\n' "$base" ;;
     *) exit 91 ;;
   esac ;;
 diskutil) printf 'fixture disk information\n' ;;
 shasum)
   [ "${ARCHIVE_BAD_HASH:-0}" != 1 ] && printf '%s  fixture\n' "$ARCHIVE_SAFE" || printf '%064d  fixture\n' 0 ;;
 launchctl)
   printf '%s\n' "$*" >> "$base/launchctl-calls"
   [ "$*" != 'print system' ] || exit 0
   if [ "$*" = 'print system/com.uhd770.mvp.capture' ] && [ -f "$base/capture-active" ]; then exit 0; fi
   exit 113 ;;
 ps) printf '\n' ;;
 *) exit 92 ;;
esac
'''


class ArchiveFailedTests(unittest.TestCase):
    def setUp(self):
        git_bash = pathlib.Path(os.environ.get("ProgramFiles", "C:/Program Files")) / "Git/bin/bash.exe"
        self.bash = str(git_bash) if os.name == "nt" and git_bash.is_file() else shutil.which("bash")
        if not self.bash:
            self.skipTest("Bash is required for the isolated entry-point fixture")
        self.temporary = tempfile.TemporaryDirectory(prefix="uhd770-archive-")
        self.addCleanup(self.temporary.cleanup)
        self.root = pathlib.Path(self.temporary.name).resolve()
        if os.name == "nt":
            result = subprocess.run([self.bash, "-c", 'cygpath -u "$1"', "_", str(self.root)],
                                    capture_output=True, text=True, encoding="utf-8", check=True)
            self.posix = result.stdout.strip()
        else:
            self.posix = str(self.root)
        self.mac = self.root / "mac"
        self.stage = self.mac / "Library/Application Support/UHD770MVP"
        self.private = self.stage / "session-private"
        self.journal = self.private / "journal"
        self.journal.mkdir(parents=True)
        (self.stage / "session-public").mkdir()
        (self.stage / "incoming/tools").mkdir(parents=True)
        (self.stage / "kc-preflight").mkdir()
        (self.mac / "Library/LaunchDaemons").mkdir()
        (self.mac / "Library/LaunchAgents").mkdir()
        self.log = self.mac / "private/var/log/UHD770MVP/session-old/stages.txt"
        self.log.parent.mkdir(parents=True)
        self.log.write_text("partial original evidence\n", encoding="utf-8")
        self.efi = self.mac / "Volumes/1401/EFI/OC/config.plist"
        self.efi.parent.mkdir(parents=True)
        self.efi.write_bytes(b"unchanged safe opt-out EFI")
        self.safe = hashlib.sha256(self.efi.read_bytes()).hexdigest()
        (self.stage / "stage-state.txt").write_text(
            "stage=offline-ready\ndriver_installed=false\ngpu_executed=false\n", encoding="utf-8")
        (self.stage / "session-public/state.txt").write_text("failed\n", encoding="utf-8")
        (self.stage / "session-public/plan.plist").write_text("fixture plan", encoding="utf-8")
        (self.private / "failure.txt").write_text(
            "prepare_exit=1\noptout_restore_exit=0\nfile_restore_exit=0\n", encoding="utf-8")
        (self.stage / "kc-preflight/result.txt").write_text(
            "temporary_KC_linkage=passed\ninstalled=false\n", encoding="utf-8")
        self.stage.chmod(0o700)
        (self.stage / "stage-state.txt").chmod(0o600)
        (self.root / "capture-active").touch()
        self.daemon = self.mac / "Library/LaunchDaemons/com.uhd770.mvp.capture.plist"
        self.daemon.write_text("fixture registration", encoding="utf-8")
        (self.stage / "incoming/tools/session.sh").write_text(
            '#!/bin/bash\nset -eu\n[ "$1" = export ] || exit 91\n'
            'printf "export\\n" >> "$ARCHIVE_FIXTURE/events"\n'
            'mkdir -p "$ARCHIVE_FIXTURE/mac/Users/Shared/exported"\n'
            'printf "exported evidence\\n" > "$ARCHIVE_FIXTURE/mac/Users/Shared/exported/report"\n',
            encoding="utf-8")
        (self.stage / "incoming/tools/manage.sh").write_text(
            '#!/bin/bash\nset -eu\n[ "$1" = remove-recorder ] || exit 91\n'
            'printf "remove-recorder\\n" >> "$ARCHIVE_FIXTURE/events"\n'
            'if [ "${ARCHIVE_RECORDER_STUCK:-0}" != 1 ]; then rm "$ARCHIVE_FIXTURE/capture-active"; fi\n'
            'rm "$ARCHIVE_FIXTURE/mac/Library/LaunchDaemons/com.uhd770.mvp.capture.plist"\n',
            encoding="utf-8")
        mock = self.root / "mock-bin"
        mock.mkdir()
        for name in ("uname", "sw_vers", "stat", "sysctl", "ioreg", "nvram", "plutil", "diskutil", "shasum", "launchctl", "ps"):
            path = mock / name
            path.write_text(DISPATCHER, encoding="utf-8", newline="\n")
            path.chmod(0o700)
        source = pathlib.Path(__file__).with_name("Archive-UHD770-Failed.command")
        text = source.read_text(encoding="utf-8")
        for name in ("Library", "Volumes", "private"):
            text = text.replace("/" + name, self.posix + "/mac/" + name)
        text = text.replace("PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                            f"PATH={self.posix}/mock-bin:/usr/bin:/bin:/usr/sbin:/sbin")
        text = re.sub(r"\$EUID\b", "0", text)
        self.wrapper = self.root / "Archive-UHD770-Failed.command"
        self.wrapper.write_text(text, encoding="utf-8", newline="\n")
        self.env = dict(os.environ, ARCHIVE_FIXTURE=self.posix, ARCHIVE_SAFE=self.safe)

    def run_helper(self, *arguments, **changes):
        """Run only the redirected production entry point, with a finite budget."""
        return subprocess.run([self.bash, "-p", self.posix + "/" + self.wrapper.name, *arguments],
                              env=dict(self.env, **changes), capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=30)

    def test_archives_stage_after_export_and_recorder_removal(self):
        original_modes = (self.stage.stat().st_mode & 0o777,
                          (self.stage / "stage-state.txt").stat().st_mode & 0o777)
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ARCHIVED:", result.stdout)
        self.assertFalse(self.stage.exists())
        archives = list(self.stage.parent.glob("UHD770MVP-retired.*"))
        self.assertEqual(len(archives), 1)
        self.assertEqual((archives[0] / "stage/session-public/state.txt").read_text(), "failed\n")
        if os.name != "nt":
            self.assertEqual(archives[0].stat().st_mode & 0o777, 0o700)
            self.assertEqual(original_modes, (0o700, 0o600))
            self.assertEqual((archives[0] / "stage").stat().st_mode & 0o777, original_modes[0])
            self.assertEqual((archives[0] / "stage/stage-state.txt").stat().st_mode & 0o777,
                             original_modes[1])
        self.assertEqual((self.root / "events").read_text(), "export\nremove-recorder\n")
        self.assertEqual(self.log.read_text(), "partial original evidence\n")
        self.assertEqual(hashlib.sha256(self.efi.read_bytes()).hexdigest(), self.safe)
        self.assertTrue((self.mac / "Users/Shared/exported/report").is_file())

    def test_nonempty_journal_is_preserved(self):
        (self.journal / "nmxgpu.target").write_text("installation journal", encoding="utf-8")
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("journal is not empty", result.stderr)
        self.assertTrue(self.stage.exists())
        self.assertFalse((self.root / "events").exists())

    def test_nonfailed_state_is_preserved(self):
        (self.stage / "session-public/state.txt").write_text("armed\n", encoding="utf-8")
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Only failed", result.stderr)
        self.assertTrue(self.stage.exists())

    def test_failed_recovery_and_existing_session_job_are_preserved(self):
        failure = self.private / "failure.txt"
        original = failure.read_text()
        failure.write_text(original.replace("file_restore_exit=0", "file_restore_exit=1"), encoding="utf-8")
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("recovery did not report success", result.stderr)
        self.assertFalse((self.root / "events").exists())
        failure.write_text(original, encoding="utf-8")
        (self.mac / "Library/LaunchDaemons/com.uhd770.mvp.session.plist").touch()
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("session job is installed", result.stderr)
        self.assertTrue(self.stage.exists())
        self.assertFalse((self.root / "events").exists())

    def test_test_boot_and_changed_efi_are_refused(self):
        for changes in ({"ARCHIVE_BOOTARGS": "-v nmxintel=1"}, {"ARCHIVE_BAD_HASH": "1"}):
            with self.subTest(changes=changes):
                result = self.run_helper(**changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(self.stage.exists())
                self.assertFalse((self.root / "events").exists())

    def test_recorder_that_remains_registered_prevents_rename(self):
        result = self.run_helper(ARCHIVE_RECORDER_STUCK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("still registered", result.stderr)
        self.assertTrue(self.stage.exists())
        self.assertTrue((self.mac / "Users/Shared/exported/report").is_file())

    def test_existing_lock_is_preserved(self):
        lock = self.stage.parent / ".com.uhd770.mvp.prepare.lock"
        lock.mkdir(mode=0o700)
        sentinel = lock / "preserve"
        sentinel.write_text("other invocation", encoding="utf-8")
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("interrupted lock", result.stderr)
        self.assertEqual(sentinel.read_text(), "other invocation")
        self.assertTrue(self.stage.exists())
        self.assertFalse((self.root / "events").exists())

    @unittest.skipIf(os.name == "nt", "POSIX symlink refusal is checked in native CI")
    def test_linked_stage_file_is_preserved(self):
        target = self.stage.parent / "outside-sentinel"
        target.write_text("outside data", encoding="utf-8")
        path = self.stage / "stage-state.txt"
        path.unlink()
        path.symlink_to(target)
        result = self.run_helper()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing/linked path", result.stderr)
        self.assertTrue(path.is_symlink())
        self.assertEqual(target.read_text(), "outside data")
        self.assertFalse((self.root / "events").exists())

    def test_help_is_inert(self):
        result = self.run_helper("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("Usage:", result.stdout)
        self.assertTrue(self.stage.exists())
        self.assertFalse((self.root / "events").exists())


if __name__ == "__main__":
    unittest.main()
