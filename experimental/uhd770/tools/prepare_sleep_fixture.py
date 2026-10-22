"""Extract the fence-facing Linux schedule path and actual XNU wait adapter.

The test replaces only XNU primitives with a deterministic host event model.
Linux state transitions, sleepqueue locking, deadline conversion, wait result
handling and cleanup are compiled from the matched kernel sources.
"""
import argparse
from pathlib import Path
import re


def definition(source, name, structure=False):
    """Extract one column-zero C definition and reject ambiguous source drift."""
    pattern = (rf'^struct {name} \{{\n.*?^\}};' if structure else
               rf'^(?:static\s+)?(?:struct \w+\s*\*|int|void|uint64_t|u_int|long)\s*{name}\([^;{{}}]*\)\n\{{\n.*?^\}}')
    matches = re.findall(pattern, source, re.M | re.S)
    if len(matches) != 1:
        raise ValueError(f'sleep fixture source drift: {name}: {len(matches)} matches')
    return matches[0]


def prepare(port, schedule, template, output):
    """Combine actual lower/upper wait code against host-only event primitives.

    schedule is linux_schedule.c from the pinned FreeBSD dependency. The only
    source adaptation is LP64 long width for Windows' LLP64 host compiler. The
    fixture verifies wait/interrupt ordering; it does not simulate a GPU IRQ.
    """
    lower = (port / 'bsdcompat/src/nmx_sleep.c').read_text(encoding='utf-8')
    upper = schedule.read_text(encoding='utf-8')
    pieces = [definition(lower, name) for name in ['result_to_errno', 'ticks_deadline', 'sbt_deadline',
              'nmx_sleep', 'pause_sbt', 'cv_wait_common']]
    for name in ['SC_TABLESIZE', 'SC_WAITERS']:
        found = re.findall(rf'^#define {name}[^\n]*', lower, re.M)
        assert len(found) == 1
        pieces.append(found[0])
    pieces += [definition(lower, 'sleepq_chain', True), definition(lower, 'sleepq_pending', True),
               'static struct sleepq_chain sc_table[SC_TABLESIZE];',
               'static struct sleepq_pending sq_pending[MAXCPU];']
    pieces += [definition(lower, name) for name in ['sc_lookup', 'nmx_sleepq_init', 'nmx_sleepq_fini',
               'sleepq_lock', 'sleepq_release', 'sc_count', 'sleepq_add', 'sleepq_set_timeout_sbt',
               'sleepq_block', 'sleepq_wait', 'sleepq_wait_sig', 'sleepq_timedwait', 'sleepq_timedwait_sig',
               'sleepq_sleepcnt', 'sleepq_signal']]
    pieces += [definition(upper, name) for name in ['linux_jiffies_timeout_to_ticks',
               'linux_add_to_sleepqueue', 'wake_up_task', 'linux_schedule_timeout']]
    implementation = '\n\n'.join(pieces)
    implementation = re.sub(r'\blong\b', 'int64_t', implementation)
    value = template.read_text(encoding='utf-8')
    marker = '/* NMX_ACTUAL_SLEEP_IMPLEMENTATION */'
    assert value.count(marker) == 1
    output.write_text(value.replace(marker, implementation), encoding='utf-8', newline='\n')
    print(f'Prepared real Linux schedule/XNU wait path: {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True, type=Path)
    parser.add_argument('--schedule', required=True, type=Path)
    parser.add_argument('--template', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    prepare(args.port, args.schedule, args.template, args.output)
