"""Join actual native device callback scopes with actual thread registry/refcounts.

Only allocation, native thread and Linux task services are modeled. Syscall
scope lifetime, registry lookup/install/detach and record references are the
production implementations. Other mm/task semantics have their joined fixture.
"""
import argparse
from pathlib import Path
import re


def definition(text, name):
    """Extract one C/C++ function, failing when its source shape changes."""
    pattern=rf'^(?:static\s+)?(?:struct \w+\s*\*|boolean_t|int|void|unsigned)\s*{name}\([^;{{}}]*\)\n\{{\n.*?^\}}'
    found=re.findall(pattern,text,re.M|re.S)
    if len(found)!=1: raise ValueError(f'thread fixture drift: {name}: {len(found)} definitions')
    return found[0]


def prepare(port, template, output):
    """Compile the native entry-to-registry lifetime path without executing a kext.

    C allocation casts are made explicit for the C++ host compiler. No ownership
    branches are replaced. Kernel-worker and retained-task cases are exercised
    separately from native callback nesting and injected callback errors.
    """
    kernel=(port/'bsdcompat/src/nmx_kernel.c').read_text(encoding='utf-8')
    native=(port/'xnu/nmx_devfs.cpp').read_text(encoding='utf-8')
    record=re.findall(r'^struct nmx_thread_rec \{\n.*?^\};',kernel,re.M|re.S)
    scope=re.findall(r'^class NmxThreadScope \{\n.*?^\};',native,re.M|re.S)
    assert len(record)==len(scope)==1
    pieces=[record[0],'''static struct nmx_thread_rec *nmx_threads[NMX_THREAD_BUCKETS];
static volatile int nmx_thread_count;
static volatile int nmx_detached_threads;''']
    for name in ['nmx_registry_lock','nmx_registry_unlock','bucket_of','nmx_thread_find','nmx_thread_hold',
                 'nmx_thread_put','nmx_thread_install_task','nmx_thread_detach_task','nmx_thread_get',
                 'nmx_curthread','nmx_thread_drop_current','nmx_thread_enter','nmx_thread_leave',
                 'nmx_thread_exit_cleanup','nmx_thread_records','nmx_detached_thread_records','nmx_task_for_tid']:
        pieces.append(definition(kernel,name))
    pieces.append(scope[0])
    for name in ['nmx_open','nmx_close','nmx_ioctl','nmx_read','nmx_select']:
        pieces.append(definition(native,name).replace('dev_t','fixture_dev_t'))
    code='\n\n'.join(pieces).replace('= IOMallocZero(sizeof(*nr));','= (struct nmx_thread_rec *)IOMallocZero(sizeof(*nr));')
    value=template.read_text(encoding='utf-8');marker='/* NMX_ACTUAL_THREAD_IMPLEMENTATION */'
    assert value.count(marker)==1
    output.write_text(value.replace(marker,code),encoding='utf-8',newline='\n')
    print(f'Prepared actual native device/thread lifetime fixture: {output}')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--port',required=True,type=Path)
    p.add_argument('--template',required=True,type=Path)
    p.add_argument('--output',required=True,type=Path)
    a=p.parse_args();prepare(a.port,a.template,a.output)
