"""Join real Linux S/G, BSD busdma and native IODMACommand adapter bodies.

Only allocator/mutex/flat S/G storage and IOKit services are host primitives.
Mapping addresses, bounds, partial failure rollback and descriptor ownership
execute production code. Device DMA reachability/cache visibility still need
real hardware evidence; these tests never submit GPU work.
"""
import argparse
from pathlib import Path
import re


def definition(text, name, structure=False):
    """Extract one named source definition, rejecting ambiguity or source drift."""
    if structure:
        pattern = rf'^struct {name} \{{\n.*?^\}};'
    else:
        pattern = rf'^(?:extern "C"\s+)?(?:static\s+)?(?:void\s*\*|void|int|bool|bus_dma_tag_t)\s*{name}\([^;{{}}]*\)\n\{{\n.*?^\}}'
    found = re.findall(pattern, text, re.M | re.S)
    if len(found) != 1:
        raise ValueError(f'DMA fixture source drift: {name}: {len(found)}')
    return found[0]


def prepare(port, templates, output):
    """Compile the actual upper mapping/rollback path with the native adapter.

    C and C++ stay separate, preserving real C allocation conversions and the
    shared native C ABI. The harness supplies device/page addresses; it does
    not execute GEM page allocation, GPU page tables or an actual IOMapper.
    """
    output.mkdir(exist_ok=True, parents=True)
    bus = (port / 'bsdcompat/src/nmx_busdma.c').read_text(encoding='utf-8')
    pci = (port / 'override/src/linux_pci.c').read_text(encoding='utf-8')
    native = (port / 'xnu/nmx_dma.cpp').read_text(encoding='utf-8')
    checked = (port / 'bsdcompat/include/nmx_checked_ranges.h').read_text(encoding='utf-8')
    (output / 'nmx_checked_ranges.h').write_text(checked, encoding='utf-8', newline='\n')
    pieces = [definition(bus, 'bus_dma_tag', True), '#define MAP_HANDLES_INLINE 4',
              definition(bus, 'bus_dmamap', True)]
    for name in ['nmx_busdma_root_tag', 'nmx_busdma_root_free', 'bus_dma_tag_create',
                 'bus_dma_tag_destroy', 'bus_dma_id_mapped', 'bus_dmamap_create',
                 'bus_dmamap_destroy', 'map_reserve', 'load_one', '_bus_dmamap_load_phys',
                 'bus_dmamap_unload', 'bus_dmamap_sync']:
        pieces.append(definition(bus, name))
    pieces += [definition(pci, 'linux_dma_priv', True), definition(pci, 'linux_dma_map_sg_attrs'),
               definition(pci, 'linux_dma_unmap_sg_attrs')]
    value = (templates / 'dma_bus_fixture.c.in').read_text(encoding='utf-8')
    marker = '/* ACTUAL_LINUX_BSD_DMA */'
    if value.count(marker) != 1:
        raise ValueError('DMA C fixture marker count')
    (output / 'dma-bus-test.c').write_text(value.replace(marker, '\n\n'.join(pieces)),
                                          encoding='utf-8', newline='\n')
    pieces = [definition(native, 'nmx_dma_map', True)]
    pieces += [definition(native, name) for name in
               ['nmx_xnu_iommu_active', 'nmx_xnu_dma_map', 'nmx_xnu_dma_unmap']]
    value = (templates / 'dma_native_fixture.cpp.in').read_text(encoding='utf-8')
    marker = '/* ACTUAL_NATIVE_DMA */'
    if value.count(marker) != 1:
        raise ValueError('DMA C++ fixture marker count')
    (output / 'dma-native-test.cpp').write_text(value.replace(marker, '\n\n'.join(pieces)),
                                               encoding='utf-8', newline='\n')
    print(f'Prepared real Linux/BSD/native DMA address and ownership chain: {output}')


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    for key in ['port', 'templates', 'output']:
        p.add_argument('--' + key, type=Path, required=True)
    a = p.parse_args()
    prepare(a.port, a.templates, a.output)
