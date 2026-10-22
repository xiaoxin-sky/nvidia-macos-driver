"""Join Linux mutex/rwsem/WW/IDR and native CV/locking to the i915 CSB fallback.

The harness models Mach/IOKit mutex primitives, CPU identity, MMIO and the
bounded polling timer. Native owner bookkeeping, BH nesting, critical scopes,
Linux lock/WW/CV paths, IDR preload, CSB fallback and uncore lock macros are
production source. C allocation casts and the Windows GNU-expression wrapper
are representation changes only; native clang keeps the original GNU macro.
This checks context/lifetime contracts and never claims GPU execution.
"""
import argparse
from pathlib import Path
import re


def definition(source, name):
    """Extract a single top-level C function and reject source-shape drift."""
    pattern = rf'^(?:static\s+)?(?:inline\s+)?(?:noinline\s+)?(?:struct \w+\s*\*|void\s*\*|void|int|unsigned|u64|bool|uintptr_t)\s*{name}\([^;{{}}]*\)\n\{{\n.*?^\}}'
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
    Shared/exclusive locks preserve atomic downgrade in the primitive model.
    IDR radix-tree operations are not simulated: the changed preload/get/free
    ownership path is extracted; full tree compilation remains a kernel check.
    WW waits run through the actual CV adapter and actual generic release/
    reacquire, using host Mach wait primitives and intrusive-list storage.
    """
    kernel = (port / 'bsdcompat/src/nmx_kernel.c').read_text(encoding='utf-8')
    locks = (port / 'bsdcompat/src/nmx_lock.c').read_text(encoding='utf-8')
    tasklet = (port / 'override/src/linux_tasklet.c').read_text(encoding='utf-8')
    spin = (freebsd / 'sys/compat/linuxkpi/common/include/linux/spinlock.h').read_text(encoding='utf-8')
    uncore = (drm / 'drivers/gpu/drm/i915/intel_uncore.c').read_text(encoding='utf-8')
    execlists = (drm / 'drivers/gpu/drm/i915/gt/intel_execlists_submission.c').read_text(encoding='utf-8')
    sx = (port / 'bsdcompat/include/sys/sx.h').read_text(encoding='utf-8')
    rw = (port / 'bsdcompat/include/sys/rwlock.h').read_text(encoding='utf-8')
    mutex = (freebsd / 'sys/compat/linuxkpi/common/include/linux/mutex.h').read_text(encoding='utf-8')
    rwsem = (freebsd / 'sys/compat/linuxkpi/common/include/linux/rwsem.h').read_text(encoding='utf-8')
    idr = (port / 'override/src/linux_idr.c').read_text(encoding='utf-8')
    idr_h = (freebsd / 'sys/compat/linuxkpi/common/include/linux/idr.h').read_text(encoding='utf-8')
    lock_h = (port / 'bsdcompat/include/sys/lock.h').read_text(encoding='utf-8')
    mtx_h = (port / 'bsdcompat/include/sys/_mutex.h').read_text(encoding='utf-8')
    mtx_api = (port / 'bsdcompat/include/sys/mutex.h').read_text(encoding='utf-8')
    condvar = (port / 'bsdcompat/include/sys/condvar.h').read_text(encoding='utf-8')
    sleep = (port / 'bsdcompat/src/nmx_sleep.c').read_text(encoding='utf-8')
    ww_h = (freebsd / 'sys/compat/linuxkpi/common/include/linux/ww_mutex.h').read_text(encoding='utf-8')
    ww_c = (freebsd / 'sys/compat/linuxkpi/common/src/linux_lock.c').read_text(encoding='utf-8')
    sched_h = (freebsd / 'sys/compat/linuxkpi/common/include/linux/sched.h').read_text(encoding='utf-8')
    record = re.findall(r'^struct nmx_thread_rec \{\n.*?^\};', kernel, re.M | re.S)
    critical = re.findall(r'^static struct \{ int nest; boolean_t saved; \} nmx_crit\[MAXCPU\];', kernel, re.M)
    if len(record) != 1 or len(critical) != 1:
        raise ValueError('native lock record/CPU critical shape changed')
    pieces = [record[0], 'static thread_local struct nmx_thread_rec fixture_record{};',
              'static struct thread *nmx_curthread() { return &fixture_record.td; }', critical[0]]
    for source, name in [(sx, 'sx'), (rw, 'rwlock')]:
        found = re.findall(rf'^struct {name} \{{\n.*?^\}};', source, re.M | re.S)
        if len(found) != 1:
            raise ValueError(f'native shared-lock layout drift: {name}')
        pieces.append(found[0])
    found = re.findall(r'^struct cv \{\n.*?^\};', condvar, re.M | re.S)
    if len(found) != 1:
        raise ValueError('native CV layout drift')
    pieces.append(found[0])
    pieces += [definition(sx, 'nmx_sx_owner'), definition(rw, 'nmx_rw_owner')]
    pieces += [definition(kernel, n) for n in ['nmx_linux_bh_disable', 'nmx_linux_bh_enable',
               'nmx_linux_bh_depth', 'nmx_critical_enter', 'nmx_critical_exit', 'nmx_in_critical',
               'nmx_idr_preload_get', 'nmx_idr_preload_set']]
    pieces += [definition(tasklet, n) for n in ['local_bh_disable', 'local_bh_enable']]
    pieces += [definition(locks, n) for n in ['lock_object_init', 'mtx_init', 'mtx_destroy',
               'mtx_check', 'nmx_mtx_lock', 'nmx_mtx_trylock', 'nmx_mtx_unlock',
               'nmx_mtx_owned', 'nmx_mtx_recursed']]
    pieces += [definition(locks, n) for n in ['sx_init_flags', 'sx_destroy', 'sx_check',
               'nmx_sx_xlock', 'nmx_sx_xlock_sig', 'nmx_sx_xunlock', 'nmx_sx_slock',
               'nmx_sx_slock_sig', 'nmx_sx_sunlock', 'nmx_sx_try_xlock', 'nmx_sx_try_slock',
               'nmx_sx_try_upgrade', 'nmx_sx_downgrade', 'nmx_sx_xlocked', 'nmx_sx_has_waiters',
               'nmx_sx_unlock', 'rw_init_flags', 'rw_destroy', 'rw_check', 'nmx_rw_rlock',
               'nmx_rw_runlock', 'nmx_rw_wlock', 'nmx_rw_wunlock', 'nmx_rw_try_rlock',
               'nmx_rw_try_wlock', 'nmx_rw_try_upgrade', 'nmx_rw_downgrade', 'nmx_rw_wowned',
               'nmx_rw_unlock']]
    pieces += [macro(locks, 'HOW_SHARED'), definition(locks, 'nmx_lock_release'),
               definition(locks, 'nmx_lock_reacquire')]
    pieces += [definition(sleep, n) for n in ['result_to_errno', 'cv_init', 'cv_destroy',
               'cv_wait_common', '_cv_wait', '_cv_wait_sig', 'cv_signal']]
    pieces += [macro(spin, n) for n in ['spin_lock', 'spin_unlock', 'spin_lock_irqsave',
                                      'spin_unlock_irqrestore']]
    values = {'/* ACTUAL_NATIVE_LOCK_IMPLEMENTATION */': '\n\n'.join(pieces)}
    layout_parts = []
    for source, pattern in [(lock_h, r'^enum nmx_lock_class \{\n.*?^\};'),
                            (lock_h, r'^struct lock_object \{\n.*?^\};'),
                            (mtx_h, r'^struct mtx \{\n.*?^\};')]:
        found = re.findall(pattern, source, re.M | re.S)
        if len(found) != 1:
            raise ValueError('native lock base layout drift')
        layout_parts.append(found[0])
    layout_parts += [macro(lock_h, n) for n in ['LO_INITIALIZED', 'LO_RECURSABLE', 'LO_SLEEPABLE', 'LO_UPGRADABLE']]
    layout_parts += [macro(mtx_api, n) for n in ['MTX_DEF', 'MTX_SPIN', 'MTX_RECURSE', 'MTX_NOWITNESS', 'MTX_NEW']]
    layout_parts += [macro(sx, n) for n in ['SX_RECURSE', 'SX_NOWITNESS']]
    layout_parts += [macro(rw, 'RW_RECURSE')]
    values['/* ACTUAL_NATIVE_LOCK_LAYOUTS */'] = '\n\n'.join(layout_parts)
    upper = []
    for source, pattern in [(mutex, r'^typedef struct mutex \{\n.*?^\} mutex_t;'),
                            (rwsem, r'^struct rw_semaphore \{\n.*?^\};')]:
        found = re.findall(pattern, source, re.M | re.S)
        if len(found) != 1:
            raise ValueError('native Linux mutex/rwsem shape changed')
        upper.append(found[0])
    upper += [macro(sx, n) for n in ['sx_xholder', 'sx_xlocked', 'sx_xlock', 'sx_xunlock',
              'sx_slock', 'sx_sunlock', 'sx_try_xlock', 'sx_try_slock', 'sx_downgrade']]
    upper += [definition(mutex, n) for n in ['mutex_is_locked', 'mutex_is_owned']]
    upper += [definition(rwsem, 'linux_init_rwsem')]
    upper += [macro(rwsem, n) for n in ['down_write', 'up_write', 'down_read', 'up_read',
              'down_read_trylock', 'down_write_trylock', 'downgrade_write']]
    values['/* ACTUAL_LINUX_SHARED_LOCK_ACCESSORS */'] = '\n\n'.join(upper)
    ww_parts = [macro(condvar, n) for n in ['cv_wait', 'cv_wait_sig']]
    ww_parts += [macro(mutex, n) for n in ['mutex_unlock', 'mutex_destroy']]
    try_macro = macro(mutex, 'mutex_trylock')
    cpp_try = try_macro.replace('({', '([&]() { return ', 1)
    cpp_try = cpp_try.rsplit('})', 1)[0] + '}())'
    ww_parts += ['#ifdef _MSC_VER\n' + cpp_try + '\n#else\n' + try_macro + '\n#endif']
    ww_parts += [definition(mutex, n) for n in ['linux_mutex_init', 'linux_mutex_destroy']]
    for source, name in [(ww_h, 'ww_class'), (ww_h, 'ww_acquire_ctx'),
                         (ww_h, 'ww_mutex'), (ww_c, 'ww_mutex_thread')]:
        found = re.findall(rf'^struct {name} \{{\n.*?^\}};', source, re.M | re.S)
        if len(found) != 1:
            raise ValueError(f'WW layout drift: {name}')
        ww_parts.append(found[0])
    ww_parts += ['static TAILQ_HEAD(, ww_mutex_thread) ww_mutex_head;',
                 'static struct mtx ww_mutex_global;']
    ww_parts += [definition(sched_h, 'linux_schedule_save_interrupt_value')]
    ww_parts += [definition(ww_c, n) for n in ['linux_ww_init', 'linux_ww_uninit',
                 'linux_ww_lock', 'linux_ww_unlock']]
    if re.search(r'^static bool\s+linux_ww_would_deadlock\(', ww_c, re.M):
        ww_parts.append(definition(ww_c, 'linux_ww_would_deadlock'))
    ww_parts += [definition(ww_c, n) for n in ['linux_ww_mutex_lock_sub', 'linux_ww_mutex_unlock_sub']]
    ww_parts += [definition(ww_h, n) for n in ['ww_mutex_lock', 'ww_mutex_lock_interruptible',
                 'ww_mutex_unlock', 'ww_mutex_init', 'ww_mutex_destroy']]
    # Select the actual >=51600 signature used by this port; retain its body.
    tries = re.findall(r'ww_mutex_trylock\(struct ww_mutex \*lock, struct ww_acquire_ctx \*ctx\)\n#else\n.*?#endif\n(\{\n.*?^\})', ww_h, re.M | re.S)
    if len(tries) != 1:
        raise ValueError('WW trylock target signature drift')
    ww_parts.append('static inline int ww_mutex_trylock(struct ww_mutex *lock, struct ww_acquire_ctx *ctx)\n' + tries[0])
    values['/* ACTUAL_WW_WAIT_PATH */'] = '\n\n'.join(ww_parts)
    idr_parts = [macro(idr_h, n) for n in ['IDR_BITS', 'IDR_SIZE', 'MAX_IDR_SHIFT']]
    idr_parts += [macro(idr, n) for n in ['MAX_IDR_LEVEL', 'MAX_IDR_FREE']]
    for source, name in [(idr_h, 'idr_layer'), (idr_h, 'idr'), (idr, 'linux_idr_cache')]:
        found = re.findall(rf'^struct {name} \{{\n.*?^\}};', source, re.M | re.S)
        if len(found) != 1:
            raise ValueError(f'IDR layout drift: {name}')
        idr_parts.append(found[0])
    idr_parts += [definition(idr, n) for n in ['idr_preload_dequeue_locked', 'idr_preload',
                  'idr_preload_end', 'idr_preload_dequeue_current', 'idr_free_list_get', 'idr_get']]
    idr_code = '\n\n'.join(idr_parts)
    # C's implicit void* conversions only: preserve every ownership branch.
    idr_code = idr_code.replace('lic = malloc(', 'lic = (struct linux_idr_cache *)malloc(')
    idr_code = idr_code.replace('cacheval = malloc(', 'cacheval = (struct idr_layer *)malloc(')
    idr_code = idr_code.replace('(il = malloc(', '(il = (struct idr_layer *)malloc(')
    idr_code = idr_code.replace('struct linux_idr_cache *lic = nmx_idr_preload_get();',
                                 'struct linux_idr_cache *lic = (struct linux_idr_cache *)nmx_idr_preload_get();')
    values['/* ACTUAL_IDR_PRELOAD */'] = idr_code
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
