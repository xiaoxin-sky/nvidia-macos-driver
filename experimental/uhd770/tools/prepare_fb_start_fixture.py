"""Check the actual framebuffer start method against its controller contract.

The fixture models the property prerequisite documented by IOFramebuffer's
start/copyController path. It does not substitute for native framework or GPU
execution; the kernel build separately checks the real Apple API declarations.
"""
import argparse
from pathlib import Path


def prepare(source, template, output):
    """Extract the sole production start method without maintaining a copy."""
    text = source.read_text(encoding="utf-8")
    anchor = "    bool start(IOService *provider) override {"
    assert text.count(anchor) == 1
    start = text.index(anchor)
    end = text.index("\n    }\n", start) + 7
    method = text[start:end].replace(" override", "")
    body = template.read_text(encoding="utf-8")
    marker = "/* NMX_FB_START_METHOD */"
    assert body.count(marker) == 1
    output.write_text(body.replace(marker, method), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("template", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    prepare(args.source, args.template, args.output)
