"""Assemble verified CI candidates without extracting or installing Mac binaries.

The explicit manifest supplies local ZIPs and their independently obtained
digests/provenance. Every ZIP digest is checked before any archive is opened.
Build evidence is a packaging gate, never evidence of hardware acceleration.
"""

import argparse
import gzip
import hashlib
import io
import json
import pathlib
import plistlib
import posixpath
import re
import struct
import tarfile
import zipfile


class InvalidCandidate(ValueError):
    """The supplied artifact cannot satisfy the offline candidate contract."""


def require(condition, message):
    """Reject incomplete or ambiguous inputs before creating the kit directory."""
    if not condition:
        raise InvalidCandidate(message)


def digest(data):
    """Return the SHA256 of a copied artifact or evidence payload."""
    return hashlib.sha256(data).hexdigest()


def safe_name(name, label):
    """Normalize an archive-relative POSIX path, refusing traversal/drive forms."""
    require(isinstance(name, str) and name and "\\" not in name and ":" not in name,
            f"{label}: invalid archive path {name!r}")
    require(not name.startswith("/") and ".." not in name.split("/"),
            f"{label}: escaping archive path {name!r}")
    return posixpath.normpath(name)


def zip_entries(archive, label):
    """Index ZIP members without filesystem extraction or duplicate aliases."""
    result, aliases = {}, set()
    for entry in archive.infolist():
        name = safe_name(entry.filename, label)
        require(name.casefold() not in aliases, f"{label}: duplicate ZIP member {name}")
        require(not entry.flag_bits & 1, f"{label}: encrypted ZIP member")
        aliases.add(name.casefold())
        if not entry.is_dir():
            result[name] = entry
    require(archive.testzip() is None, f"{label}: ZIP CRC verification failed")
    return result


def text_file(archive, entries, name, label):
    """Read a required, bounded UTF8 CI evidence file from its verified ZIP."""
    require(name in entries, f"{label}: missing required evidence {name}")
    require(entries[name].file_size <= 16 * 1024 * 1024, f"{label}: oversized evidence {name}")
    try:
        return archive.read(entries[name]).decode("utf-8")
    except UnicodeDecodeError as error:
        raise InvalidCandidate(f"{label}: non-UTF8 evidence {name}") from error


def tar_entries(payload, component, expected_logs=None):
    """Validate tar paths, link targets, member types and candidate payloads.

    No Mach-O file or symlink is extracted on the host. Links must resolve to
    an existing member inside this tar, and members below a link are refused.
    The original tar bytes and executable bits remain untouched in the kit.
    """
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:gz") as archive:
        entries, aliases = {}, set()
        for entry in archive.getmembers():
            name = safe_name(entry.name, component)
            require(name.casefold() not in aliases, f"{component}: duplicate tar member {name}")
            require(entry.isdir() or entry.isfile() or entry.issym() or entry.islnk(),
                    f"{component}: unsupported tar member type {name}")
            require(not entry.mode & 0o7000, f"{component}: privileged tar mode {name}")
            entries[name] = entry
            aliases.add(name.casefold())
        for name, entry in entries.items():
            parent = posixpath.dirname(name)
            while parent and parent != ".":
                require(parent not in entries or entries[parent].isdir(),
                        f"{component}: member below a link/file {name}")
                parent = posixpath.dirname(parent)
            if entry.issym() or entry.islnk():
                require(entry.linkname and not entry.linkname.startswith("/") and
                        "\\" not in entry.linkname and ":" not in entry.linkname,
                        f"{component}: unsafe link {name}")
                target = posixpath.normpath(posixpath.join(posixpath.dirname(name), entry.linkname)
                                           if entry.issym() else entry.linkname)
                require(target != ".." and not target.startswith("../") and target in entries,
                        f"{component}: escaping or dangling link {name}")
                seen = {name}
                while entries[target].issym() or entries[target].islnk():
                    require(target not in seen, f"{component}: cyclic tar link {name}")
                    seen.add(target)
                    linked = entries[target]
                    target = posixpath.normpath(posixpath.join(posixpath.dirname(target), linked.linkname)
                                               if linked.issym() else linked.linkname)
                    require(target in entries and target != ".." and not target.startswith("../"),
                            f"{component}: invalid link chain {name}")
                require(not entry.islnk() or entries[target].isfile(),
                        f"{component}: hard link to non-file {name}")
        required = ["probe/uhd770-compute-probe", "Library/GPUBundles/nvmtl/libvulkan_intel.dylib"] if component == "userland" else [
            "probe/uhd770-metal-probe", "Library/GPUBundles/nvmtl/air-opt",
            "Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver",
            "Library/Extensions/NMXAccel.kext/Contents/MacOS/NMXAccel",
        ]
        for name in required:
            require(name in entries and entries[name].isfile() and entries[name].mode & 0o111,
                    f"{component}: missing/non-executable required member {name}")
        if component == "metal":
            name = "Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/air-runtime"
            require(name in entries and entries[name].issym() and entries[name].linkname == "../../../nvmtl",
                    "metal: signed bundle air-runtime link was not preserved")
        for name, expected in (expected_logs or {}).items():
            require(name in entries and entries[name].isfile() and
                    archive.extractfile(entries[name]).read() == expected,
                    f"{component}: preserved tar evidence differs from outer ZIP: {name}")
        return {name: {"size": entry.size, "mode": oct(entry.mode), "link": entry.linkname}
                for name, entry in sorted(entries.items())}


def kernel_tar(archive, entries):
    """Repackage only NMXGPU.kext ZIP bytes with explicit native Unix modes."""
    prefix = "NMXGPU.kext/"
    files = {name: entry for name, entry in entries.items() if name.startswith(prefix)}
    executable = "NMXGPU.kext/Contents/MacOS/NMXGPU"
    info = "NMXGPU.kext/Contents/Info.plist"
    require(executable in files and files[executable].file_size > 1024 and info in files,
            "kernel: missing NMXGPU executable or Info.plist")
    properties = plistlib.loads(archive.read(files[info]))
    require(properties.get("CFBundleExecutable") == "NMXGPU" and
            properties.get("CFBundleIdentifier") == "com.nullmoth.NMXGPU", "kernel: wrong kext identity")
    directories, evidence = {"Library", "Library/Extensions", "Library/Extensions/NMXGPU.kext"}, {}
    for name, entry in files.items():
        require((entry.external_attr >> 16) & 0o170000 != 0o120000,
                "kernel: ZIP contains a symlink whose original link bytes are ambiguous")
        parent = posixpath.dirname("Library/Extensions/" + name)
        while parent:
            directories.add(parent)
            parent = posixpath.dirname(parent)
    output = io.BytesIO()
    with gzip.GzipFile(fileobj=output, mode="wb", filename="", mtime=0) as compressed:
        with tarfile.open(fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT) as target:
            for name in sorted(directories):
                entry = tarfile.TarInfo(name)
                entry.type, entry.mode = tarfile.DIRTYPE, 0o755
                target.addfile(entry)
            for name, source in sorted(files.items()):
                data = archive.read(source)
                entry = tarfile.TarInfo("Library/Extensions/" + name)
                entry.size = len(data)
                entry.mode = 0o755 if name == executable else 0o644
                target.addfile(entry, io.BytesIO(data))
                evidence[name] = {"sha256": digest(data), "bytes": len(data), "mode": oct(entry.mode)}
    return output.getvalue(), evidence


def check_component(archive, entries, name, spec):
    """Require component-specific success evidence and retain its raw gate logs."""
    logs = {}

    def read(path):
        value = text_file(archive, entries, path, name)
        logs[path] = value.encode("utf-8")
        return value

    metadata = {"run_url": spec["run_url"], "source_commit": spec["source_commit"],
                "commit_evidence": "manifest-declared"}
    if name == "kernel":
        for path, pattern in [("logs/all.log", r"sources: 900\s+compiled: 900\s+failed: 0"),
                              ("logs/i915.log", r"sources: 274\s+compiled: 274\s+failed: 0"),
                              ("logs/rt.log", r"runtime sources: 76\s+failed: 0")]:
            require(re.search(pattern, read(path)), f"kernel: failed/incomplete source count {path}")
        units = [path for path in entries if (path.startswith(("logs/logs/", "logs/logs-i915/", "logs/lklogs/"))
                 and path.endswith(".log")) or (path.startswith(("logs/srclog_", "logs/xlog_")) and path.endswith(".txt"))]
        require(len(units) == 1250 and not any(path.endswith(".failed") for path in entries),
                "kernel: incomplete/failed compilation logs")
        require("CPU scope, persistent pins, failure cleanup and fd-close PASS" in read("logs/nmx-i915-mmap-test.log"),
                "kernel: mapping lifecycle fixture did not pass")
        require("concurrency, requeue, cancel, drain and worker free passed" in read("logs/nmx-taskqueue-test.log"),
                "kernel: workqueue lifecycle fixture did not pass")
        require("Native KC symbol/dependency preflight passed" in read("logs/kernel-collection-preflight.txt"),
                "kernel: KC preflight missing/failed")
        require("NMX DRM file identity: actual helper, ABI, shared opens and invalid minors passed" in
                read("logs/nmx-drm-node-test.log"), "kernel: NMX node-identity interface evidence missing/failed")
        metadata["nmx_node_info_ioctl"] = "0x40084e44"
        require("NMX framebuffer start identity/order/failure tests passed" in read("logs/nmx-fb-start-test.log"),
                "kernel: framebuffer controller initialization regression check missing/failed")
        require("NMX runtime-PM policy: actual i915 conditional wakerefs retained" in read("logs/nmx-runtime-pm-test.log"),
                "kernel: runtime-PM configuration regression check missing/failed")
        require(not re.search(r"(?m)^-DCONFIG_PM(?:_SLEEP|_RUNTIME)?(?:=|$)", read("logs/amd.flags")),
                "kernel: unsupported Linux runtime PM was compiled in")
        metadata["compiled_units"] = {path: digest(archive.read(entries[path])) for path in sorted(units)}
        payload, metadata["kext_members"] = kernel_tar(archive, entries)
    else:
        require(read("logs/source-commit.txt").strip() == spec["source_commit"], f"{name}: source commit mismatch")
        metadata["commit_evidence"] = "artifact-source-commit-log"
        build = read("logs/build.txt")
        if name == "userland":
            require("Real Intel ICD and compute diagnostic compiled; no GPU executed." in build,
                    "userland: final success marker missing")
            require(re.fullmatch(r"CLOCK_UPTIME_RAW matches mach_absolute_time; converted deadline=\d+\s*",
                                 read("logs/native_clock_smoke.txt")), "userland: native Mach clock comparison missing/failed")
            require("actual NMX deadline epoch, poll/infinite and error conversion passed" in read("logs/clock_fixture.txt"),
                    "userland: deadline fixture missing/failed")
            require("NMX ANV mmap ABI, slice ownership and failure fixture passed" in read("logs/nmx-mmap-test.txt"),
                    "userland: ANV mapping fixture missing/failed")
            require("NMX Darwin node identity: compiled libdrm enumeration, clone fds, PCI isolation and failures passed" in
                    read("logs/nmx-node-test.txt"), "userland: compiled libdrm node-identity test missing/failed")
            metadata["nmx_node_info_ioctl"] = "0x40084e44"
        else:
            require("Intel accelerator, translator and Metal frontend compiled; nothing installed or loaded." in build,
                    "metal: final success marker missing")
            smoke = json.loads(read("logs/apple-air-smoke.txt"))
            require(smoke.get("input_kind") == "decoded-apple-air" and smoke.get("gpu_executed") is False and
                    smoke.get("check") == "offline-translator-abi" and smoke.get("spirv", {}).get("bytes", 0) > 20,
                    "metal: Apple AIR translation evidence invalid")
            for key, path in [("input_sha256", "logs/apple.ll"), ("output_sha256", "logs/apple-air.spv")]:
                require(path in entries and digest(archive.read(entries[path])) == smoke.get(key),
                        f"metal: AIR smoke payload digest mismatch {path}")
            require("logs/apple.air" in entries, "metal: captured Apple AIR bitcode missing")
            air = archive.read(entries["logs/apple.air"])
            if air[:4] == b"\xde\xc0\x17\x0b" and len(air) >= 20:
                offset, length = struct.unpack_from("<II", air, 8)
                require(offset >= 20 and length >= 4 and offset + length <= len(air),
                        "metal: invalid Apple AIR bitcode wrapper")
                bitcode = air[offset:offset + length]
            else:
                bitcode = air
            require(bitcode[:4] == b"BC\xc0\xde" and
                    re.search(rb'target triple = "air64-apple-macosx15\.', archive.read(entries["logs/apple.ll"])),
                    "metal: missing Apple AIR bitcode/target evidence")
            metadata["apple_air_bitcode_sha256"] = digest(air)
            spirv = archive.read(entries["logs/apple-air.spv"])
            require(spirv[:4] == b"\x03\x02\x23\x07" and len(spirv) == smoke["spirv"]["bytes"],
                    "metal: malformed SPIR-V smoke result")
            require("Native KC symbol/dependency preflight passed" in read("logs/kernel-collection-preflight.txt"),
                    "metal: KC preflight missing/failed")
            metadata["apple_air_smoke"] = smoke
        tar_name = f"uhd770-acceleration-{name}.tar.gz"
        require(tar_name in entries and sum(path.endswith(".tar.gz") for path in entries) == 1,
                f"{name}: missing or ambiguous preserved component tar")
        payload = archive.read(entries[tar_name])
        read("logs/acceleration-sources.json")
        expected_logs = dict(logs)
        if name == "metal":
            expected_logs.update({path: archive.read(entries[path]) for path in
                                  ["logs/apple.air", "logs/apple.ll", "logs/apple-air.spv"]})
        metadata["tar_members"] = tar_entries(payload, name, expected_logs)
    return payload, logs, metadata


def assemble(manifest_path, output, repo, dependency_root=None):
    """Validate every input in memory, then create a fresh offline-only kit."""
    require(not output.exists(), f"output already exists; refusing overwrite: {output}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    specs = manifest.get("components", {})
    require(set(specs) == {"kernel", "userland", "metal"}, "manifest needs exactly kernel/userland/metal components")
    inputs = {}
    # Complete all expected-digest checks before ZipFile or tarfile inspects anything.
    for name, spec in specs.items():
        require(re.fullmatch(r"[0-9a-f]{64}", spec.get("sha256", "")), f"{name}: invalid expected SHA256")
        require(re.fullmatch(r"[0-9a-f]{40}", spec.get("source_commit", "")), f"{name}: full source commit required")
        require(re.fullmatch(r"https://github\.com/[\w.-]+/[\w.-]+/actions/runs/\d+", spec.get("run_url", "")),
                f"{name}: invalid GitHub run URL")
        path = (manifest_path.parent / spec["zip"]).resolve()
        require(path.is_file(), f"{name}: ZIP not found: {path}")
        data = path.read_bytes()
        require(digest(data) == spec["sha256"], f"{name}: complete ZIP SHA256 mismatch")
        inputs[name] = data
    files, evidence = {}, {"schema_version": 1, "classification": "compiled-candidate",
                           "hardware_ready": False, "gpu_executed": False, "installed": False,
                           "components": {}, "input_manifest_sha256": digest(manifest_path.read_bytes())}
    for name in ["kernel", "userland", "metal"]:
        with zipfile.ZipFile(io.BytesIO(inputs[name])) as archive:
            entries = zip_entries(archive, name)
            payload, logs, record = check_component(archive, entries, name, specs[name])
        tar_name = f"uhd770-acceleration-{name}.tar.gz"
        files[tar_name] = payload
        for path, data in logs.items():
            files[f"evidence/{name}/{path}"] = data
        record.update({"input_zip_sha256": specs[name]["sha256"], "input_zip_bytes": len(inputs[name]),
                       "output_tar": tar_name, "output_tar_sha256": digest(payload),
                       "preserved_tar_verbatim": name != "kernel"})
        evidence["components"][name] = record
    for path in ["LICENSE", "NOTICE", "translator/LICENSE", "translator/COPYING",
                 "experimental/uhd770/sources.json", "experimental/uhd770/acceleration/sources.json"]:
        require((repo / path).is_file(), f"missing project license/source pointer: {path}")
        files[f"source-and-licenses/{path}"] = (repo / path).read_bytes()
    evidence["source_repository"] = "https://github.com/xiaoxin-sky/nvidia-macos-driver"
    evidence["dependency_license_files"] = []
    if dependency_root:
        source_names = {"mesa", "libdrm", "vulkan-loader", "vulkan-headers", "spirv-tools",
                        "spirv-headers", "spirv-llvm-translator", "translator-spirv-headers",
                        "glslang", "llvm", "air-reader", "air-opt", "nvidia-headers"}
        for directory in dependency_root.iterdir():
            if not directory.is_dir() or directory.name.casefold() not in source_names:
                continue
            for source in directory.rglob("*"):
                relative = source.relative_to(directory)
                if len(relative.parts) > 3 or not source.is_file() or source.is_symlink():
                    continue
                if source.name in {"LICENSE", "LICENSE.txt", "COPYING", "COPYING.txt", "license.rst"} or (
                        relative.parts[0].lower() in {"license", "licenses"}):
                    if source.stat().st_size <= 1024 * 1024:
                        target = f"source-and-licenses/dependencies/{directory.name}/{relative.as_posix()}"
                        files[target] = source.read_bytes()
                        evidence["dependency_license_files"].append(target)
    evidence["file_sha256"] = {name: digest(data) for name, data in sorted(files.items())}
    files["evidence.json"] = (json.dumps(evidence, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    files["README.txt"] = (
        "UHD 770 compiled candidate archives; hardware_ready=false.\n"
        "Nothing was installed, activated or run on a GPU by this assembler.\n"
        "Keep all three tar.gz archives intact on Windows: they preserve macOS executable modes and signed bundle links.\n"
        "The kernel tar recreates Unix modes from ZIP entries without changing kext file bytes.\n"
        "No installer or activation commands are included. Read evidence.json for build limits and provenance.\n"
        "Offline build/translation checks do not prove UHD 770 acceleration or a working Metal device.\n"
        "\nUHD 770 加速 MVP 离线候选测试材料\n"
        "目标：i7-12700 / UHD 770（8086:4680），x86_64 macOS 15。\n"
        "包含：NMXGPU、NMXAccel、真实 Intel ANV/加载器、Metal 前端与翻译库、Vulkan 和 Metal 计算读回程序。\n"
        "构建、接口测试、Apple 着色器翻译与内核链接检查已通过；尚未在 UHD 770 上执行 GPU 命令。\n"
        "三个 tar.gz 请原样保存，在 macOS 中解压；不要在 Windows 解包成目录后再拷贝，以免丢失执行权限和签名符号链接。\n"
        "本包不含安装、启用或修改 EFI 的操作；尚不证明 Metal 设备初始化、实机出图或硬件加速成功。\n"
        "首次运行范围仅为计算及读回；WindowServer 桌面加速、完整睡眠唤醒和视频编解码尚未完成。\n"
        "后续实机验证仍需先准备与本包匹配的回退和自动日志采集步骤。\n"
    ).encode("utf-8")
    files["SHA256SUMS"] = "".join(f"{digest(data)}  {name}\n" for name, data in sorted(files.items())).encode("utf-8")
    output.mkdir(parents=True, exist_ok=False)
    for name, data in files.items():
        target = output / name
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(data)
    return evidence


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    parser.add_argument("--output", required=True, type=pathlib.Path)
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[4])
    parser.add_argument("--dependency-root", type=pathlib.Path)
    arguments = parser.parse_args()
    try:
        assemble(arguments.manifest.resolve(), arguments.output.resolve(), arguments.repo.resolve(), arguments.dependency_root)
    except (InvalidCandidate, OSError, KeyError, ValueError, zipfile.BadZipFile, tarfile.TarError) as error:
        parser.exit(1, f"candidate rejected: {error}\n")
    print(f"assembled offline compiled candidate: {arguments.output}; hardware_ready=false")
