"""Extract the actual native ioctl transport, DRM dispatcher and query layout.

The host fixture supplies only a bounded user-memory model and inert driver
handler. Top-level remapping, permission checks, structure sizing, nested
copyin/out, return conversion and saved file context execute production code.
"""
import argparse
from pathlib import Path
import re


def definition(source, name):
    """Read exactly one complete named function from the pinned source."""
    pattern = rf'^(?:static\s+)?(?:inline\s+)?(?:int|long)\s+{re.escape(name)}\([^;{{}}]*\)\n\{{\n.*?^\}}'
    found = re.findall(pattern, source, re.M | re.S)
    if len(found) != 1:
        raise ValueError(f'ioctl fixture drift: {name}: {len(found)} definitions')
    return found[0]


def prepare(port, drm, template, output):
    """Combine unchanged LinuxKPI and DRM bodies with a native host ABI model.

    The input trees must be the same patched pinned sources used by the kernel
    job. The driver callback is intentionally inert; passing proves transport
    behavior, not i915 QUERY/GEM execution. No system ioctl or GPU is invoked.
    """
    compat = (port / 'override/src/linux_compat.c').read_text(encoding='utf-8')
    core = (drm / 'drivers/gpu/drm/drm_ioctl.c').read_text(encoding='utf-8')
    uapi = (drm / 'include/uapi/drm/i915_drm.h').read_text(encoding='utf-8')
    query = re.findall(r'^struct drm_i915_query \{\n.*?^\};', uapi, re.M | re.S)
    assert len(query) == 1
    opw = re.findall(r'^#define\s+OPW\(fp,td,code\).*?^\}\)', compat, re.M | re.S)
    assert len(opw) == 1
    pieces = [opw[0]]
    pieces += [definition(compat, name) for name in ['linux_remap_address', 'linux_copyin', 'linux_copyout', 'linux_get_error', 'linux_file_ioctl_sub']]
    pieces.append('#define file linux_file')
    pieces += [definition(core, name) for name in ['drm_ioctl_permit', 'drm_ioctl_kernel', 'drm_ioctl']]
    pieces.append('#undef file')
    value = template.read_text(encoding='utf-8')
    for marker, replacement in [('/* NMX_ACTUAL_QUERY_LAYOUT */', query[0]),
                                ('/* NMX_ACTUAL_IOCTL_IMPLEMENTATION */', '\n\n'.join(pieces))]:
        assert value.count(marker) == 1
        value = value.replace(marker, replacement)
    output.write_text(value, encoding='utf-8', newline='\n')
    print(f'Prepared actual LinuxKPI/DRM ioctl transport: {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', required=True, type=Path)
    parser.add_argument('--drm', required=True, type=Path)
    parser.add_argument('--template', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    prepare(args.port, args.drm, args.template, args.output)
