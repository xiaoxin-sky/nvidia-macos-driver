"""Extract the production DRM-file identity helper and its wire ABI for a test.

Only the surrounding Linux file/minor objects are substituted. This verifies
metadata and failure behavior without opening a device or executing GPU work.
The complete kernel translation unit is compiled separately by the native job.
"""
import argparse
from pathlib import Path
import re


def prepare(port, output):
    """Build a standalone C test from a patched pinned xkpi tree.

    Refuse missing or changed extraction anchors rather than silently testing
    a copied implementation. Kernel/libdrm ioctl numbers must remain in sync.
    """
    source = (port / "override/src/nmx_drm_os.c").read_text()
    header = (port / "bsdcompat/include/nmx_drm_uapi.h").read_text()
    helper = re.search(r"static int nmx_drm_node_identity\([^\n]*\n.*?\n}\n", source, re.S)
    structure = re.search(r"struct nmx_drm_node_info \{.*?\n};", header, re.S)
    assert helper and structure
    assert source.count("return nmx_drm_node_identity(filp, data);") == 1
    definitions = "\n".join(line for line in header.splitlines()
                            if line.startswith(("#define NMX_DRM_NODE_", "#define NMX_DRM_IOCTL_NODE_INFO")))
    prefix = r'''
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifdef _WIN32
#define _IOR(g,n,t) (0x40000000UL | ((unsigned long)sizeof(t) << 16) | ((unsigned long)(g) << 8) | (n))
#else
#include <sys/ioctl.h>
#endif
#define DRM_MINOR_PRIMARY 0
#define DRM_MINOR_RENDER 2
struct drm_minor { int type; int index; };
struct drm_file { struct drm_minor *minor; };
struct linux_file { void *private_data; };
'''
    tests = r'''
int main(void) {
    struct nmx_drm_node_info info;
    struct drm_minor render = {DRM_MINOR_RENDER, 128}, primary = {DRM_MINOR_PRIMARY, 0};
    struct drm_file df = {&render};
    struct linux_file first = {&df}, second = {&df}, empty = {NULL};
    assert(sizeof(info) == 8 && NMX_DRM_IOCTL_NODE_INFO == 0x40084e44UL);
    assert(nmx_drm_node_identity(&first, &info) == 0 && info.type == 2 && info.index == 128);
    assert(nmx_drm_node_identity(&second, &info) == 0 && info.index == 128);
    df.minor = &primary;
    assert(nmx_drm_node_identity(&first, &info) == 0 && info.type == 0 && info.index == 0);
    assert(nmx_drm_node_identity(NULL, &info) == ENODEV);
    assert(nmx_drm_node_identity(&empty, &info) == ENODEV);
    df.minor = NULL; assert(nmx_drm_node_identity(&first, &info) == ENODEV);
    df.minor = &render; render.index = -1;
    assert(nmx_drm_node_identity(&first, &info) == ENODEV);
    render.index = 129; render.type = 32;
    assert(nmx_drm_node_identity(&first, &info) == ENODEV);
    render.type = DRM_MINOR_RENDER;
    assert(nmx_drm_node_identity(&first, &info) == 0 && info.index == 129);
    puts("NMX DRM file identity: actual helper, ABI, shared opens and invalid minors passed; no GPU opened.");
    return 0;
}
'''
    output.write_text(prefix + structure[0] + "\n" + definitions + "\n" + helper[0] + tests,
                      encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("port", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    prepare(args.port, args.output)
