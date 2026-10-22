"""Join actual BH/critical/native mutex code to the real i915 CSB fallback.

The harness models Mach/IOKit mutex primitives, CPU identity, MMIO and the
bounded polling timer. Native owner bookkeeping, BH nesting, critical scopes,
Linux spin macros, CSB fallback and uncore lock macros are production source.
This checks context/lifetime contracts and never claims GPU execution.
"""
import argparse
from pathlib import Path
import re


def definition(source, name):
    """Extract a single top-level C function and reject source-shape drift."""
    pattern = rf'^(?:static\s+)?(?:noinline\s+)?(?:void|int|unsigned|u64)\s+{name}\([^;{{}}]*\)\n\{{\n.*?^\}}'
    found = re.findall(pattern, source, re.M | re.S)
    if len(found) != 1:
        raise ValueError(f'native lock fixture drift: {name}: {len(found)}')
    return found[0]


def macro(source, name):
    """Read a complete continued macro without reimplementing its operations."""
    lines = source.splitlines()
    starts = [i for i, line in enumerate(lines) if re.match(rf'^#define\s+{name}\b', line)]
    if len(starts) != 1:
        raise ValueError(f'native lock macro drift: {name}: {len(starts)}')
    start = end = starts[0]
    while lines[end].endswith('\\'):
        end += 1
    return '\n'.join(lines[start:end + 1])


def prepare(port, freebsd, drm, template, output):
    """Preserve actual native locking and the transitive register-access route.

    Only the native thread registry is represented by a thread-local record;
    registry ownership/scoped callbacks have a separate actual-source fixture.
    A modeled native mutex rejects acquisition with interrupts disabled, making
    context errors fail even when a particular host run has no contention.
    """
    kernel = (port / 'bsdcompat/src/nmx_kernel.c').read_text(encoding='utf-8')
    locks = (port / 'bsdcompat/src/nmx_lock.c').read_text(encoding='utf-8')
    tasklet = (port / 'override/src/linux_tasklet.c').read_text(encoding='utf-8')
    spin = (freebsd / 'sys/compat/linuxkpi/common/include/linux/spinlock.h').read_text(encoding='utf-8')
    uncore = (drm / 'drivers/gpu/drm/i915/intel_uncore.c').read_text(encoding='utf-8')
    execlists = (drm / 'drivers/gpu/drm/i915/gt/intel_execlists_submission.c').read_text(encoding='utf-8')
    record = re.findall(r'^struct nmx_thread_rec \{\n.*?^\};', kernel, re.M | re.S)
    critical = re.findall(r'^static struct \{ int nest; boolean_t saved; \} nmx_crit\[MAXCPU\];', kernel, re.M)
    if len(record) != 1 or len(critical) != 1:
        raise ValueError('native lock record/CPU critical shape changed')
    pieces = [record[0], 'static thread_local struct nmx_thread_rec fixture_record{};',
              'static struct thread *nmx_curthread() { return &fixture_record.td; }', critical[0]]
    pieces += [definition(kernel, n) for n in ['nmx_linux_bh_disable', 'nmx_linux_bh_enable',
               'nmx_linux_bh_depth', 'nmx_critical_enter', 'nmx_critical_exit', 'nmx_in_critical']]
    pieces += [definition(tasklet, n) for n in ['local_bh_disable', 'local_bh_enable']]
    pieces += [definition(locks, n) for n in ['lock_object_init', 'mtx_init', 'mtx_destroy',
               'mtx_check', 'nmx_mtx_lock', 'nmx_mtx_trylock', 'nmx_mtx_unlock',
               'nmx_mtx_owned', 'nmx_mtx_recursed']]
    pieces += [macro(spin, n) for n in ['spin_lock', 'spin_unlock', 'spin_lock_irqsave',
                                      'spin_unlock_irqrestore']]
    values = {'/* ACTUAL_NATIVE_LOCK_IMPLEMENTATION */': '\n\n'.join(pieces)}
    values['/* ACTUAL_UNCORE_READ_MACROS */'] = '\n\n'.join(macro(uncore, n) for n in
        ['GEN6_READ_HEADER', 'GEN6_READ_FOOTER', '__gen_fwtable_read']) + '\n__gen_fwtable_read(64)\n'
    values['/* ACTUAL_CSB_FALLBACK */'] = definition(execlists, 'wa_csb_read')
    text = template.read_text(encoding='utf-8')
    for marker, value in values.items():
        if text.count(marker) != 1:
            raise ValueError(f'native lock fixture marker: {marker}')
        text = text.replace(marker, value)
    output.write_text(text, encoding='utf-8', newline='\n')
    print(f'Prepared actual BH/native mutex/uncore CSB contract: {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ['port', 'freebsd', 'drm', 'template', 'output']:
        parser.add_argument('--' + key, type=Path, required=True)
    args = parser.parse_args()
    prepare(args.port, args.freebsd, args.drm, args.template, args.output)
