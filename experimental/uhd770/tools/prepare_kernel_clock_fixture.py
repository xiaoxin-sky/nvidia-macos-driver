"""Validate the real LinuxKPI clock through the actual Darwin time adapter.

Native timer/calendar primitives are modeled independently so wall-clock steps
cannot accidentally masquerade as monotonic progress. On clang the actual i915
atomic wait macro is also executed, including migration and timeout branches.
"""
import argparse
from pathlib import Path
import re

from prepare_native_lock_fixture import macro


def definition(text, name):
    """Extract one complete native/inline clock definition without replacing it."""
    pattern = rf'^(?:static\s+)?(?:inline\s+)?(?:uint64_t|void|int)\s+{name}\([^;{{}}]*\)\n\{{\n.*?^\}}'
    found = re.findall(pattern, text, re.M | re.S)
    if len(found) != 1:
        raise ValueError(f'clock fixture drift: {name}: {len(found)}')
    return found[0]


def prepare(port, freebsd, drm, template, output):
    """Join Linux local_clock, native uptime and real polling macro branches.

    Windows compiles the real clock/adapter chain only; its C++ compiler cannot
    parse the driver's GNU statement expressions. Native macOS compiles and
    executes those expressions without any algorithm substitution.
    """
    lower = (port / 'bsdcompat/src/nmx_time.c').read_text(encoding='utf-8')
    upper = (freebsd / 'sys/compat/linuxkpi/common/include/linux/sched.h').read_text(encoding='utf-8')
    wait = (drm / 'drivers/gpu/drm/i915/i915_utils.h').read_text(encoding='utf-8')
    actual = '\n\n'.join(definition(lower, n) for n in ['uptime_ns', 'nanouptime', 'nanotime'])
    actual += '\n\n' + definition(upper, 'local_clock')
    actual += '\n#ifndef _MSC_VER\n' + macro(wait, '_wait_for_atomic') + '\n#endif\n'
    pcode = (drm / 'drivers/gpu/drm/i915/intel_pcode.c').read_text(encoding='utf-8')
    pcode_body = '\n\n'.join(macro(wait, n) for n in ['__wait_for', '_wait_for'])
    pcode_body += '\n\n' + definition(pcode, 'skl_pcode_request')
    value = template.read_text(encoding='utf-8')
    marker = '/* ACTUAL_KERNEL_CLOCK_CHAIN */'
    if value.count(marker) != 1:
        raise ValueError('clock fixture marker count')
    value = value.replace(marker, actual)
    marker = '/* ACTUAL_PCODE_RETRY */'
    if value.count(marker) != 1:
        raise ValueError('PCODE fixture marker count')
    output.write_text(value.replace(marker, pcode_body), encoding='utf-8', newline='\n')
    print(f'Prepared actual LinuxKPI/native clock and i915 wait: {output}')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for key in ['port', 'freebsd', 'drm', 'template', 'output']:
        p.add_argument('--' + key, required=True, type=Path)
    a = p.parse_args()
    prepare(a.port, a.freebsd, a.drm, a.template, a.output)
