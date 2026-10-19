"""Copy the actual BSD synchronize_irq adapter into a teardown-race fixture."""
import argparse
from pathlib import Path


def prepare(source_path, template_path, output_path):
    """Extract one complete drain function; mocks supply list/IOKit lifetimes."""
    source = source_path.read_text(encoding="utf-8")
    signature = "void _intr_drain("
    assert source.count(signature) == 1
    start = source.index(signature)
    end = source.index("\n}\n", start) + 3
    template = template_path.read_text(encoding="utf-8")
    marker = "/* NMX_IRQ_DRAIN_IMPLEMENTATION */"
    assert template.count(marker) == 1
    output_path.write_text(template.replace(marker, source[start:end]), encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("template", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    prepare(args.source, args.template, args.output)
