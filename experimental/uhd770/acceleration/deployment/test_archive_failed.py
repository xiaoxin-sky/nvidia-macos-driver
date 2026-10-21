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
 stat)
   if [ -n "${ARCHIVE_BAD_CONTROL:-}" ] && [ "${3##*/}" = "$ARCHIVE_BAD_CONTROL" ]; then
     printf '501 700\n'
   else
     case "$2" in '%u %Lp') printf '0 700\n' ;; %u) printf '0\n' ;; *) printf '700\n' ;; esac
   fi ;;
 sysctl) printf '%s\n' "${ARCHIVE_BOOTARGS:--v -nvoff}" ;;
 ioreg)
   if [ "$3" = IGPU ]; then printf '"device-id" = <80460000>\n"vendor-id" = <86800000>\n';
   elif [ "${ARCHIVE_ATTACHED:-0}" = 1 ]; then printf 'class NMXGPU\n'; fi ;;
 nvram)
   printf '%s\n' "$*" >> "$base/nvram-calls"
   if [ "$*" = '-d nullmoth-gpu-attaching' ]; then
     printf 'delete-guard\n' >> "$base/events"
     [ "${ARCHIVE_DELETE_FAIL:-0}" != 1 ] || exit 5
     [ "${ARCHIVE_DELETE_STUCK:-0}" = 1 ] || rm -f "$base/attach-guard"
     exit 0
   fi
   [ "$*" = nullmoth-gpu-attaching ] || exit 93
   [ "${ARCHIVE_GUARD_QUERY_ERROR:-0}" != 1 ] || { printf 'permission denied\n' >&2; exit 5; }
   if [ -f "$base/attach-guard" ]; then
     printf 'nullmoth-gpu-attaching\t%s\n' "$(cat "$base/attach-guard")"; exit 0
   fi
   printf 'data was not found\n' >&2; exit 1 ;;
 plutil)
   case "$2" in
     Label) printf 'com.uhd770.mvp.capture\n' ;;
     ProgramArguments.0) printf '/bin/bash\n' ;;
     ProgramArguments.1) printf '%s/mac/Library/Application Support/UHD770MVP/capture/collector.sh\n' "$base" ;;
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
   case "${3:-}" in
     */incoming/candidate/uhd770-acceleration-kernel.tar.gz)
       printf '%s  old-kernel\n' "${ARCHIVE_OLD_KERNEL_HASH:-252cd1c4fc9be71416af8a1e452c587cd1af587b33f832ef3ea770b5b5124a67}"; exit 0 ;;
     */candidate/uhd770-acceleration-kernel.tar.gz)
       printf '%s  new-kernel\n' "${ARCHIVE_NEW_KERNEL_HASH:-245f7aed51a89a8ea71bb3df706dc9ddaed40107277a0cbd8e32a80ef079d06a}"; exit 0 ;;
   esac
   [ "${ARCHIVE_BAD_HASH:-0}" != 1 ] && printf '%s  fixture\n' "$ARCHIVE_SAFE" || printf '%064d  fixture\n' 0 ;;
 launchctl)
   printf '%s\n' "$*" >> "$base/launchctl-calls"
   [ "$*" != 'print system' ] || exit 0
   if [ "$*" = 'bootout system/com.uhd770.mvp.capture' ]; then
     printf 'remove-recorder\n' >> "$base/events"
     [ "${ARCHIVE_RECORDER_STUCK:-0}" != 1 ] || exit 5
     rm -f "$base/capture-active"
     exit 0
   fi
   if [ "$*" = 'print system/com.uhd770.mvp.capture' ] && [ -f "$base/capture-active" ]; then
     printf 'program = /bin/bash\narguments = {\n/bin/bash\n%s/mac/Library/Application Support/UHD770MVP/capture/collector.sh\n}\n' "$base"
     exit 0
   fi
   case "$*" in 'print system/'*)
     printf 'Could not find service "%s" in domain for system\n' "${2#system/}" >&2 ;;
   esac
   exit 113 ;;
 ps) printf '\n' ;;
 *) exit 92 ;;
esac
'''


class ArchiveFailedTests(unittest.TestCase):
    TARGETS = {
        "nmxgpu": ("Library/Extensions/NMXGPU.kext", "directory"),
        "nmxaccel": ("Library/Extensions/NMXAccel.kext", "directory"),
        "cachegpu": ("Library/NullMoth/kexts/15/NMXGPU.kext", "directory"),
        "cacheaccel": ("Library/NullMoth/kexts/15/NMXAccel.kext", "directory"),
        "firmware": ("Library/NullMoth/firmware/i915", "directory"),
        "license": ("Library/NullMoth/firmware/LICENSES/LICENSE.i915", "file"),
        "runtime": ("Library/GPUBundles/nvmtl", "directory"),
        "frontend": ("Library/GPUBundles/NVMTLDriver.bundle", "directory"),
        "auxkc": ("Library/KernelCollections/AuxiliaryKernelExtensions.kc", "file"),
        "rootjob": ("Library/LaunchDaemons/com.uhd770.mvp.session.plist", "file"),
        "userjob": ("Library/LaunchAgents/com.uhd770.mvp.session.plist", "file"),
    }

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
        # Darwin temporary roots themselves start with /private. Rewrite only
        # original source tokens once, never rescan a previously inserted root.
        text = re.sub(r"(?<![A-Za-z0-9_$])/(Library|Volumes|private|Users)(?=/|[ \t'\";]|$)",
                      lambda match: self.posix + "/mac/" + match[1], text)
        text = text.replace("PATH=/usr/bin:/bin:/usr/sbin:/sbin",
                            f"PATH={self.posix}/mock-bin:/usr/bin:/bin:/usr/sbin:/sbin")
        text = re.sub(r"\$EUID\b", "0", text)
        self.wrapper = self.root / "Archive-UHD770-Failed.command"
        self.wrapper.write_text(text, encoding="utf-8", newline="\n")
        current_tools = self.root / "tools"
        current_tools.mkdir()
        library = pathlib.Path(__file__).with_name("session-lib.sh").read_text(encoding="utf-8")
        # Only the simulated service's wait budget is compressed; genuine
        # Darwin launchd timing is covered by test_recorder_macos.sh.
        library = library.replace("wait_limit=${5:-20}", "wait_limit=${5:-5}")
        (current_tools / "session-lib.sh").write_text(library, encoding="utf-8", newline="\n")
        self.env = dict(os.environ, ARCHIVE_FIXTURE=self.posix, ARCHIVE_SAFE=self.safe)

    def run_helper(self, *arguments, **changes):
        """Run only the redirected production entry point, with a finite budget."""
        return subprocess.run([self.bash, "-p", self.posix + "/" + self.wrapper.name, *arguments],
                              env=dict(self.env, **changes), capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=90)

    def restored_entry(self, key, original="present"):
        """Create inert old receipts and current targets using the fixed protocol.

        The helper must only inspect these bytes. Replaced candidate evidence
        remains inside the journal, and no fixture invokes restoration code.
        """
        relative, kind = self.TARGETS[key]
        target = self.mac / relative
        if original == "present":
            if kind == "directory":
                target.mkdir(parents=True, exist_ok=True)
                (target / "original-bytes").write_bytes(b"restored original")
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b"restored original")
        for suffix, data in {
            "target": f"{self.posix}/mac/{relative}\n",
            "original": f"{original}\n",
            "restored": "",
            "replaced": "preserved candidate evidence\n",
        }.items():
            (self.journal / f"{key}.{suffix}").write_text(data, encoding="utf-8")
        return target

    def assert_refused_without_archiving(self, result):
        """A rejected receipt must not run export/removal or rename the stage."""
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(self.stage.exists())
        self.assertFalse((self.root / "events").exists())
        self.assertEqual(hashlib.sha256(self.efi.read_bytes()).hexdigest(), self.safe)

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

    def test_incomplete_journal_is_preserved(self):
        (self.journal / "nmxgpu.target").write_text("installation journal", encoding="utf-8")
        result = self.run_helper()
        self.assert_refused_without_archiving(result)
        self.assertIn("journal control", result.stderr)

    def test_fully_restored_seven_target_journal_is_archived_without_live_writes(self):
        live_bytes = {}
        for key in ("nmxgpu", "nmxaccel", "cachegpu", "cacheaccel", "firmware", "license", "runtime"):
            target = self.restored_entry(key, "absent" if key in ("nmxaccel", "cacheaccel") else "present")
            if target.is_file():
                live_bytes[target] = target.read_bytes()
            elif target.is_dir():
                live_bytes[target / "original-bytes"] = (target / "original-bytes").read_bytes()
        journal_bytes = {p.name: p.read_bytes() for p in self.journal.iterdir()}
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("byte equality cannot be verified", result.stdout)
        archive = next(self.stage.parent.glob("UHD770MVP-retired.*"))
        retained = archive / "stage/session-private/journal"
        self.assertEqual({p.name: p.read_bytes() for p in retained.iterdir()}, journal_bytes)
        self.assertEqual({p: p.read_bytes() for p in live_bytes}, live_bytes)
        self.assertFalse((self.mac / self.TARGETS["nmxaccel"][0]).exists())
        self.assertFalse((self.mac / self.TARGETS["cacheaccel"][0]).exists())
        verification = (archive / "retirement-verification.txt").read_text()
        self.assertIn("journal=fully-restored", verification)
        self.assertIn("journal_entries=7", verification)
        self.assertIn("restored_byte_equality=not-verified", verification)

    def test_all_fixed_targets_accept_restored_absence_including_legacy_userjob(self):
        for key in self.TARGETS:
            self.restored_entry(key, "absent")
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("entries=11", result.stdout)

    def test_completed_session_requires_explicit_restore_mode_and_all_receipts(self):
        """A finished r8 is archived only after restore, without failure.txt."""
        for key in self.TARGETS:
            self.restored_entry(key, "absent" if key in ("rootjob", "userjob") else "present")
        (self.private / "failure.txt").unlink()
        state = self.stage / "session-public/state.txt"
        for value in ("armed", "finished"):
            state.write_text(value + "\n")
            self.assert_refused_without_archiving(self.run_helper("--restored-session"))
        state.write_text("restored\n")
        self.assert_refused_without_archiving(self.run_helper())
        originals = {path: path.read_bytes() for path in self.mac.rglob("original-bytes")}
        result = self.run_helper("--restored-session")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        archive = next(self.stage.parent.glob("UHD770MVP-retired.*"))
        self.assertEqual((archive / "stage/session-public/state.txt").read_text(), "restored\n")
        self.assertEqual({path: path.read_bytes() for path in originals}, originals)
        self.assertEqual(self.log.read_text(), "partial original evidence\n")

    def test_restored_state_cannot_hide_partial_or_unrestored_installation(self):
        """A state line alone must not bypass missing target receipts/backups."""
        (self.stage / "session-public/state.txt").write_text("restored\n")
        (self.private / "failure.txt").unlink()
        self.assert_refused_without_archiving(self.run_helper("--restored-session"))
        self.restored_entry("nmxgpu")
        self.assert_refused_without_archiving(self.run_helper("--restored-session"))
        (self.journal / "nmxgpu.backup").write_bytes(b"unresolved original")
        self.assert_refused_without_archiving(self.run_helper("--restored-session"))

    def reviewed_transition(self, marker="1"):
        """Model a restored r9 and exact replacement without touching real NVRAM.

        The command adapter supplies independently pinned digest results; the
        production comparisons and every mutation ordering check remain active.
        Only the completed journal permits reaching the reviewed transition.
        """
        for key in self.TARGETS:
            self.restored_entry(key, "absent" if key in ("rootjob", "userjob") else "present")
        (self.stage / "session-public/state.txt").write_text("restored\n")
        (self.private / "failure.txt").unlink()
        for parent in (self.stage / "incoming/candidate", self.root / "candidate"):
            parent.mkdir(parents=True)
            (parent / "uhd770-acceleration-kernel.tar.gz").write_bytes(b"inert pinned archive")
        (self.root / "tools/session.sh").write_text(
            '#!/bin/bash\nset -eu\n[ "$1" = export ] || exit 91\n'
            'printf "current-export\\n" >> "$ARCHIVE_FIXTURE/events"\n'
            '[ "${ARCHIVE_EXPORT_FAIL:-0}" != 1 ] || exit 5\n', encoding="utf-8")
        if marker is not None:
            (self.root / "attach-guard").write_text(marker)

    def test_reviewed_transition_saves_marker_and_retires_only_after_export_and_stop(self):
        self.reviewed_transition()
        args = ("--restored-session", "--reviewed-fbfix")
        result = self.run_helper(*args)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ARCHIVED", result.stdout)
        self.assertFalse((self.root / "attach-guard").exists())
        self.assertEqual((self.root / "events").read_text(),
                         "export\nremove-recorder\ncurrent-export\ndelete-guard\n")
        self.assertEqual((self.root / "nvram-calls").read_text(),
                         "nullmoth-gpu-attaching\nnullmoth-gpu-attaching\n-d nullmoth-gpu-attaching\nnullmoth-gpu-attaching\n")
        archive = next(self.stage.parent.glob("UHD770MVP-retired.*"))
        receipt = next((archive / "stage/session-private").glob("reviewed-fbfix.*"))
        self.assertEqual((receipt / "guard-before.txt").read_text(), "nullmoth-gpu-attaching\t1\n")
        self.assertIn("guard_retired=verified", (receipt / "result.txt").read_text())
        self.assertEqual(hashlib.sha256(self.efi.read_bytes()).hexdigest(), self.safe)

    def test_reviewed_absent_marker_never_issues_a_delete(self):
        self.reviewed_transition(marker=None)
        result = self.run_helper("--restored-session", "--reviewed-fbfix")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("delete-guard", (self.root / "events").read_text())
        self.assertEqual((self.root / "nvram-calls").read_text(), "nullmoth-gpu-attaching\n")

    def test_marker_is_preserved_without_explicit_reviewed_transition(self):
        self.reviewed_transition()
        result = self.run_helper("--restored-session")
        self.assert_refused_without_archiving(result)
        self.assertEqual((self.root / "attach-guard").read_text(), "1")

    def test_reviewed_transition_refuses_unknown_kernels_hardware_and_guard_queries(self):
        self.reviewed_transition()
        for changes in ({"ARCHIVE_OLD_KERNEL_HASH": "0" * 64},
                        {"ARCHIVE_NEW_KERNEL_HASH": "252cd1c4fc9be71416af8a1e452c587cd1af587b33f832ef3ea770b5b5124a67"},
                        {"ARCHIVE_ATTACHED": "1"}, {"ARCHIVE_BOOTARGS": "-v nmxintel=1"},
                        {"ARCHIVE_BAD_HASH": "1"}, {"ARCHIVE_GUARD_QUERY_ERROR": "1"}):
            with self.subTest(changes=changes):
                result = self.run_helper("--restored-session", "--reviewed-fbfix", **changes)
                self.assert_refused_without_archiving(result)
                self.assertEqual((self.root / "attach-guard").read_text(), "1")
        (self.root / "attach-guard").write_text("unexpected")
        self.assert_refused_without_archiving(self.run_helper("--restored-session", "--reviewed-fbfix"))

    def test_reviewed_transition_needs_all_receipts_before_mutation(self):
        self.reviewed_transition()
        (self.journal / "auxkc.restored").unlink()
        self.assert_refused_without_archiving(self.run_helper("--restored-session", "--reviewed-fbfix"))
        self.assertEqual((self.root / "attach-guard").read_text(), "1")

    def test_reviewed_export_failure_preserves_guard_and_stage(self):
        self.reviewed_transition()
        result = self.run_helper("--restored-session", "--reviewed-fbfix", ARCHIVE_EXPORT_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("export failed", result.stderr)
        self.assertTrue(self.stage.exists())
        self.assertEqual((self.root / "attach-guard").read_text(), "1")
        self.assertNotIn("delete-guard", (self.root / "events").read_text())

    def test_reviewed_recorder_failure_preserves_guard_and_stage(self):
        self.reviewed_transition()
        result = self.run_helper("--restored-session", "--reviewed-fbfix", ARCHIVE_RECORDER_STUCK="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Recorder stop was not verified", result.stderr)
        self.assertTrue(self.stage.exists())
        self.assertEqual((self.root / "attach-guard").read_text(), "1")
        self.assertNotIn("delete-guard", (self.root / "events").read_text())

    def test_reviewed_failed_deletion_or_remaining_marker_never_archives(self):
        self.reviewed_transition()
        for changes in ({"ARCHIVE_DELETE_FAIL": "1"}, {"ARCHIVE_DELETE_STUCK": "1"}):
            with self.subTest(changes=changes):
                result = self.run_helper("--restored-session", "--reviewed-fbfix", **changes)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(self.stage.exists())
                self.assertFalse(list(self.stage.parent.glob("UHD770MVP-retired.*")))
                self.assertEqual((self.root / "attach-guard").read_text(), "1")

    def test_unknown_keys_and_unresolved_backups_are_preserved(self):
        for name in ("foreign.target", "nmxgpu.backup", "runtime.backup-pending", "frontend.replaced-pending", ".hidden"):
            with self.subTest(name=name):
                entry = self.journal / name
                entry.write_bytes(b"unresolved evidence")
                result = self.run_helper()
                self.assert_refused_without_archiving(result)
                self.assertEqual(entry.read_bytes(), b"unresolved evidence")
                entry.unlink()

    def test_missing_receipt_bad_target_and_invalid_original_are_preserved(self):
        self.restored_entry("nmxgpu")
        for suffix, replacement in (("restored", None), ("restored", b"not a receipt"),
                                    ("target", b"/Library/Extensions/Other.kext\n"),
                                    ("original", b"unknown\n")):
            with self.subTest(suffix=suffix, replacement=replacement):
                path = self.journal / f"nmxgpu.{suffix}"
                old = path.read_bytes()
                if replacement is None:
                    path.unlink()
                else:
                    path.write_bytes(replacement)
                result = self.run_helper()
                self.assert_refused_without_archiving(result)
                path.write_bytes(old)

    def test_restored_presence_absence_and_type_are_checked(self):
        target = self.restored_entry("license")
        target.unlink()
        self.assert_refused_without_archiving(self.run_helper())
        target.mkdir()
        self.assert_refused_without_archiving(self.run_helper())
        target.rmdir()
        target.write_bytes(b"original")
        (self.journal / "license.original").write_text("absent\n", encoding="utf-8")
        self.assert_refused_without_archiving(self.run_helper())

    def test_untrusted_control_owner_is_refused(self):
        self.restored_entry("nmxgpu")
        result = self.run_helper(ARCHIVE_BAD_CONTROL="nmxgpu.restored")
        self.assert_refused_without_archiving(result)
        self.assertIn("Unsafe journal control owner/mode", result.stderr)

    @unittest.skipIf(os.name == "nt", "Native symlink/FIFO rejection is verified in POSIX CI")
    def test_linked_control_linked_live_absence_and_fifo_are_rejected(self):
        self.restored_entry("nmxgpu", "absent")
        sentinel = self.stage.parent / "sentinel"
        sentinel.write_bytes(b"outside bytes")
        control = self.journal / "nmxgpu.restored"
        control.unlink()
        control.symlink_to(sentinel)
        self.assert_refused_without_archiving(self.run_helper())
        control.unlink()
        os.mkfifo(control)
        self.assert_refused_without_archiving(self.run_helper())
        control.unlink()
        control.touch()
        target = self.mac / self.TARGETS["nmxgpu"][0]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(self.stage.parent / "missing")
        self.assert_refused_without_archiving(self.run_helper())
        self.assertEqual(sentinel.read_bytes(), b"outside bytes")

    @unittest.skipIf(os.name == "nt", "Native sealed symlinks are preserved in POSIX CI")
    def test_replaced_candidate_tree_preserves_dangling_relative_symlink(self):
        self.restored_entry("frontend", "absent")
        replaced = self.journal / "frontend.replaced"
        replaced.unlink()
        bundle = replaced / "Contents/MacOS"
        bundle.mkdir(parents=True)
        link = bundle / "air-runtime"
        link.symlink_to("../../../nvmtl")
        result = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        archive = next(self.stage.parent.glob("UHD770MVP-retired.*"))
        archived_link = archive / "stage/session-private/journal/frontend.replaced/Contents/MacOS/air-runtime"
        self.assertTrue(archived_link.is_symlink())
        self.assertEqual(os.readlink(archived_link), "../../../nvmtl")

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
        self.assertIn("Recorder stop was not verified", result.stderr)
        self.assertTrue(self.stage.exists())
        self.assertTrue(self.daemon.exists())
        self.assertTrue((self.root / "capture-active").exists())
        self.assertEqual(list(self.stage.parent.glob("UHD770MVP-retired.*")), [])
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
