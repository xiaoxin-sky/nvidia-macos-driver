"""Join the actual kernel-mapping helpers to the actual device-mapping registry.

The fixture executes the pinned port's own vmmap registration, both rollback
paths and both native release paths. Only allocators, mutexes, list primitives
and the IOKit primitives are modelled; the function bodies are copied verbatim
and any drift in their anchors fails preparation instead of silently testing
something else.
"""

import argparse
from pathlib import Path
import re

MARKER = "/* NMX_ACTUAL_PAGE_MAP_IMPLEMENTATION */"

PAGE_FUNCTIONS = [
    "is_vmalloc_addr",
    "vmmap_add",
    "vmmap_remove",
    "_ioremap_attr",
    "iounmap",
    "vmap",
    "linuxkpi_vmap_pfn",
    "vunmap",
]


def slice_between(source, start_anchor, end_anchor):
    """Return the text from start_anchor through the end of end_anchor."""
    assert source.count(start_anchor) == 1, (start_anchor, source.count(start_anchor))
    assert source.count(end_anchor) == 1, (end_anchor, source.count(end_anchor))
    start = source.index(start_anchor)
    end = source.index(end_anchor, start) + len(end_anchor)
    return source[start:end]


def _definition_at(source, name):
    """Locate the one definition of name, ignoring calls and declarations."""
    hits = []
    for match in re.finditer(r"(?<![\w])" + re.escape(name) + r"\(", source):
        close = source.index(")", match.start())
        if re.match(r"\)\n\{\n", source[close:close + 4]):
            hits.append(match.start())
    if len(hits) != 1:
        raise ValueError(f"page-map fixture drift: {name}: {len(hits)} definitions")
    return hits[0]


def function(source, name):
    """Read one actual C function body, including a return type on its own line.

    The declaration may be `void *name(...)` or `void *` on the previous line,
    which both appear in these two port files.
    """
    at = _definition_at(source, name)
    start = source.rfind("\n", 0, at) + 1
    while start > 0:
        previous = source.rfind("\n", 0, start - 1) + 1
        line = source[previous:start].strip()
        if not line or line.startswith("#") or line.startswith("/*") or line.endswith("*/"):
            break
        if line.endswith(";") or line.endswith("}") or line.endswith("{"):
            break
        start = previous
    end = source.index("\n}\n", at) + 3
    return source[start:end]


def strip_arch_guards(text):
    """Drop the architecture guard *lines* around code the kernel compiles on x86_64.

    Only the two directive lines go away; the statements they guard stay, because
    they are the ones this fixture has to execute. The guards test FreeBSD/GCC
    macros such as __amd64__, which the extracted text's host compiler (MSVC on
    the Windows side) does not define, so leaving them in would silently compile
    the guarded statements out of the fixture. The kext build uses clang on
    x86_64, which does define __amd64__, so the same statements are compiled
    there -- the fixture is not testing a different code set.
    """
    while True:
        opening = re.search(r"^#if defined\(__i386__\)[^\n]*\n", text, re.M)
        if opening is None:
            break
        head, rest = text[:opening.start()], text[opening.end():]
        closing = re.search(r"^#endif\n", rest, re.M)
        if closing is None:
            raise ValueError("page-map fixture drift: unbalanced architecture guard")
        text = head + rest[:closing.start()] + rest[closing.end():]
    for line in text.splitlines():
        if line.startswith("#"):
            raise ValueError(f"page-map fixture drift: unexpected directive {line!r}")
    return text


# Statements the fixture exists to execute. If the fix is reverted, or the port
# reworks these bodies, preparation fails instead of passing on other code.
MUST_CONTAIN = {
    "vmmap_add": "if (vmmap == NULL)",
    "_ioremap_attr": "pmap_unmapdev(addr, size);",
    "iounmap": "pmap_unmapdev(addr, vmmap->vm_size);",
    "vmap": "nmx_xnu_unmap(handle);",
    "linuxkpi_vmap_pfn": "nmx_xnu_unmap(handle);",
    "vunmap": "nmx_xnu_unmap(vmmap->vm_handle);",
    "pmap_mapdev_attr": "nmx_xnu_map_phys(pa, size, mode, &d->handle)",
    "pmap_unmapdev": "nmx_xnu_unmap(d->handle);",
}


def prepare(port, templates, output):
    """Write the host fixture with the real bodies substituted into its marker."""
    page = (port / "override/src/linux_page.c").read_text(encoding="utf-8")
    native = (port / "bsdcompat/src/nmx_page.c").read_text(encoding="utf-8")

    # The two registries. Their mutexes stay in the fixture so it owns the host
    # synchronisation; the lists themselves are the actual declarations.
    devmap_state = slice_between(native, "struct devmap {", "static struct devmap *devmaps;")
    vmmap_state = slice_between(page, "struct vmmap {", "static struct vmmaphd vmmaphead[VMMAP_HASH_SIZE];")

    bodies = {}
    for name in ("pmap_mapdev_attr", "pmap_unmapdev"):
        bodies[name] = strip_arch_guards(function(native, name))
    for name in PAGE_FUNCTIONS:
        bodies[name] = strip_arch_guards(function(page, name))

    for name, needle in MUST_CONTAIN.items():
        if needle not in bodies[name]:
            raise ValueError(f"page-map fixture drift: {name} lost {needle!r}")

    pieces = [devmap_state, bodies["pmap_mapdev_attr"], bodies["pmap_unmapdev"], vmmap_state]
    pieces += [bodies[name] for name in PAGE_FUNCTIONS]

    template = (templates / "page_map_fixture.c.in").read_text(encoding="utf-8")
    assert template.count(MARKER) == 1
    output.write_text(template.replace(MARKER, "\n\n".join(pieces)), encoding="utf-8", newline="\n")
    print(f"Prepared kernel mapping registration/rollback fixture: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, type=Path)
    parser.add_argument("--templates", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.port, args.templates, args.output)
