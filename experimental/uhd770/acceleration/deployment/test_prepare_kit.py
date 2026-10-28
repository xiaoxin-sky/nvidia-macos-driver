"""Preparation boundary tests; no Mac command, live EFI or GPU is accessed."""

import io
import json
import pathlib
import plistlib
import shutil
import tarfile
import tempfile
import unittest

import prepare_kit as kit


class PreparationTests(unittest.TestCase):
    @staticmethod
    def candidate_fixture(root):
        """Write inert three-component archives accepted by the real kit validator.

        Payload names model the compiled package contract, while their contents
        remain plain fixture data and are never executed or installed.
        """
        members = {
            "kernel": {
                "Library/Extensions/NMXGPU.kext/Contents/MacOS/NMXGPU": b"inert-kext",
                "Library/Extensions/NMXGPU.kext/Contents/Info.plist": b"inert-info",
            },
            "userland": {
                "probe/uhd770-compute-probe": b"inert-vulkan",
                "Library/GPUBundles/nvmtl/libvulkan_intel.dylib": b"inert-anv",
            },
            "metal": {
                "probe/uhd770-metal-probe": b"inert-metal",
                "Library/GPUBundles/nvmtl/air-opt": b"inert-reader",
                "Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver": b"inert-frontend",
                "Library/Extensions/NMXAccel.kext/Contents/MacOS/NMXAccel": b"inert-accel",
                "Library/GPUBundles/nvmtl": None,
            },
        }
        files, components = {}, {}
        for component, content in members.items():
            buffer = io.BytesIO()
            with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
                for name, data in content.items():
                    entry = tarfile.TarInfo(name)
                    entry.mode = 0o755
                    if data is None:
                        entry.type = tarfile.DIRTYPE
                    else:
                        entry.size = len(data)
                    archive.addfile(entry, io.BytesIO(data) if data is not None else None)
                if component == "metal":
                    entry = tarfile.TarInfo("Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime")
                    entry.type, entry.linkname = tarfile.SYMTYPE, "../../../nvmtl"
                    archive.addfile(entry)
            name = f"uhd770-acceleration-{component}.tar.gz"
            files[name] = buffer.getvalue()
            components[component] = {
                "output_tar": name,
                "output_tar_sha256": kit.sha256(files[name]),
                "run_url": f"https://example.invalid/{component}",
                "source_commit": "0" * 40,
            }
        files["evidence.json"] = json.dumps({"hardware_ready": False, "gpu_executed": False,
                                               "installed": False, "components": components}).encode()
        root.mkdir()
        for name, data in files.items():
            (root / name).write_bytes(data)
        (root / "SHA256SUMS").write_text(
            "".join(f"{kit.sha256(data)}  {name}\n" for name, data in files.items()), encoding="utf-8")

    def test_session_package_has_explicit_manual_entrypoint_and_no_login_agent(self):
        """Exercise real package assembly without touching a host config or GPU."""
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            source = root / "acceleration/deployment"
            original = pathlib.Path(__file__).resolve().parent
            shutil.copytree(original, source, ignore=shutil.ignore_patterns("__pycache__"))
            shutil.copytree(original.parent / "kit", source.parent / "kit",
                            ignore=shutil.ignore_patterns("__pycache__"))
            firmware = root / "firmware"
            for name, data in (("i915/test.bin", b"firmware"), ("LICENSES/LICENSE.i915", b"license")):
                path = firmware / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            (source / "firmware.json").write_text(json.dumps({"files": {
                "i915/test.bin": kit.sha256(b"firmware"),
                "LICENSES/LICENSE.i915": kit.sha256(b"license")}}), encoding="utf-8")
            self.candidate_fixture(root / "candidate")
            safe = root / "safe.plist"
            guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
            safe.write_bytes(plistlib.dumps({"NVRAM": {"Add": {guid: {"boot-args": "-v -nvoff"}},
                                                         "Delete": {guid: ["boot-args"]}}}))
            output = root / "output"
            plan = kit.prepare(root / "candidate", firmware, output, source, session_config=safe)
            self.assertFalse(plan["gpu_executed"])
            self.assertEqual((output / "Run-UHD770-Test.command").read_bytes(),
                             (source / "Run-UHD770-Test.command").read_bytes())
            self.assertEqual((output / "Archive-UHD770-Failed.command").read_bytes(),
                             (source / "Archive-UHD770-Failed.command").read_bytes())
            self.assertFalse((output / "tools/com.uhd770.mvp.session-user.plist").exists())
            self.assertTrue((output / "tools/com.uhd770.mvp.session-root.plist").is_file())
            manifest = (output / "SHA256SUMS").read_text(encoding="utf-8")
            self.assertIn("  Run-UHD770-Test.command\n", manifest)
            self.assertIn("  Archive-UHD770-Failed.command\n", manifest)
            self.assertNotIn("com.uhd770.mvp.session-user.plist", manifest)

    def test_single_session_config_preserves_safe_bytes_and_unrelated_settings(self):
        guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
        original = {"NVRAM": {"Add": {guid: {"boot-args": "-v -igfxvesa amfi=0x80 -nvoff"}},
                              "Delete": {guid: ["boot-args"]}},
                    "DeviceProperties": {"Add": {"GPU": {"device-id": b"\x80\x46\x00\x00"}}},
                    "Kernel": {"Add": [{"Enabled": True, "BundlePath": "Lilu.kext"}]}}
        raw = plistlib.dumps(original, fmt=plistlib.FMT_BINARY)
        payload = kit.session_payload(raw, "1401")
        self.assertEqual(payload["session-target/config.safe.plist"], raw)
        test = plistlib.loads(payload["session-target/config.test.plist"])
        self.assertEqual(test["DeviceProperties"], original["DeviceProperties"])
        self.assertEqual(test["Kernel"], original["Kernel"])
        self.assertEqual(test["NVRAM"]["Delete"], original["NVRAM"]["Delete"])
        self.assertEqual(test["NVRAM"]["Add"][guid]["boot-args"],
                         "-v -igfxvesa amfi=0x80 nmxintel=1 nmxdiagdelay=60")
        identity = json.loads(payload["session-target/identity.json"])
        self.assertEqual(identity["safe_hash"], kit.sha256(raw))
        self.assertEqual(plistlib.loads(payload["session-target/identity.plist"]), identity)

    def test_single_session_refuses_missing_recovery_and_competing_kexts(self):
        guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
        def configuration(args="-v -nvoff", deletes=None, entries=None):
            return plistlib.dumps({"NVRAM": {"Add": {guid: {"boot-args": args}},
                                             "Delete": {guid: deletes if deletes is not None else ["boot-args"]}},
                                   "Kernel": {"Add": entries or []}})
        for raw in (configuration("-v"), configuration(deletes=[]),
                    configuration("-nvoff nmxintel=1"),
                    configuration(entries=[{"Enabled": True, "BundlePath": "NMXGPU.kext"}])):
            with self.subTest(raw=raw), self.assertRaises(kit.InvalidKit):
                kit.session_payload(raw, "1401")
        with self.assertRaises(kit.InvalidKit):
            kit.session_payload(configuration(), "../USB")

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
