"""Build a host-only PCI iterator fixture from the function actually patched.

The fixture substitutes IOKit object discovery, not the PCI filtering code. It
checks iteration, continuation, missing devices and allocation failures; it does
not validate real PCI configuration reads, driver loading or hardware behavior.
"""

import argparse
from pathlib import Path


def prepare(source_path, template_path, output_path):
    """Insert the unique native lookup implementation into the reviewed fixture.

    The pinned source uses column-zero function braces. Reject a missing or
    repeated signature/placeholder rather than silently testing another body.
    """
    source = source_path.read_text(encoding="utf-8")
    signature = 'extern "C" void *nmx_xnu_pci_find_class('
    assert source.count(signature) == 1
    start = source.index(signature)
    end = source.index("\n}\n", start) + 3
    template = template_path.read_text(encoding="utf-8")
    marker = "/* NMX_NATIVE_FUNCTION */"
    assert template.count(marker) == 1
    output_path.write_text(template.replace(marker, source[start:end]), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("template", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    prepare(args.source, args.template, args.output)
