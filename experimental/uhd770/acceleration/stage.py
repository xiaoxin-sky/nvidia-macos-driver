"""Stage verified acceleration sources in a fresh, disposable build directory.

Only immutable archives enter the cache. Revisions, digests and archive roots are
checked together before extracting; patched trees and binaries are never reused.
Historical Darwin patches and NMX names come from recorded repository revisions.
Nothing here installs a driver, modifies an EFI or contacts a GPU.
"""
import argparse
import hashlib
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import urllib.request


def digest(path):
    """Return the SHA256 of a complete saved archive without loading it in RAM."""
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def archive(source, cache):
    """Cache a single digest-verified archive keyed by its complete revision."""
    assert re.fullmatch(r"[0-9a-f]{40}", source["revision"])
    assert re.fullmatch(r"[0-9a-f]{64}", source["sha256"])
    path = cache / (source["name"] + "-" + source["revision"] + ".tar.gz")
    if not path.exists():
        partial = path.with_suffix(".partial")
        with urllib.request.urlopen(source["url"], timeout=90) as response, partial.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
        assert digest(partial) == source["sha256"], f"download digest mismatch: {source['name']}"
        partial.replace(path)
    assert digest(path) == source["sha256"], f"cached digest mismatch: {path}"
    return path


def extract(path, source, destination):
    """Validate a single archive root before safe extraction into a fresh tree."""
    with tarfile.open(path) as stream:
        members = stream.getmembers()
        roots = {member.name.split("/")[0] for member in members}
        assert roots == {source["archiveRoot"]}, (source["name"], roots)
        assert source["revision"] in source["archiveRoot"]
        temporary = destination.parent / (destination.name + "-extract")
        temporary.mkdir()
        stream.extractall(temporary, filter="data")
        (temporary / source["archiveRoot"]).rename(destination)
        temporary.rmdir()


def git_bytes(repository, revision, path):
    """Read a tracked file at the pinned input, never from the mutable checkout."""
    return subprocess.check_output(["git", "-C", str(repository), "show", revision + ":" + path])


def stage(repository, root, cache, group):
    """Prepare one independent build group; root must not already contain files."""
    package = repository / "experimental/uhd770/acceleration"
    pins = json.loads((package / "sources.json").read_text(encoding="utf-8"))
    root.mkdir(parents=True, exist_ok=False)
    cache.mkdir(parents=True, exist_ok=True)
    sources = root / "src"
    sources.mkdir()
    for source in pins["sources"]:
        metal = source["name"] in {"nvidia-headers", "vulkan-headers"}
        if (group == "metal" and not metal) or (group == "userland" and source["name"] == "nvidia-headers"):
            continue
        extract(archive(source, cache), source, sources / source["name"])
        print("verified", source["name"], source["revision"], flush=True)
    if group == "userland":
        for name in ("mesa", "libdrm"):
            patch = root / (name + "-historical.patch")
            patch.write_bytes(git_bytes(repository, pins["historical_revision"], "gpu-port/patches/" + name + "-macos.patch"))
            subprocess.run(["git", "-C", str(sources / name), "apply", "--check", str(patch)], check=True)
            subprocess.run(["git", "-C", str(sources / name), "apply", str(patch)], check=True)
        # mesa-anv-iokit: ANV's ioctls go through libdrm's drmNmxIoctl, which WindowServer's sandbox needs (r40)
        for name in ("mesa-anv-nmx.patch", "mesa-nmx-clock.patch", "mesa-anv-readonly.patch", "mesa-anv-iokit.patch"):
            patch = package / "patches" / name
            assert patch.is_file(), f"required Darwin ANV repair is missing: {name}"
            subprocess.run(["git", "-C", str(sources / "mesa"), "apply", "--check", str(patch)], check=True)
            subprocess.run(["git", "-C", str(sources / "mesa"), "apply", str(patch)], check=True)
        # libdrm-nmx-readonly: WindowServer's sandbox lets it open the render node only read-only (UHD 770 F, r38);
        # libdrm-nmx-iokit: and denies its ioctls, which then go through NMXGPU's IOKit user client (r40)
        for name in ("libdrm-nmx-node.patch", "libdrm-nmx-readonly.patch", "libdrm-nmx-iokit.patch"):
            patch = package / "patches" / name
            subprocess.run(["git", "-C", str(sources / "libdrm"), "apply", "--check", str(patch)], check=True)
            subprocess.run(["git", "-C", str(sources / "libdrm"), "apply", str(patch)], check=True)
    else:
        raw = subprocess.check_output(["git", "-C", str(repository), "archive", pins["frontend_revision"], "kexts/NVRM", "plugin", "translator"])
        with tarfile.open(fileobj=io.BytesIO(raw)) as stream:
            stream.extractall(sources, filter="data")
        for name in ("accel/nmx_accel_names.h", "accel/nmx/Info.plist"):
            path = sources / "kexts/NVRM" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(git_bytes(repository, pins["historical_revision"], "kexts/NVRM/" + name))
        # UHD 770 plan step F on the pinned frontend: NMXAccel takes NMIntelFB as head 0 and gets its own arm
        # switches; the plugin lets WindowServer composite on an armed AMD/Intel accelerator
        patch = package / "patches/frontend-nmx.patch"
        subprocess.run(["git", "-C", str(sources), "apply", "--check", str(patch)], check=True)
        subprocess.run(["git", "-C", str(sources), "apply", str(patch)], check=True)
    (root / "sources.json").write_text(json.dumps(pins, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--cache", required=True, type=Path)
    parser.add_argument("--group", required=True, choices=["userland", "metal"])
    arguments = parser.parse_args()
    stage(Path(__file__).resolve().parents[3], arguments.root.resolve(), arguments.cache.resolve(), arguments.group)
