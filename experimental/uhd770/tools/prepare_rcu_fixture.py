"""Stage native concurrency checks from the actual Darwin RCU and CK inputs.

Only OS scheduling/locks are represented by pthread services. The RCU functions
and BSD-licensed CK algorithm are the ones selected by the kernel build. The CK
headers retain their multiprocessor policy; only the kernel-only include guard
in ck_md.h is removed for this userspace executable.
"""
import argparse
from pathlib import Path
import re
import shutil


def function(source, name):
    """Extract exactly one named C definition without changing its control flow."""
    pattern = (r"^(?:static\s+)?(?:void|bool|boolean_t)\s+" + re.escape(name) +
               r"\([^;{}]*\)\n\{\n.*?^\}")
    found = re.findall(pattern, source, re.M | re.S)
    if len(found) != 1:
        raise ValueError(f"RCU fixture drift: {name}: {len(found)} definitions")
    return found[0]


def prepare(port, freebsd, template, output):
    """Copy CK inputs and inject current production RCU/registry functions.

    port is the patched immutable source tree; freebsd is its pinned dependency.
    The destination must be fresh. No kernel, GPU or production device is opened.
    CPU migration and interrupt state are host models; CK grace periods and
    memory reclamation are real concurrent operations.
    """
    output.mkdir(parents=True, exist_ok=False)
    include = output / "include"
    include.mkdir()
    for header in (port / "bsdcompat/include").glob("ck_*.h"):
        shutil.copyfile(header, include / header.name)
    shutil.copytree(port / "bsdcompat/include/gcc", include / "gcc")
    md = include / "ck_md.h"
    text = md.read_text(encoding="utf-8")
    guard = '#ifndef _KERNEL\n#error This header file is meant for the FreeBSD kernel.\n#endif /* _KERNEL */'
    assert text.count(guard) == 1
    md.write_text(text.replace(guard, '/* Native user-space test of the kernel CK policy. */'), encoding="utf-8", newline="\n")
    shutil.copyfile(freebsd / "sys/contrib/ck/src/ck_epoch.c", output / "ck_epoch.c")
    rcu = (port / "override/src/linux_rcu.c").read_text(encoding="utf-8")
    registry = (port / "bsdcompat/src/nmx_kernel.c").read_text(encoding="utf-8")
    assert registry.count('lck_spin_lock(nmx_thread_lock);') == 1
    assert registry.count('lck_spin_unlock(nmx_thread_lock);') == 1
    record = re.findall(r'^struct linux_epoch_record \{.*?^\} __aligned\(CACHE_LINE_SIZE\);', rcu, re.M | re.S)
    assert len(record) == 1
    pieces = [record[0], 'static struct linux_epoch_record linux_epoch_record[RCU_TYPE_MAX];']
    for name in ['linux_rcu_runtime_init', 'linux_rcu_read_lock', 'linux_rcu_read_unlock',
                 'linux_rcu_read_lock_held', 'linux_synchronize_rcu_cb', 'linux_synchronize_rcu',
                 'linux_rcu_cleaner_func', 'linux_call_rcu']:
        pieces.append(function(rcu, name))
    pieces += [function(registry, 'nmx_registry_lock'), function(registry, 'nmx_registry_unlock')]
    value = template.read_text(encoding="utf-8")
    marker = '/* NMX_ACTUAL_RCU_IMPLEMENTATION */'
    assert value.count(marker) == 1
    (output / "rcu-test.c").write_text(value.replace(marker, '\n\n'.join(pieces)), encoding="utf-8", newline="\n")
    print(f"Prepared real CK/Darwin RCU concurrency fixture: {output}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True, type=Path)
    parser.add_argument('--freebsd', required=True, type=Path)
    parser.add_argument('--template', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    prepare(args.port, args.freebsd, args.template, args.output)
