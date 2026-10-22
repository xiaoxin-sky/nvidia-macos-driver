"""Exercise actual LinuxKPI tasklet bodies and the i915 inline callers together.

Kernel mutexes, queues and atomics are modeled by the host harness. Tasklet
state transitions, disabled/running behavior and i915 helper definitions come
from the pinned, patched source. This does not execute a GPU or prove IRQ/BH
exclusion on Darwin. --baseline selects the pristine pinned implementation.
"""
import argparse
from pathlib import Path
import re


def prepare(port, freebsd, drm, template, output, baseline=False):
    """Extract the complete tasklet module, retaining all production branches.

    Only include directives are removed; SYSINIT and per-CPU/queue primitives
    are supplied by the harness. The real i915 helpers and inline submission
    flush exercise the caller/callee state contract, not copied algorithms.
    """
    source = freebsd / 'sys/compat/linuxkpi/common/src/linux_tasklet.c'
    override = port / 'override/src/linux_tasklet.c'
    if not baseline:
        if not override.is_file():
            raise ValueError('patched tasklet override is missing')
        source = override
    body = source.read_text(encoding='utf-8')
    body = re.sub(r'^#include[^\n]*\n', '', body, flags=re.M)
    if not baseline:
        body = '#define NMXKPI 1\n' + body
    helpers = (drm / 'drivers/gpu/drm/i915/i915_tasklet.h').read_text(encoding='utf-8')
    helpers = re.sub(r'^#include[^\n]*\n', '', helpers, flags=re.M)
    engine = (drm / 'drivers/gpu/drm/i915/gt/intel_engine_cs.c').read_text(encoding='utf-8')
    flush = re.findall(r'^void __intel_engine_flush_submission\([^;{}]*\)\n\{\n.*?^\}', engine, re.M | re.S)
    if len(flush) != 1:
        raise ValueError('i915 flush source shape changed')
    value = template.read_text(encoding='utf-8')
    for marker, replacement in [('/* ACTUAL_TASKLET_SOURCE */', body),
                                ('/* ACTUAL_I915_HELPERS */', helpers + '\n' + flush[0])]:
        if value.count(marker) != 1:
            raise ValueError(f'fixture marker count: {marker}')
        value = value.replace(marker, replacement)
    output.write_text(value, encoding='utf-8', newline='\n')
    print(f'Prepared actual tasklet/i915 fixture ({source}): {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['port', 'freebsd', 'drm', 'template', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--baseline', action='store_true')
    args = parser.parse_args()
    prepare(args.port, args.freebsd, args.drm, args.template, args.output, args.baseline)
