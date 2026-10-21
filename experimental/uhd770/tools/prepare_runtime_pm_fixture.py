"""Exercise the pinned i915 conditional-wakeref function with actual KPI stubs.

Read the generated flags and production function bodies, then model only i915's
reference bookkeeping. This catches CONFIG_PM accidentally selecting unsupported
FreeBSD runtime-PM APIs; it cannot establish physical device power or suspend.
"""

import argparse
from pathlib import Path
import re


def function_body(text, name):
    """Copy one named production body, including both header-version signatures.

    pm_runtime_get_if_active has two preprocessor-selected signatures followed by
    one shared body. Only that body is needed; no alternative implementation is
    kept in the fixture. Missing or unbalanced input is a source-drift error.
    """
    anchor = text.index(name + "(")
    start = text.index("{", anchor)
    depth = 0
    for offset in range(start, len(text)):
        if text[offset] == "{":
            depth += 1
        elif text[offset] == "}":
            depth -= 1
            if depth == 0:
                return text[start:offset + 1]
    raise ValueError(f"Unbalanced production function: {name}")


def prepare(i915, header, flags, output):
    """Generate a C check from pinned i915/KPI sources and real build flags."""
    enabled = bool(re.search(r"(?m)^-DCONFIG_PM(?:=1)?$", flags.read_text()))
    source = i915.read_text(encoding="utf-8")
    backend = header.read_text(encoding="utf-8")
    text = """#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <errno.h>
#define pr_debug(...) ((void)0)
#define IS_ENABLED(option) (option)
struct device { int unused; };
struct intel_runtime_pm { struct device *kdev; unsigned refs; };
typedef void *intel_wakeref_t;
static void intel_runtime_pm_acquire(struct intel_runtime_pm *rpm, bool wake)
{ assert(wake); rpm->refs++; }
static intel_wakeref_t track_intel_runtime_pm_wakeref(struct intel_runtime_pm *rpm)
{ return rpm; }
"""
    text += f"#define CONFIG_PM {int(enabled)}\n"
    for name in ("pm_runtime_get_if_in_use", "pm_runtime_get_if_active"):
        text += f"static int {name}(struct device *dev)\n"
        body = function_body(backend, name).replace("{", "{\n    (void)dev;", 1)
        text += body + "\n"
    text += "static intel_wakeref_t __intel_runtime_pm_get_if_active(struct intel_runtime_pm *rpm, bool ignore_usecount)\n"
    text += function_body(source, "__intel_runtime_pm_get_if_active") + "\n"
    text += """int main(void) {
    struct device dev = {0};
    struct intel_runtime_pm rpm = {&dev, 0};
    if (!__intel_runtime_pm_get_if_active(&rpm, false) || rpm.refs != 1) return 42;
    if (!__intel_runtime_pm_get_if_active(&rpm, true) || rpm.refs != 2) return 43;
    puts("NMX runtime-PM policy: actual i915 conditional wakerefs retained; no GPU power test");
    return 0;
}
"""
    output.write_text(text, encoding="utf-8", newline="\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("i915", "header", "flags", "output"):
        parser.add_argument(name, type=Path)
    args = parser.parse_args()
    prepare(args.i915, args.header, args.flags, args.output)
