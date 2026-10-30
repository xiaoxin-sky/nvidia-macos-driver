"""Prepare an offline target-preflight kit from verified compiled candidates.

This runs on the Windows preparation machine. macOS uses only its bundled shell
and command-line tools. The output never edits a live EFI, installs a driver or
enables a GPU. All original component archives remain byte-for-byte intact.
"""

import argparse
import hashlib
import importlib.util
import io
import json
import pathlib
import plistlib
import re
import tarfile


class InvalidKit(ValueError):
    """An input cannot satisfy the offline preparation contract."""


def require(condition, message):
    """Fail before creating an output directory on invalid or incomplete input."""
    if not condition:
        raise InvalidKit(message)


def sha256(data):
    """Hash an immutable input, copied payload or generated evidence file."""
    return hashlib.sha256(data).hexdigest()


def relative_path(name):
    """Accept unambiguous portable package paths, never host filesystem paths."""
    p = pathlib.PurePosixPath(name)
    require(name and not p.is_absolute() and ".." not in p.parts and
            "\\" not in name and ":" not in name and "\n" not in name and
            p.as_posix() == name and name != ".", f"unsafe package path: {name!r}")
    return p


def checked_candidate(directory):
    """Verify the complete existing kit manifest before consuming any tar bytes.

    This verifies consistency, not remote authenticity; independent GitHub ZIP
    digest checks are retained in evidence.json from the earlier assembler.
    """
    require(directory.is_dir() and not directory.is_symlink(), "candidate directory missing or linked")
    manifest = directory / "SHA256SUMS"
    require(manifest.is_file() and not manifest.is_symlink(), "candidate SHA256SUMS missing")
    files, aliases = {}, set()
    for line in manifest.read_text(encoding="utf-8").splitlines():
        match = re.fullmatch(r"([0-9a-f]{64})  (.+)", line)
        require(match is not None, "malformed candidate checksum line")
        expected, name = match.groups()
        parts = relative_path(name).parts
        require(name.casefold() not in aliases, "duplicate candidate checksum entry")
        aliases.add(name.casefold())
        source = directory.joinpath(*parts)
        require(not any(directory.joinpath(*parts[:i]).is_symlink() for i in range(1, len(parts) + 1)),
                f"linked candidate member: {name}")
        require(source.is_file(), f"missing candidate member: {name}")
        data = source.read_bytes()
        require(sha256(data) == expected, f"candidate checksum mismatch: {name}")
        files[name] = data
    actual = {f.relative_to(directory).as_posix() for f in directory.rglob("*") if f.is_file()}
    require(actual == set(files) | {"SHA256SUMS"}, "candidate has unmanifested or missing files")
    require("evidence.json" in files, "candidate evidence missing")
    evidence = json.loads(files["evidence.json"])
    require(evidence.get("hardware_ready") is False and evidence.get("gpu_executed") is False and
            evidence.get("installed") is False, "expected offline-only candidate evidence")
    require(set(evidence.get("components", {})) == {"kernel", "userland", "metal"},
            "candidate must contain exactly three matched components")
    for name, component in evidence["components"].items():
        expected_name = f"uhd770-acceleration-{name}.tar.gz"
        require(component.get("output_tar") == expected_name and expected_name in files and
                sha256(files[expected_name]) == component.get("output_tar_sha256"),
                f"candidate component digest mismatch: {name}")
    return files, evidence


def runtime_manifest(files, validator_path):
    """Reuse the assembler's tar policy before root-side Mac extraction.

    Only runtime Library/probe entries are merged; component logs stay separate.
    Differing duplicate runtime names are refused. The generated content hashes
    later detect copy/extraction errors without requiring Python on macOS.
    """
    spec = importlib.util.spec_from_file_location("uhd770_candidate_assembler", validator_path)
    validator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(validator)
    known, regular, links = {}, {}, {}
    for component in ("kernel", "userland", "metal"):
        data = files[f"uhd770-acceleration-{component}.tar.gz"]
        if component != "kernel":
            validator.tar_entries(data, component)
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            for entry in archive:
                name = entry.name.removeprefix("./")
                if name == ".":
                    continue
                relative_path(name)
                if component == "kernel":
                    require(entry.isdir() or entry.isfile(), "kernel tar may contain only directories/files")
                    require(not entry.mode & 0o7000 and
                            (name in {"Library", "Library/Extensions"} or
                             name.startswith("Library/Extensions/NMXGPU.kext")), "unexpected kernel tar member")
                if entry.isdir() or not name.startswith(("Library/", "probe/")):
                    continue
                require(entry.isfile() or entry.issym(), "runtime hardlinks are not supported")
                identity = ("file", sha256(archive.extractfile(entry).read())) if entry.isfile() else ("link", entry.linkname)
                require(name not in known or known[name] == identity, f"conflicting runtime path: {name}")
                known[name] = identity
                if entry.isfile():
                    regular[name] = identity[1]
                else:
                    links[name] = entry.linkname
    required = {"Library/Extensions/NMXGPU.kext/Contents/MacOS/NMXGPU",
                "Library/Extensions/NMXGPU.kext/Contents/Info.plist"}
    require(required <= set(regular), "kernel runtime incomplete")
    return regular, links


def firmware_tar(directory, specification):
    """Create a minimal digest-pinned i915 archive with its redistribution license.

    Required file names come from the exact drm-kmod DMC/GuC/HuC tables, including
    their fallback names. No firmware is modified or loaded. A local status file
    is deliberately not accepted as proof of the actual bytes.
    """
    files = {}
    for name, expected in specification["files"].items():
        parts = relative_path(name).parts
        path = directory.joinpath(*parts)
        require(not path.is_symlink() and path.is_file(), f"firmware file missing/linked: {name}")
        require(not any(directory.joinpath(*parts[:i]).is_symlink() for i in range(1, len(parts))),
                f"linked firmware parent: {name}")
        data = path.read_bytes()
        require(sha256(data) == expected, f"firmware digest mismatch: {name}")
        files[name] = data
    require("LICENSES/LICENSE.i915" in files and any(n.startswith("i915/") for n in files),
            "firmware specification needs i915 bytes and license")
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz", format=tarfile.PAX_FORMAT) as archive:
        for name, data in sorted(files.items()):
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode = len(data), 0o644
            archive.addfile(entry, io.BytesIO(data))
    return out.getvalue()


def recovery_copy(source):
    """Generate only an opt-out reference from an explicit saved OpenCore plist.

    The returned copy is not installed. Existing ACPI/device/kernel/security
    settings are preserved. A saved backup may differ from the current boot EFI;
    its SHA256 is recorded so callers cannot imply current-boot provenance.
    """
    data = plistlib.loads(source)
    guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    try:
        args = data["NVRAM"]["Add"][guid]["boot-args"]
        deletes = data["NVRAM"]["Delete"][guid]
    except (KeyError, TypeError) as error:
        raise InvalidKit("reference config lacks explicit OpenCore boot-args Add/Delete") from error
    require(isinstance(args, str) and isinstance(deletes, list) and
            all(isinstance(x, str) for x in deletes), "invalid OpenCore boot-args types")
    words = [w for w in args.split() if not w.startswith(TEST_ONLY_ARGS) and w != "-nvoff"]
    data["NVRAM"]["Add"][guid]["boot-args"] = " ".join(words + ["-nvoff"])
    if "boot-args" not in deletes:
        deletes.append("boot-args")
    return plistlib.dumps(data, sort_keys=False)


# Boot arguments only the one-boot test config carries. AMFI is relaxed there for
# plan step F (WindowServer loading the ad-hoc signed Metal plugin), as the user
# approved on 2026-10-28; the safe -nvoff config never has it.
TEST_ONLY_ARGS = ("nmxintel=", "nmxdiagdelay=", "amfi_get_out_of_my_way=")


def session_payload(source, volume_label):
    """Build a one-boot opt-in and independent recovery from an explicit USB.

    The input must already be an opt-out OpenCore config with a boot-args Delete
    rule. All unrelated settings and raw safe-config bytes are retained. These
    private machine files must never be committed with the generic tools.
    """
    data = plistlib.loads(source)
    guid = "7C436110-AB2A-4BBB-A880-FE41995C9F82"
    args = data["NVRAM"]["Add"][guid]["boot-args"]
    deletes = data["NVRAM"]["Delete"][guid]
    require(isinstance(args, str) and isinstance(deletes, list) and
            "boot-args" in deletes, "session USB requires an existing boot-args refresh rule")
    words = args.split()
    require("-nvoff" in words and not any(w.startswith(TEST_ONLY_ARGS) for w in words),
            "session USB must already be in clean -nvoff recovery mode")
    for entry in data.get("Kernel", {}).get("Add", []):
        require(not (entry.get("Enabled") and
                     entry.get("BundlePath", "").split("/")[0] in {"NMXGPU.kext", "NMXAccel.kext"}),
                "session cannot replace a competing EFI-injected NMX bundle")
    require(re.fullmatch(r"[A-Za-z0-9_-]{1,32}", volume_label) is not None, "invalid USB label")
    # Verbose boot only where it diagnoses something: the safe config may drop -v to boot faster (r41)
    kept = [w for w in words if w != "-nvoff"]
    if "-v" not in kept:
        kept.insert(0, "-v")
    data["NVRAM"]["Add"][guid]["boot-args"] = " ".join(
        kept + ["nmxintel=1", "nmxdiagdelay=60", "amfi_get_out_of_my_way=0x1"])
    test = plistlib.dumps(data, sort_keys=False)
    identity = {"safe_hash": sha256(source), "test_hash": sha256(test), "volume_label": volume_label}
    return {"session-target/config.safe.plist": source,
            "session-target/config.test.plist": test,
            "session-target/identity.plist": plistlib.dumps(identity),
            "session-target/identity.json": (json.dumps(identity, indent=2) + "\n").encode()}


def prepare(candidate, firmware, output, source, config_backup=None, session_config=None, volume_label="1401"):
    """Validate all inputs, then write a fresh offline preparation directory.

    Existing output is never overwritten. Component archives are copied whole;
    the Mac staging script later extracts them inside a new root-owned folder.
    """
    require(not output.exists(), "output already exists; choose a new directory")
    files, evidence = checked_candidate(candidate)
    runtime, links = runtime_manifest(files, source.parent / "kit" / "assemble.py")
    specification = json.loads((source / "firmware.json").read_text(encoding="utf-8"))
    payload = {f"candidate/{name}": data for name, data in files.items()}
    payload["candidate/SHA256SUMS"] = (candidate / "SHA256SUMS").read_bytes()
    payload["firmware.tar.gz"] = firmware_tar(firmware, specification)
    payload["firmware.json"] = (source / "firmware.json").read_bytes()
    runtime.update({f"firmware/{name}": digest for name, digest in specification["files"].items()})
    payload["runtime-SHA256SUMS"] = "".join(f"{digest}  {name}\n" for name, digest in sorted(runtime.items())).encode("utf-8")
    payload["runtime-links.json"] = (json.dumps(links, indent=2) + "\n").encode("utf-8")
    for path in source.rglob("*"):
        relative = path.relative_to(source)
        if not path.is_file() or path.is_symlink() or "__pycache__" in relative.parts:
            continue
        # Legacy login-time compute is intentionally not distributed. The
        # manual helper is only invoked explicitly by the root test command.
        if path.name == "com.uhd770.mvp.session-user.plist":
            continue
        if path.suffix in {".sh", ".plist", ".txt", ".ps1", ".command"}:
            payload[f"tools/{relative.as_posix()}"] = path.read_bytes()
    for needed in ["tools/manage.sh", "tools/preflight.sh", "tools/README.txt",
                   "tools/capture/collector.sh", "tools/capture/com.uhd770.mvp.capture.plist",
                   "tools/probes/run-probe.sh"]:
        require(needed in payload, f"deployment tool incomplete: {needed}")
    plan = {"schema_version": 1, "classification": "target-preflight-only",
            "hardware_ready": False, "gpu_executed": False, "driver_installation_enabled": False,
            "candidate_evidence_sha256": sha256(files["evidence.json"]),
            "components": {name: {k: c[k] for k in ("run_url", "source_commit", "output_tar_sha256")}
                           for name, c in evidence["components"].items()},
            "firmware": specification,
            "next_gate": "Target preflight, isolated KC linkage and recorder validation; no GPU opt-in."}
    if config_backup:
        original = config_backup.read_bytes()
        payload["reference-efi/config.saved-original.plist"] = original
        payload["reference-efi/config.optout-reference.plist"] = recovery_copy(original)
        plan["reference_efi"] = {"source_sha256": sha256(original), "installed": False,
                                 "current_boot_efi_verified": False,
                                 "note": "Saved reference only. Compare with the actual booting EFI before any later edit."}
    if session_config:
        payload.update(session_payload(session_config.read_bytes(), volume_label))
        for name in ("Start-UHD770.command", "Run-UHD770-Test.command", "Run-UHD770-Desktop.command",
                     "Archive-UHD770-Failed.command", "Restore-UHD770.ps1", "README-session.txt"):
            payload[name] = (source / name).read_bytes()
        plan.update({"classification": "opt-in-manual-session-candidate",
                     "driver_installation_enabled": True,
                     "compute_trigger": "explicit-manual-command-after-reboot",
                     "login_compute_enabled": False,
                     "next_gate": "Prepare, reboot through matched USB, explicitly invoke Run-UHD770-Test.command.",
                     "runtime_verified": False})
    payload["PLAN.json"] = (json.dumps(plan, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    payload["README.txt"] = (source / "README.txt").read_bytes()
    payload["SHA256SUMS"] = "".join(f"{sha256(data)}  {name}\n" for name, data in sorted(payload.items())).encode("utf-8")
    output.mkdir(parents=True, exist_ok=False)
    for name, data in sorted(payload.items()):
        target = output.joinpath(*relative_path(name).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(data)
    return plan


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=pathlib.Path)
    parser.add_argument("--firmware", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--config-backup", type=pathlib.Path)
    parser.add_argument("--session-config", type=pathlib.Path)
    parser.add_argument("--usb-label", default="1401")
    arguments = parser.parse_args()
    try:
        prepare(arguments.candidate.resolve(), arguments.firmware.resolve(), arguments.output.resolve(),
                pathlib.Path(__file__).resolve().parent, arguments.config_backup,
                arguments.session_config, arguments.usb_label)
    except (InvalidKit, OSError, ValueError, KeyError, plistlib.InvalidFileException, tarfile.TarError) as error:
        parser.exit(1, f"preparation refused: {error}\n")
    print(f"Prepared {arguments.output}; no driver installed, hardware_ready=false")
