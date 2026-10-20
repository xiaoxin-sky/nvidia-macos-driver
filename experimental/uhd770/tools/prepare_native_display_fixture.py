"""Extract native display methods into a userspace IOFramebuffer ABI fixture.

Use actual production method bodies; the fixture replaces Apple types/services
only. This checks native state/mode/DDC/notification behavior, not Apple framework
internals, real workloop ordering or hardware. CI still compiles against Apple's
real headers and resolves actual kernel symbols independently.
"""
import argparse
from pathlib import Path


def prepare(source_path, template_path, output_path):
    """Extract uniquely named multiline class methods with the pinned brace style."""
    source = source_path.read_text(encoding="utf-8")
    names = [
        "static void connectFire(", "void acceptState(", "bool copyMode(",
        "static uint32_t refresh16(", "IOReturn refreshDisplayState(",
        "IOItemCount getDisplayModeCount(", "IOReturn getDisplayModes(",
        "IOReturn getInformationForDisplayMode(", "IOReturn getPixelInformation(",
        "IOReturn getCurrentDisplayMode(", "IOReturn getTimingInfoForDisplayMode(",
        "IOReturn setDisplayMode(", "bool hasDDCConnect(", "IOReturn getDDCBlock(",
        "IOReturn getAttributeForConnection(",
        "IOReturn connectFlags(",
    ]
    bodies = []
    for signature in names:
        anchor = "    " + signature
        assert source.count(anchor) == 1, signature
        start = source.index(anchor)
        end = source.index("\n    }\n", start) + 7
        bodies.append(source[start:end].replace(" override", ""))
    template = template_path.read_text(encoding="utf-8")
    marker = "/* NMX_NATIVE_DISPLAY_METHODS */"
    assert template.count(marker) == 1
    output_path.write_text(template.replace(marker, "\n".join(bodies)), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("template", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    prepare(args.source, args.template, args.output)
