"""Run the actual Windows recovery code with a temporary fake USB inventory.

Only the fixed DriveInfo inventory expression is substituted in a copied script;
production has no mock switch. Every real filesystem mutation stays in one new
temporary directory. macOS/Linux skip this Windows-specific fixture.
"""

import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest


POWERSHELL = shutil.which("powershell.exe")


@unittest.skipUnless(POWERSHELL, "Windows PowerShell required for recovery fixture")
class WindowsRecoveryTests(unittest.TestCase):
    def test_real_recovery_and_refusal_paths_on_temporary_fake_usb(self):
        source = (pathlib.Path(__file__).parent / "Restore-UHD770.ps1").read_text(encoding="utf-8")
        inventory = "[System.IO.DriveInfo]::GetDrives()"
        self.assertEqual(source.count(inventory), 1)
        safe, test = b"original optout fixture", b"single test fixture"
        with tempfile.TemporaryDirectory(prefix="uhd770-win-recovery-") as temporary:
            root = pathlib.Path(temporary).resolve()
            plan = root / "session-target"
            plan.mkdir()
            (plan / "config.safe.plist").write_bytes(safe)
            (plan / "identity.json").write_text(json.dumps({
                "safe_hash": hashlib.sha256(safe).hexdigest(),
                "test_hash": hashlib.sha256(test).hexdigest(), "volume_label": "1401"}), encoding="utf-8")
            usb = root / "fake-usb"
            target = usb / "EFI" / "OC" / "config.plist"
            target.parent.mkdir(parents=True)
            self.assertTrue(target.resolve().is_relative_to(root))
            literal = str(usb).replace("'", "''")
            fake = ("[PSCustomObject]@{IsReady=$true;DriveFormat='FAT32';VolumeLabel='1401';"
                    f"RootDirectory=[IO.DirectoryInfo]'{literal}'" + "}")

            def run(check_only=False, duplicates=False):
                """Execute the copied production logic with only its drive list replaced."""
                setup = "$taskFixtureDrives = @(" + fake + ("," + fake if duplicates else "") + ")\n"
                script = root / "Restore-UHD770.ps1"
                script.write_text(source.replace(inventory, "$taskFixtureDrives").replace(
                    '$taskMatches = @()', setup + '$taskMatches = @()'), encoding="utf-8-sig")
                command = [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script)]
                if check_only:
                    command.append("-CheckOnly")
                return subprocess.run(command, capture_output=True, timeout=30, check=False)

            target.write_bytes(test)
            checked = run(check_only=True)
            self.assertEqual(checked.returncode, 0, checked.stderr.decode(errors="replace"))
            self.assertEqual(target.read_bytes(), test)
            self.assertEqual(run(duplicates=True).returncode, 1)
            self.assertEqual(target.read_bytes(), test)
            restored = run()
            self.assertEqual(restored.returncode, 0, restored.stderr.decode(errors="replace"))
            self.assertEqual(target.read_bytes(), safe)
            backups = list(target.parent.glob("*.uhd770-before-restore-*"))
            self.assertEqual(len(backups), 1)
            self.assertEqual(backups[0].read_bytes(), test)
            self.assertEqual(run().returncode, 0)
            target.write_bytes(b"independent user change")
            self.assertNotEqual(run().returncode, 0)
            self.assertEqual(target.read_bytes(), b"independent user change")


if __name__ == "__main__":
    unittest.main()
