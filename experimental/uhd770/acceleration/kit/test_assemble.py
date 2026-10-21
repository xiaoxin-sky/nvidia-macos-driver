"""Synthetic artifact contract tests; they execute no GPU or packaged binary."""

import hashlib
import io
import json
import pathlib
import plistlib
import tarfile
import tempfile
import unittest
import zipfile

import assemble


def make_tar(component, extra=None, executable=True, evidence=None):
    """Create small synthetic archive members with the real packaging layout."""
    files = {"probe/uhd770-compute-probe": b"probe", "Library/GPUBundles/nvmtl/libvulkan_intel.dylib": b"icd"} if component == "userland" else {
        "probe/uhd770-metal-probe": b"probe", "Library/GPUBundles/nvmtl/air-opt": b"reader",
        "Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver": b"plugin",
        "Library/Extensions/NMXAccel.kext/Contents/MacOS/NMXAccel": b"accelerator",
    }
    files.update({name: value.encode() if isinstance(value, str) else value for name, value in (evidence or {}).items()})
    directories = {"."}
    for path in files:
        directories.update(parent.as_posix() for parent in pathlib.PurePosixPath(path).parents)
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as archive:
        for path in sorted(directories):
            member = tarfile.TarInfo(path)
            member.type, member.mode = tarfile.DIRTYPE, 0o755
            archive.addfile(member)
        for path, data in files.items():
            member = tarfile.TarInfo(path)
            member.mode = 0o755 if executable and not path.startswith("logs/") else 0o644
            member.size = len(data)
            archive.addfile(member, io.BytesIO(data))
        if component == "metal":
            member = tarfile.TarInfo("Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime")
            member.type, member.linkname = tarfile.SYMTYPE, "../../../nvmtl"
            archive.addfile(member)
        if extra:
            member = tarfile.TarInfo(extra[0])
            member.type, member.linkname = tarfile.SYMTYPE, extra[1]
            archive.addfile(member)
    return stream.getvalue()


def write_zip(path, entries):
    """Write test-only ZIP bytes, returning their explicit expected digest."""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for name, data in entries.items():
            archive.writestr(name, data)
    return assemble.digest(path.read_bytes())


def fixtures(root, missing_clock=False, missing_changing_lookup=False):
    """Prepare all required offline evidence using clearly synthetic payloads."""
    kernel = {
        "logs/all.log": "sources: 900  compiled: 900  failed: 0\n",
        "logs/i915.log": "sources: 274  compiled: 274  failed: 0\n",
        "logs/rt.log": "runtime sources: 76  failed: 0\n",
        "logs/nmx-i915-mmap-test.log": "CPU scope, persistent pins, failure cleanup and fd-close PASS\n",
        "logs/nmx-taskqueue-test.log": "concurrency, requeue, cancel, drain and worker free passed\n",
        "logs/kernel-collection-preflight.txt": "Native KC symbol/dependency preflight passed\n",
        "logs/nmx-drm-node-test.log": "NMX DRM file identity: actual helper, ABI, shared opens and invalid minors passed\n",
        "logs/nmx-fb-start-test.log": "NMX framebuffer start identity/order/failure tests passed\n",
        "logs/nmx-fb-bridge-test.log": "Framebuffer bridge fixture passed: native activation\n",
        "logs/nmx-runtime-pm-test.log": "NMX runtime-PM policy: actual i915 conditional wakerefs retained; no GPU power test\n",
        "logs/amd.flags": "-DCONFIG_DRM_I915\n",
        "NMXGPU.kext/Contents/MacOS/NMXGPU": b"synthetic Mach-O placeholder" * 100,
        "NMXGPU.kext/Contents/Info.plist": plistlib.dumps({"CFBundleExecutable": "NMXGPU", "CFBundleIdentifier": "com.nullmoth.NMXGPU"}),
    }
    for prefix, count in [("logs/logs/", 900), ("logs/logs-i915/", 274), ("logs/lklogs/", 76)]:
        kernel.update({f"{prefix}unit-{index}.log": "synthetic compile log\n" for index in range(count)})
    userland = {
        "logs/probe-diagnostics-test.txt": "Vulkan diagnostic callback/optional extension/lifetime checks passed; no GPU executed.\n",
        "logs/build.txt": "Real Intel ICD and compute diagnostic compiled; no GPU executed.\n",
        "logs/source-commit.txt": "a" * 40 + "\n", "logs/acceleration-sources.json": "{}\n",
        "logs/native_clock_smoke.txt": "CLOCK_UPTIME_RAW matches mach_absolute_time; converted deadline=500000000\n",
        "logs/clock_fixture.txt": "actual NMX deadline epoch, poll/infinite and error conversion passed\n",
        "logs/nmx-mmap-test.txt": "NMX ANV mmap ABI, slice ownership and failure fixture passed\n",
        "logs/nmx-node-test.txt": "NMX Darwin node identity: compiled libdrm enumeration, clone fds, PCI isolation and failures passed\n"
                                  "NMX Darwin changing-lookup discovery: fresh stat IDs, fd identity, canonical names and descriptor cleanup passed\n",
    }
    if missing_clock:
        del userland["logs/native_clock_smoke.txt"]
    if missing_changing_lookup:
        userland["logs/nmx-node-test.txt"] = userland["logs/nmx-node-test.txt"].splitlines()[0] + "\n"
    userland["uhd770-acceleration-userland.tar.gz"] = make_tar("userland", evidence=userland)
    air = b'; synthetic decoded Apple AIR\ntarget triple = "air64-apple-macosx15.0.0"\n'
    spirv = b"\x03\x02\x23\x07" + bytes(20)
    metal = {
        "logs/build.txt": "Intel accelerator, translator and Metal frontend compiled; nothing installed or loaded.\n",
        "logs/source-commit.txt": "a" * 40 + "\n", "logs/acceleration-sources.json": "{}\n",
        "logs/kernel-collection-preflight.txt": "Native KC symbol/dependency preflight passed\n",
        "logs/apple.ll": air, "logs/apple.air": b"BC\xc0\xdesynthetic bitcode", "logs/apple-air.spv": spirv,
        "logs/apple-air-smoke.txt": json.dumps({"check": "offline-translator-abi", "gpu_executed": False,
            "input_kind": "decoded-apple-air", "input_sha256": assemble.digest(air), "output_sha256": assemble.digest(spirv),
            "spirv": {"bytes": len(spirv)}}),
    }
    metal["uhd770-acceleration-metal.tar.gz"] = make_tar("metal", evidence=metal)
    manifest = {"components": {}}
    for component, entries in [("kernel", kernel), ("userland", userland), ("metal", metal)]:
        path = root / f"{component}.zip"
        manifest["components"][component] = {"zip": path.name, "sha256": write_zip(path, entries),
            "run_url": "https://github.com/example/driver/actions/runs/1", "source_commit": "a" * 40}
    path = root / "inputs.json"
    path.write_text(json.dumps(manifest))
    return path


class AssemblerTests(unittest.TestCase):
    def test_legacy_kernel_or_userland_cannot_be_mixed_with_node_identity_pair(self):
        """Reject independently hashed older artifacts before making a kit."""
        for component, missing in (("kernel", "logs/nmx-drm-node-test.log"),
                                   ("kernel", "logs/nmx-runtime-pm-test.log"),
                                   ("userland", "logs/nmx-node-test.txt")):
            with self.subTest(component=component), tempfile.TemporaryDirectory() as temporary:
                root = pathlib.Path(temporary)
                manifest_path = fixtures(root)
                manifest = json.loads(manifest_path.read_text())
                archive_path = root / f"{component}.zip"
                with zipfile.ZipFile(archive_path) as archive:
                    entries = {name: archive.read(name) for name in archive.namelist() if name != missing}
                manifest["components"][component]["sha256"] = write_zip(archive_path, entries)
                manifest_path.write_text(json.dumps(manifest))
                with self.assertRaises(assemble.InvalidCandidate) as refused:
                    assemble.assemble(manifest_path, root / "kit", pathlib.Path(__file__).resolve().parents[4])
                self.assertIn(missing, str(refused.exception))
                self.assertFalse((root / "kit").exists())

    def test_success_preserves_tars_and_always_denies_hardware_readiness(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            manifest = fixtures(root)
            evidence = assemble.assemble(manifest, root / "kit", pathlib.Path(__file__).resolve().parents[4])
            self.assertFalse(evidence["hardware_ready"])
            self.assertFalse(evidence["gpu_executed"])
            self.assertEqual(len(evidence["components"]["kernel"]["compiled_units"]), 1250)
            for component in ["userland", "metal"]:
                name = f"uhd770-acceleration-{component}.tar.gz"
                with zipfile.ZipFile(root / f"{component}.zip") as archive:
                    self.assertEqual(archive.read(name), (root / "kit" / name).read_bytes())
            with tarfile.open(root / "kit/uhd770-acceleration-kernel.tar.gz") as archive:
                member = archive.getmember("Library/Extensions/NMXGPU.kext/Contents/MacOS/NMXGPU")
                self.assertEqual(member.mode, 0o755)
                self.assertEqual(archive.extractfile(member).read(), b"synthetic Mach-O placeholder" * 100)
                self.assertEqual(archive.getmember("Library/Extensions/NMXGPU.kext/Contents/Info.plist").mode, 0o644)

    def test_missing_native_clock_does_not_create_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            manifest = fixtures(root, missing_clock=True)
            with self.assertRaisesRegex(assemble.InvalidCandidate, "native_clock_smoke"):
                assemble.assemble(manifest, root / "kit", pathlib.Path(__file__).resolve().parents[4])
            self.assertFalse((root / "kit").exists())

    def test_stable_stat_fixture_cannot_validate_xnu_discovery(self):
        """Older successful node tests omitted lookup-created clone IDs."""
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            manifest = fixtures(root, missing_changing_lookup=True)
            with self.assertRaisesRegex(assemble.InvalidCandidate, "XNU changing-lookup"):
                assemble.assemble(manifest, root / "kit", pathlib.Path(__file__).resolve().parents[4])
            self.assertFalse((root / "kit").exists())

    def test_every_digest_checked_before_any_zip_open(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            manifest_path = fixtures(root)
            manifest = json.loads(manifest_path.read_text())
            (root / "kernel.zip").write_bytes(b"not even a ZIP")
            manifest["components"]["kernel"]["sha256"] = assemble.digest(b"not even a ZIP")
            manifest["components"]["metal"]["sha256"] = "0" * 64
            manifest_path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(assemble.InvalidCandidate, "metal: complete ZIP SHA256 mismatch"):
                assemble.assemble(manifest_path, root / "kit", pathlib.Path(__file__).resolve().parents[4])
            self.assertFalse((root / "kit").exists())

    def test_existing_directory_is_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            marker = root / "keep.txt"
            marker.write_text("keep")
            with self.assertRaisesRegex(assemble.InvalidCandidate, "already exists"):
                assemble.assemble(root / "missing-manifest", root, root)
            self.assertEqual(marker.read_text(), "keep")

    def test_tar_refuses_traversal_absolute_and_dangling_links(self):
        for name, link in [("../escape", "probe"), ("escape", "../../outside"), ("escape", "/absolute"), ("escape", "missing")]:
            with self.subTest(name=name, link=link), self.assertRaises(assemble.InvalidCandidate):
                assemble.tar_entries(make_tar("userland", (name, link)), "userland")

    def test_tar_requires_executable_probes(self):
        with self.assertRaisesRegex(assemble.InvalidCandidate, "non-executable"):
            assemble.tar_entries(make_tar("userland", executable=False), "userland")

    def test_tar_duplicate_signed_bundle_link_is_rejected(self):
        with self.assertRaisesRegex(assemble.InvalidCandidate, "duplicate"):
            assemble.tar_entries(make_tar("metal", ("Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime", "../../../nvmtl")), "metal")


if __name__ == "__main__":
    unittest.main()
