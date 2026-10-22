"""Join actual Linux mm ownership code to actual native task/copy/wire code.

Two translation units preserve the C/LinuxKPI and C++/IOKit boundary. The host
models allocation/locking/descriptor primitives; publication, owner cleanup and
native task-reference control flow come from the patched pinned sources.
"""
import argparse
from pathlib import Path
import re


def function(source, name):
    """Read one actual named C function while rejecting drift or duplicates."""
    pattern=rf'^(?:static\s+)?(?:inline\s+)?(?:struct \w+\s*\*|int|void|bool)\s*{re.escape(name)}\([^;{{}}]*\)\n\{{\n.*?^\}}'
    found=re.findall(pattern,source,re.M|re.S)
    if len(found)!=1:
        raise ValueError(f'mm fixture drift: {name}: {len(found)} definitions')
    return found[0]


def prepare(port, freebsd, templates, output):
    """Stage matched C/C++ implementations with only native services mocked.

    freebsd supplies the exact mmget/mmput/get_task/put_task inline contracts.
    No graphics device, kernel extension or Mach task is accessed by the fixture.
    Thread-record cleanup and GPU page visibility remain separate audit gates.
    """
    output.mkdir(parents=True,exist_ok=False)
    current=(port/'override/src/linux_current.c').read_text(encoding='utf-8')
    headers=freebsd/'sys/compat/linuxkpi/common/include/linux'
    mm=(headers/'mm_types.h').read_text(encoding='utf-8')
    sched=(headers/'sched.h').read_text(encoding='utf-8')
    owner=re.findall(r'^struct nmx_mm_owner \{\n.*?^\};',current,re.M|re.S)
    assert len(owner)==1
    pieces=[owner[0]]
    pieces += [function(mm,n) for n in ['mmdrop','mmget_not_zero','mmput','mmgrab']]
    pieces += [function(sched,n) for n in ['get_task_struct','put_task_struct']]
    pieces += [function(current,n) for n in ['find_other_mm','linux_alloc_current','linux_get_task_mm',
               'linux_mm_dtor','linux_free_current','linuxkpi_thread_dtor_hook','linux_current_init']]
    value=(templates/'mm_lifetime.c.in').read_text(encoding='utf-8')
    marker='/* NMX_ACTUAL_MM_IMPLEMENTATION */'; assert value.count(marker)==1
    (output/'mm-test.c').write_text(value.replace(marker,'\n\n'.join(pieces)),encoding='utf-8',newline='\n')
    native=(port/'xnu/nmx_mm.cpp').read_text(encoding='utf-8')
    native=re.sub(r'^#include[^\n]*\n','',native,flags=re.M)
    value=(templates/'native_mm_lifetime.cpp.in').read_text(encoding='utf-8')
    marker='/* NMX_ACTUAL_NATIVE_MM_IMPLEMENTATION */'; assert value.count(marker)==1
    (output/'native-mm-test.cpp').write_text(value.replace(marker,native),encoding='utf-8',newline='\n')
    print(f'Prepared combined Linux mm/native task ownership fixture: {output}')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port',required=True,type=Path)
    parser.add_argument('--freebsd',required=True,type=Path)
    parser.add_argument('--templates',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    prepare(args.port,args.freebsd,args.templates,args.output)
