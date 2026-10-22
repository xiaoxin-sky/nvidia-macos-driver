"""Insert the actual i915 ring space/wrap code into a host fixture.

Both the C file and the header carry executed bodies: intel_ring_update_space
and intel_ring_begin from gt/intel_ring.c, and the inline space/offset/tail
helpers from gt/intel_ring.h. Only the request wait (wait_for_space) and the
request's timeline accessor are modelled, because the real ones sleep on a
GPU fence; every arithmetic path that decides where a packet lands and how
much space it consumes runs unchanged.
"""

import argparse
from pathlib import Path
import re

MARKER = "/* NMX_ACTUAL_RING_IMPLEMENTATION */"

FROM_C = ["intel_ring_update_space", "intel_ring_begin"]
FROM_H = [
    "intel_ring_advance",
    "intel_ring_wrap",
    "intel_ring_direction",
    "intel_ring_offset_valid",
    "intel_ring_offset",
    "assert_ring_tail_valid",
    "intel_ring_set_tail",
    "__intel_ring_space",
]

# Statements the fixture exists to execute. If the ring rework loses one of
# them, preparation fails instead of passing on different code.
MUST_CONTAIN = {
    "intel_ring_begin": "ring->space -= need_wrap;",
    "intel_ring_offset": "return intel_ring_wrap(rq->ring, offset);",
    "__intel_ring_space": "& (size - 1)",
}


def _definition_at(source, name):
    hits = []
    for match in re.finditer(r"(?<![\w])" + re.escape(name) + r"\(", source):
        close = source.index(")", match.start())
        if re.match(r"\)\n\{\n", source[close:close + 4]):
            hits.append(match.start())
    if len(hits) != 1:
        raise ValueError(f"ring fixture drift: {name}: {len(hits)} definitions")
    return hits[0]


def function(source, name):
    """Read one definition, including a return type on its own line."""
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


def prepare(drm, templates, output):
    """Write the host fixture with the real bodies substituted into its marker."""
    c = (drm / "gt/intel_ring.c").read_text(encoding="utf-8")
    h = (drm / "gt/intel_ring.h").read_text(encoding="utf-8")

    bodies = {}
    for name in FROM_C:
        bodies[name] = function(c, name)
    for name in FROM_H:
        bodies[name] = function(h, name)

    for name, needle in MUST_CONTAIN.items():
        if needle not in bodies[name]:
            raise ValueError(f"ring fixture drift: {name} lost {needle!r}")

    pieces = [bodies[name] for name in
              ("intel_ring_wrap", "intel_ring_direction", "intel_ring_offset_valid",
               "assert_ring_tail_valid", "intel_ring_set_tail", "__intel_ring_space",
               "intel_ring_update_space", "intel_ring_offset", "intel_ring_advance",
               "intel_ring_begin")]

    template = (templates / "ring_space_fixture.c.in").read_text(encoding="utf-8")
    assert template.count(MARKER) == 1
    output.write_text(template.replace(MARKER, "\n\n".join(pieces)), encoding="utf-8", newline="\n")
    print(f"Prepared i915 ring space/wrap fixture: {output}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--drm", required=True, type=Path)
    parser.add_argument("--templates", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    prepare(args.drm, args.templates, args.output)
