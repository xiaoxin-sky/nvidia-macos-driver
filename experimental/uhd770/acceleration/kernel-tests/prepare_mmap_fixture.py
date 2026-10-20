"""Extract the actual pinned i915 and node mapping lifecycle for host checks.

Only the kernel services are mocked. Mapping scope, persistent pin callbacks,
fault/population ordering, failed setup, unmap and file-close cleanup execute
the generated port's own function bodies.
"""

import argparse
import pathlib
import re


def definition(text, name, structure=False):
    """Read one column-zero C definition, rejecting source shape drift."""
    if structure:
        pattern = rf"^struct {re.escape(name)} \{{\n.*?^\}};"
    else:
        pattern = rf"^(?:static )?[^;{{}}\n]+\b{re.escape(name)}\([^;{{}}]*\)\n\{{\n.*?^\}}"
    matches = re.findall(pattern, text, re.MULTILINE | re.DOTALL)
    if len(matches) != 1:
        raise SystemExit(f"fixture source drift: {name}: found {len(matches)} definitions")
    return matches[0]


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=pathlib.Path, required=True)
parser.add_argument("--template", type=pathlib.Path, required=True)
parser.add_argument("--output", type=pathlib.Path, required=True)
args = parser.parse_args()
i915 = (args.port / "override/i915/i915_gem_mman.c").read_text(encoding="utf-8")
node = (args.port / "override/src/nmx_linux_cdev.c").read_text(encoding="utf-8")
pieces = [definition(i915, "nmx_i915_mmap_pin"), definition(i915, "vm_close")]
# i915 uses a split return type/name declaration; normalize only its whitespace.
i915 = i915.replace("static int\ni915_gem_object_mmap(", "static int i915_gem_object_mmap(")
pieces.append(definition(i915, "i915_gem_object_mmap"))
pieces.append(definition(node, "nmx_umap", structure=True))
for name in ["umap_of", "nmx_vma_set_pin", "nmx_umap_insert", "umap_populate", "umap_free", "nmx_mmap", "nmx_munmap", "umap_release_all"]:
    pieces.append(definition(node, name))
# Darwin is LP64, whereas MSVC x64 is LLP64. Preserve the target's address
# width in the host model without changing production control flow.
implementation = "\n\n".join(pieces).replace("unsigned long", "uintptr_t")
template = args.template.read_text(encoding="utf-8")
marker = "/* NMX_ACTUAL_MMAP_IMPLEMENTATION */"
if template.count(marker) != 1:
    raise SystemExit("fixture template needs exactly one implementation marker")
args.output.write_text(template.replace(marker, implementation), encoding="utf-8", newline="\n")
print(f"extracted {len(pieces)} actual kernel mapping definitions")
