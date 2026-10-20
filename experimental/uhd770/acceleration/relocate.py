"""Copy a Mach-O dependency closure into a standalone diagnostic bundle.

Uses recorded otool dependencies; system libraries stay on macOS, all other
strong dependencies must resolve from the original file or explicit search roots.
Edits only destination copies and signs them after install-name changes. This
does not certify runtime API/ABI compatibility or install/execute the binaries.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def command(*arguments):
    """Read one native inspection command, failing on any inspection error."""
    return subprocess.check_output(arguments, text=True)


def dependencies(path):
    """Read Mach-O imports and exclude the install-ID line of a dylib."""
    ids = command("otool", "-D", str(path)).splitlines()[1:]
    imports = [line.strip().split(" (", 1)[0] for line in command("otool", "-L", str(path)).splitlines()[1:]]
    return ids, [entry for entry in imports if entry not in ids]


def relocate(inputs, destination, searches):
    """Copy closure, reject conflicting basenames, rewrite and verify imports."""
    destination.mkdir(parents=True, exist_ok=True)
    records = {}
    pending = list(inputs)
    while pending:
        source = pending.pop()
        name = source.name
        data_digest = hashlib.sha256(source.read_bytes()).hexdigest()
        if name in records:
            assert records[name]["input_sha256"] == data_digest, f"basename collision: {name}"
            continue
        target = destination / name
        shutil.copy2(source, target)
        ids, imports = dependencies(source)
        record = {"source": str(source), "input_sha256": data_digest, "imports": imports}
        records[name] = record
        for imported in imports:
            if imported.startswith(("/usr/lib/", "/System/")):
                continue
            if imported.startswith("@loader_path/"):
                candidates = [source.parent / imported.removeprefix("@loader_path/")]
            elif imported.startswith("/"):
                candidates = [Path(imported)]
            else:
                assert imported.startswith("@rpath/"), f"unhandled import: {source}: {imported}"
                candidates = [source.parent / Path(imported).name]
            candidates += [directory / Path(imported).name for directory in searches]
            dependency = next((path for path in candidates if path.is_file()), None)
            assert dependency is not None, f"unresolved bundled import: {source}: {imported}"
            pending.append(dependency)
            subprocess.run(["install_name_tool", "-change", imported,
                            "@loader_path/" + dependency.name, str(target)], check=True)
        if ids:
            subprocess.run(["install_name_tool", "-id", "@loader_path/" + name, str(target)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(target)], check=True)
    for name in records:
        target = destination / name
        _, imports = dependencies(target)
        for imported in imports:
            if imported.startswith("@loader_path/"):
                assert (destination / imported.removeprefix("@loader_path/")).is_file()
            else:
                assert imported.startswith(("/usr/lib/", "/System/")), (name, imported)
        records[name]["output_sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
    (destination / "dependency-closure.json").write_text(json.dumps(records, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--input", type=Path, action="append", required=True)
    parser.add_argument("--search", type=Path, action="append", default=[])
    options = parser.parse_args()
    relocate(options.input, options.destination, options.search)
