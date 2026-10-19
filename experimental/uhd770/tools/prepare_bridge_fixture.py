"""Insert the actual patched display bridge into its host fault-injection test.

Only include directives are removed: the fixture supplies mock DRM/BSD services
and includes the real boundary header. The production allocation, registration,
mode retry and cleanup functions run unchanged, without loading any GPU code.
"""

import argparse
from pathlib import Path
import re


def prepare(source_path, template_path, output_path):
    """Copy the bridge implementation into one unique host-fixture placeholder.

    Inputs must be the staged pinned bridge after patching and the reviewed host
    template. A missing public entry or duplicate marker fails preparation.
    """
    source = source_path.read_text(encoding="utf-8")
    assert source.count("int nmx_fb_open(") == 1
    assert source.count("void nmx_fb_close(") == 1
    source = re.sub(r"^#include[^\n]*\n", "", source, flags=re.MULTILINE)
    template = template_path.read_text(encoding="utf-8")
    marker = "/* NMX_BRIDGE_IMPLEMENTATION */"
    assert template.count(marker) == 1
    output_path.write_text(template.replace(marker, source), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("template", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    prepare(args.source, args.template, args.output)
