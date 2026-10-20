"""Extract actual NMX taskqueue scheduling and lifecycle code for host checks.

Only kernel primitives and intrusive queue storage are replaced by the fixture;
active executor tracking, cancellation, drain, worker exit and free ordering
come from the patched source. Reject source-shape drift instead of silently
testing a separate implementation.
"""

import argparse
from pathlib import Path
import re


def definition(source, name, structure=False):
    """Read one column-zero definition from the pinned runtime source."""
    if structure:
        pattern = rf"^struct {re.escape(name)} \{{\n.*?^\}};"
    else:
        pattern = rf"^(?:static )?[^;{{}}\n]+\b{re.escape(name)}\([^;{{}}]*\)\n\{{\n.*?^\}}"
    matches = re.findall(pattern, source, re.MULTILINE | re.DOTALL)
    if len(matches) != 1:
        raise SystemExit(f"fixture source drift: {name}: {len(matches)} definitions")
    return matches[0]


def prepare(port, template, output):
    """Insert production bodies in dependency order into the host ABI shell."""
    source = (port / "bsdcompat/src/nmx_task.c").read_text(encoding="utf-8")
    task_header = (port / "bsdcompat/include/sys/_task.h").read_text(encoding="utf-8")
    pieces = [definition(task_header, "task", structure=True)]
    pieces += [definition(source, name, structure=True) for name in
               ["nmx_taskqueue_active", "taskqueue"]]
    for name in [
        "taskqueue_run_locked", "taskqueue_run", "taskqueue_thread_loop",
        "enqueue_locked", "taskqueue_enqueue_flags", "taskqueue_enqueue",
        "task_is_running", "taskqueue_poll_is_busy", "taskqueue_cancel",
        "taskqueue_drain", "taskqueue_drain_all", "taskqueue_free",
    ]:
        pieces.append(definition(source, name))
    body = template.read_text(encoding="utf-8")
    marker = "/* NMX_ACTUAL_TASKQUEUE_IMPLEMENTATION */"
    if body.count(marker) != 1:
        raise SystemExit("fixture template needs exactly one implementation marker")
    output.write_text(body.replace(marker, "\n\n".join(pieces)),
                      encoding="utf-8", newline="\n")
    print(f"extracted {len(pieces)} actual taskqueue definitions")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=Path, required=True)
    parser.add_argument("--template", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    prepare(args.port, args.template, args.output)
