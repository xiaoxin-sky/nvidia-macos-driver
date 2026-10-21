"""Extract the actual native-open and LinuxKPI file lifetime path for CI.

The template mocks allocation, locks and a DRM device callback. The adapter,
logical inode lookup, ioctl dispatch, final drop and pinned FreeBSD get/fput
functions are read from the build inputs, not copied into the test.
"""
import argparse
from pathlib import Path
import re


def definition(source, name, structure=False, optional=False):
    """Read one column-zero definition, refusing source-shape drift."""
    if structure:
        pattern = rf"^struct {re.escape(name)} \{{\n.*?^\}};"
    else:
        pattern = (r"^(?:(?:static|inline)\s+)*(?:struct \w+\s*\*|unsigned int|int|void)\s*"
                   + re.escape(name) + r"\([^;{}]*\)\n\{\n.*?^\}")
    matches = re.findall(pattern, source, re.M | re.S)
    if not matches and optional:
        return ""
    if len(matches) != 1:
        raise ValueError(f"node-open fixture source drift: {name}: {len(matches)} definitions")
    return matches[0]


def prepare(port, freebsd, template, output):
    """Extract the reviewed open/close chain from matched immutable build inputs.

    The FreeBSD path contains the pinned LinuxKPI headers. Its fput/_fdrop
    contract must stay synchronized with the port's sys/file.h. This fixture
    tests sequential ownership and callback handoff; native races/GPU execution
    remain outside its scope. Optional old definitions enable negative controls.
    """
    node = (port / "override/src/nmx_linux_cdev.c").read_text(encoding="utf-8")
    compat = (port / "override/src/linux_compat.c").read_text(encoding="utf-8")
    metadata = (port / "override/src/nmx_drm_os.c").read_text(encoding="utf-8")
    header = (port / "bsdcompat/include/sys/file.h").read_text(encoding="utf-8")
    lkpi = freebsd / "sys/compat/linuxkpi/common/include/linux"
    fs = (lkpi / "fs.h").read_text(encoding="utf-8")
    file_header = (lkpi / "file.h").read_text(encoding="utf-8")
    final_macro = re.findall(r"^#define _fdrop\([^\n]+", header, re.M)
    if len(final_macro) != 1:
        raise ValueError("one final-drop macro required")
    has_final = "nmx_file_final_drop(" in node
    pieces = ["#define NMX_HAVE_FINAL_DROP 1" if has_final else "", final_macro[0],
              definition(fs, "get_file"), definition(file_header, "file_count"),
              definition(compat, "linux_file_free"), definition(file_header, "fput"),
              definition(compat, "linux_iminor"), definition(compat, "linux_dev_fdopen"),
              definition(compat, "linux_file_close"),
              definition(node, "nmx_node_file", structure=True, optional=True),
              definition(node, "nmx_open", structure=True)]
    table = re.findall(r"^#define OPEN_BUCKETS[^\n]*\n.*?^MTX_SYSINIT[^\n]+", node, re.M | re.S)
    if len(table) != 1:
        raise ValueError("one actual open table required")
    pieces.append(table[0])
    for name in ["open_find", "enter", "leave", "devfs_set_cdevpriv", "devfs_get_cdevpriv", "devfs_clear_cdevpriv",
                 "nmx_cdev_open", "nmx_file_final_drop", "fdrop", "nmx_cdev_close", "nmx_cdev_ioctl"]:
        pieces.append(definition(node, name, optional=name == "nmx_file_final_drop"))
    pieces.append(definition(metadata, "nmx_drm_node_identity"))
    value = template.read_text(encoding="utf-8")
    marker = "/* NMX_ACTUAL_NODE_OPEN_IMPLEMENTATION */"
    if value.count(marker) != 1:
        raise ValueError("one node-open implementation marker required")
    output.write_text(value.replace(marker, "\n\n".join(pieces)), encoding="utf-8", newline="\n")
    print(f"Extracted actual native node open/file-drop path: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, type=Path)
    parser.add_argument("--freebsd", required=True, type=Path)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.port, args.freebsd, args.template, args.output)
