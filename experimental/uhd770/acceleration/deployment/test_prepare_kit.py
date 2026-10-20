"""Preparation boundary tests; no Mac command, live EFI or GPU is accessed."""

import io
import json
import pathlib
import plistlib
import tarfile
import tempfile
import unittest

import prepare_kit as kit


class PreparationTests(unittest.TestCase):
    def test_recovery_copy_preserves_unrelated_settings_and_source(self):
        guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
        original = {"NVRAM": {"Add": {guid: {"boot-args": "-v nmxintel=1 nmxdiagdelay=90 debug=0x100 -nvoff"}},
                              "Delete": {guid: ["existing"]}},
                    "DeviceProperties": {"Add": {"GPU": {"nullmoth-gpu": b"\x01"}}},
                    "Kernel": {"Add": [{"Enabled": True, "BundlePath": "Lilu.kext"}]}}
        source = plistlib.dumps(original)
        result = plistlib.loads(kit.recovery_copy(source))
        self.assertEqual(result["NVRAM"]["Add"][guid]["boot-args"], "-v debug=0x100 -nvoff")
        self.assertEqual(result["NVRAM"]["Delete"][guid], ["existing", "boot-args"])
        self.assertEqual(result["Kernel"], original["Kernel"])
        self.assertEqual(result["DeviceProperties"], original["DeviceProperties"])
        self.assertEqual(plistlib.loads(source), original)

    def test_invalid_recovery_structure_is_not_invented(self):
        with self.assertRaises(kit.InvalidKit):
            kit.recovery_copy(plistlib.dumps({"NVRAM": {"Add": {}}}))

    def test_portable_paths_reject_escape_alias_and_host_paths(self):
        for path in ("../file", "/etc/file", "C:/file", "a\\b", "a/./b", "a//b", "a\nb"):
            with self.subTest(path=path), self.assertRaises(kit.InvalidKit):
                kit.relative_path(path)

    def test_firmware_uses_real_bytes_and_includes_license(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            spec = {"files": {"i915/test.bin": kit.sha256(b"firmware"),
                              "LICENSES/LICENSE.i915": kit.sha256(b"license")}}
            for name, payload in (("i915/test.bin", b"firmware"), ("LICENSES/LICENSE.i915", b"license")):
                path = root / name
                path.parent.mkdir(exist_ok=True)
                path.write_bytes(payload)
            data = kit.firmware_tar(root, spec)
            with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                self.assertEqual(archive.extractfile("i915/test.bin").read(), b"firmware")
                self.assertEqual(archive.extractfile("LICENSES/LICENSE.i915").read(), b"license")
                self.assertTrue(all(e.mode == 0o644 for e in archive))
            (root / "i915/test.bin").write_bytes(b"corrupt")
            with self.assertRaisesRegex(kit.InvalidKit, "digest mismatch"):
                kit.firmware_tar(root, spec)

    def test_existing_output_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            sentinel = root / "keep.txt"
            sentinel.write_bytes(b"original")
            with self.assertRaisesRegex(kit.InvalidKit, "already exists"):
                kit.prepare(root / "missing", root / "missing", root, root / "missing")
            self.assertEqual(sentinel.read_bytes(), b"original")

    def test_candidate_corruption_and_unlisted_files_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            evidence = {"hardware_ready": False, "gpu_executed": False, "installed": False,
                        "components": {name: {"output_tar": f"uhd770-acceleration-{name}.tar.gz",
                                             "output_tar_sha256": kit.sha256(b"test")}
                                       for name in ("kernel", "userland", "metal")}}
            data = {"evidence.json": json.dumps(evidence).encode()}
            data.update({f"uhd770-acceleration-{name}.tar.gz": b"test" for name in evidence["components"]})
            for name, payload in data.items():
                (root / name).write_bytes(payload)
            (root / "SHA256SUMS").write_text("".join(f"{kit.sha256(v)}  {k}\n" for k, v in data.items()), encoding="utf-8")
            kit.checked_candidate(root)
            (root / "unlisted.txt").write_bytes(b"unexpected")
            with self.assertRaisesRegex(kit.InvalidKit, "unmanifested"):
                kit.checked_candidate(root)
            (root / "evidence.json").write_bytes(b"corrupt")
            with self.assertRaisesRegex(kit.InvalidKit, "checksum mismatch"):
                kit.checked_candidate(root)


if __name__ == "__main__":
    unittest.main()
