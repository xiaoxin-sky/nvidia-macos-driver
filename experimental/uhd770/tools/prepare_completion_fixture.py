"""Join actual irq-work/taskqueue, i915 breadcrumbs, fence/syncobj and waits.

Hardware IRQ routing/MMIO, HWSP writes, native primitive locks/waits, RCU and
object storage/refcounts remain controlled host boundaries. The completion
predicate and all queue/breadcrumb/callback/syncobj/sleep state machines are
production source. This is software-interface evidence, never GPU proof.
"""
import argparse
from pathlib import Path
import re

from prepare_native_lock_fixture import macro
from prepare_sleep_fixture import prepare as prepare_sleep


def definition(source, name, structure=False):
    """Extract one actual top-level definition and fail on source-shape drift."""
    pattern = (rf'^struct {name} \{{\n.*?^\}};' if structure else
               rf'^(?:__maybe_unused\s+)?(?:static\s+)?(?:inline\s+)?(?:struct \w+\s*\*|signed long|long|int|void|bool|u32)\s*{name}\([^;{{}}]*\)\n\{{\n.*?^\}}')
    found = re.findall(pattern, source, re.M | re.S)
    if len(found) != 1:
        raise ValueError(f'completion source drift: {name}: {len(found)}')
    return found[0]


def prepare(port, freebsd, drm, templates, output):
    """Preserve actual completion code across the Linux/BSD/XNU adapters.

    The prior sleep fixture's native event model is reused and its lock model
    is connected to real host mutexes for the actual queue sleep/reacquire.
    C allocation casts and LP64 long types are represented explicitly for the
    Windows C++ host. RCU lifetime and real HWSP/MMIO/coherence require their
    separate native/target evidence and are not inferred from this fixture.
    """
    output.parent.mkdir(parents=True, exist_ok=True)
    schedule = freebsd / 'sys/compat/linuxkpi/common/src/linux_schedule.c'
    temporary = output.with_suffix('.sleep.cpp')
    prepare_sleep(port, schedule, templates / 'sleep_fixture.cpp.in', temporary)
    sleep = temporary.read_text(encoding='utf-8').split('static void check_clean()')[0]
    sleep = sleep.replace('#include <vector>', '#include <vector>\n#include <deque>\n#include <shared_mutex>\n#include <type_traits>')
    sleep = sleep.replace('struct lock_object { bool held=true;', 'struct lock_object { std::mutex *native=nullptr; bool held=true;')
    sleep = sleep.replace('l->held=false; ++l->released; return 17;',
                          'l->held=false; ++l->released; if(l->native) l->native->unlock(); return 17;')
    sleep = sleep.replace('assert(l && !l->held && how==17); l->held=true;',
                          'assert(l && how==17); if(l->native) l->native->lock(); assert(!l->held); l->held=true;')
    sleep = sleep.replace('static thread_local unsigned held_spins=0, cpu_id=0;',
                          'static thread_local unsigned held_spins=0, cpu_id=0;\nstatic thread_local std::function<void()> before_native_block;')
    sleep = sleep.replace('    ++block_calls;\n', '    if(before_native_block) { auto f=std::move(before_native_block); before_native_block={}; f(); }\n    ++block_calls;\n')
    lower = (port / 'bsdcompat/src/nmx_sleep.c').read_text(encoding='utf-8')
    sleep += '\n' + '\n'.join(definition(lower, n) for n in ['nmx_wakeup', 'nmx_wakeup_one'])

    queue = (port / 'bsdcompat/src/nmx_task.c').read_text(encoding='utf-8')
    task = (port / 'bsdcompat/include/sys/_task.h').read_text(encoding='utf-8')
    q_template = (templates.parent / 'acceleration/workqueue-tests/taskqueue_fixture.cpp.in').read_text(encoding='utf-8')
    q_macros = q_template[q_template.index('#ifdef STAILQ_HEAD'):q_template.index('constexpr int TASK_ENQUEUED')]
    q = q_macros + '\n' + definition(task, 'task', True)
    q += '\n' + '\n'.join(definition(queue, n, True) for n in ['nmx_taskqueue_active', 'taskqueue'])
    q += '\n' + '\n'.join(definition(queue, n) for n in ['taskqueue_thread_enqueue', 'taskqueue_run_locked',
        'taskqueue_run', 'taskqueue_thread_loop', 'enqueue_locked', 'taskqueue_enqueue_flags', 'taskqueue_enqueue',
        'task_is_running', 'taskqueue_drain', 'taskqueue_drain_all', 'taskqueue_free'])
    q = q.replace('free(q, M_TASKQUEUE);', 'completion_queue_free(q);')
    q = q.replace('struct taskqueue **qp = context;', 'struct taskqueue **qp = (struct taskqueue **)context;')
    irq_h = (freebsd / 'sys/compat/linuxkpi/common/include/linux/irq_work.h').read_text(encoding='utf-8')
    irq_c = (freebsd / 'sys/compat/linuxkpi/common/src/linux_work.c').read_text(encoding='utf-8')
    q += '\n' + definition(irq_h, 'irq_work', True)
    q += '\n' + definition(irq_c, 'linux_irq_work_fn')
    q += '\n' + '\n'.join(definition(irq_h, n) for n in ['init_irq_work', 'irq_work_queue', 'irq_work_sync'])
    q = q.replace('struct irq_work *irqw = context;', 'struct irq_work *irqw = (struct irq_work *)context;')

    fence = (drm / 'drivers/dma-buf/dma-fence.c').read_text(encoding='utf-8')
    sync = (drm / 'drivers/gpu/drm/drm_syncobj.c').read_text(encoding='utf-8')
    sync_h = (drm / 'include/drm/drm_syncobj.h').read_text(encoding='utf-8')
    rq_h = (drm / 'drivers/gpu/drm/i915/i915_request.h').read_text(encoding='utf-8')
    bread = (drm / 'drivers/gpu/drm/i915/gt/intel_breadcrumbs.c').read_text(encoding='utf-8')
    completion = '\n'.join(definition(rq_h, n) for n in ['i915_seqno_passed', '__hwsp_seqno', '__i915_request_is_complete'])
    completion += '\n' + '\n'.join(definition(fence, n) for n in ['dma_fence_init', 'dma_fence_signal_timestamp_locked',
         'dma_fence_signal_timestamp', 'dma_fence_signal_locked', 'dma_fence_signal', 'dma_fence_enable_sw_signaling',
         'dma_fence_add_callback', 'dma_fence_remove_callback', 'dma_fence_get', 'dma_fence_put',
         'dma_fence_get_rcu', 'dma_fence_get_rcu_safe', 'dma_fence_is_signaled', 'dma_fence_set_deadline'])
    completion += '\n' + '\n'.join(definition(bread, n) for n in ['__intel_breadcrumbs_arm_irq',
         'intel_breadcrumbs_arm_irq', '__intel_breadcrumbs_disarm_irq', 'intel_breadcrumbs_disarm_irq',
         'add_signaling_context', 'remove_signaling_context', 'check_signal_order', '__dma_fence_signal',
         '__dma_fence_signal__timestamp', '__dma_fence_signal__notify', 'add_retire', 'slist_add',
         'signal_irq_work', 'irq_signal_request', 'insert_breadcrumb', 'i915_request_enable_breadcrumb'])
    completion += '\n' + definition(sync, 'syncobj_wait_entry', True)
    completion += '\n' + definition(sync_h, 'drm_syncobj_fence_get')
    completion += '\n' + '\n'.join(definition(sync, n) for n in ['drm_syncobj_fence_add_wait',
          'drm_syncobj_remove_wait', 'syncobj_wait_fence_func', 'syncobj_wait_syncobj_func',
          'drm_syncobj_array_wait_timeout'])
    completion = re.sub(r'\bsigned long\b', 'int64_t', completion)
    completion = re.sub(r'\blong\b', 'int64_t', completion)
    completion = completion.replace('points = kmalloc_array(', 'points = (uint64_t *)kmalloc_array(')
    completion = completion.replace('entries = kcalloc(', 'entries = (struct syncobj_wait_entry *)kcalloc(')

    enums = (drm / 'linuxkpi/bsd/include/linux/dma-fence.h').read_text(encoding='utf-8')
    bits = re.findall(r'^enum dma_fence_flag_bits \{\n.*?^\};', enums, re.M | re.S)
    rq_bits = re.findall(r'^enum \{\n.*?^\};', rq_h, re.M | re.S)
    if len(bits) != 1 or len(rq_bits) != 1:
        raise ValueError('completion flags drift')
    values = {'/* ACTUAL_SLEEP_CHAIN */': sleep, '/* ACTUAL_QUEUE_IRQWORK */': q,
              '/* ACTUAL_COMPLETION_CHAIN */': completion, '/* ACTUAL_FENCE_FLAGS */': bits[0] + '\n' + rq_bits[0]}
    gt_irq = (drm / 'drivers/gpu/drm/i915/gt/intel_gt_irq.c').read_text(encoding='utf-8')
    gt_h = (drm / 'drivers/gpu/drm/i915/gt/intel_gt_irq.h').read_text(encoding='utf-8')
    engine_h = (drm / 'drivers/gpu/drm/i915/gt/intel_engine_types.h').read_text(encoding='utf-8')
    gt_regs = (drm / 'drivers/gpu/drm/i915/gt/intel_gt_regs.h').read_text(encoding='utf-8')
    regs = (drm / 'drivers/gpu/drm/i915/i915_reg.h').read_text(encoding='utf-8')
    execlists = (drm / 'drivers/gpu/drm/i915/gt/intel_execlists_submission.c').read_text(encoding='utf-8')
    bread_h = (drm / 'drivers/gpu/drm/i915/gt/intel_breadcrumbs.h').read_text(encoding='utf-8')
    defs = [macro(engine_h, n) for n in ['RENDER_CLASS', 'VIDEO_DECODE_CLASS', 'VIDEO_ENHANCEMENT_CLASS',
             'OTHER_CLASS', 'MAX_ENGINE_CLASS', 'MAX_ENGINE_INSTANCE']]
    defs += [macro(gt_regs, n) for n in ['GEN11_INTR_ENGINE_CLASS', 'GEN11_INTR_ENGINE_INSTANCE',
              'GEN11_INTR_ENGINE_INTR', 'OTHER_GSC_HECI_2_INSTANCE', 'OTHER_KCR_INSTANCE', 'OTHER_GSC_INSTANCE']]
    defs += [macro(regs, n) for n in ['GT_WAIT_SEMAPHORE_INTERRUPT', 'GT_CONTEXT_SWITCH_INTERRUPT',
              'GT_CS_MASTER_ERROR_INTERRUPT', 'GT_RENDER_USER_INTERRUPT']]
    values['/* ACTUAL_ENGINE_IRQ_DEFINES */'] = '\n'.join(defs)
    irq = '\n'.join([definition(bread_h, 'intel_engine_signal_breadcrumbs'),
                       definition(execlists, 'execlists_irq_handler'), definition(gt_h, 'intel_engine_cs_irq'),
                       definition(gt_irq, 'pick_gt'), definition(gt_irq, 'gen11_gt_identity_handler')])
    # C identifiers may use "class"; C++ reserves it. Rename the local token
    # without changing bit extraction, engine selection or dispatch branches.
    values['/* ACTUAL_ENGINE_IRQ_DISPATCH */'] = re.sub(r'\bclass\b', 'engine_class_id', irq)
    text = (templates / 'completion_fixture.cpp.in').read_text(encoding='utf-8')
    for marker, value in values.items():
        if text.count(marker) != 1:
            raise ValueError(f'completion marker count: {marker}')
        text = text.replace(marker, value)
    output.write_text(text, encoding='utf-8', newline='\n')
    print(f'Prepared actual IRQ-work/queue/breadcrumb/fence/syncobj/Linux/native sleep chain: {output}')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for key in ['port', 'freebsd', 'drm', 'templates', 'output']:
        p.add_argument('--' + key, type=Path, required=True)
    a = p.parse_args()
    prepare(a.port, a.freebsd, a.drm, a.templates, a.output)
