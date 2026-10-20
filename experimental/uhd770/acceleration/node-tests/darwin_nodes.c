/* SPDX-License-Identifier: MIT
 * Exercise the compiled Darwin libdrm against an inert devfs inventory. The
 * interposer owns only /dev/dri and descriptors it opens on /dev/null; no GPU
 * node is opened. Published IDs, clone IDs and logical DRM suffixes deliberately
 * differ. Build once as a dylib with NMX_NODE_SHIM, once as the test executable.
 */
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include "xf86drm.h"
#include "nmx_drm_node.h"

#ifdef NMX_NODE_SHIM
struct fixture_pci {
    uint16_t domain;
    uint8_t bus, dev, func;
    uint16_t vendor_id, device_id, subvendor_id, subdevice_id;
    uint8_t revision_id;
};
#define FIXTURE_PCI_IOCTL DRM_IOR(0x15, struct fixture_pci)
static const char *const names[] = {"card0", "renderD128", "card1", "renderD129"};
static int descriptors[4096], replaced[4096];
struct fixture_dir { unsigned position; struct dirent entry; };
static struct fixture_dir *directories[32];

static int mode(const char *name)
{
    const char *value = getenv("NMX_NODE_TEST_MODE");
    return value && !strcmp(value, name);
}
static int node(const char *path)
{
    for (unsigned i = 0; i < 4; ++i) {
        char candidate[64];
        snprintf(candidate, sizeof(candidate), "/dev/dri/%s", names[i]);
        if (!strcmp(path, candidate)) return (int)i;
    }
    return -1;
}
static int tracked(int fd) { return fd >= 0 && fd < 4096 ? descriptors[fd] : 0; }
static int directory(DIR *value)
{
    for (int i = 0; i < 32; ++i)
        if (directories[i] && (DIR *)directories[i] == value) return i;
    return -1;
}
static DIR *fake_opendir(const char *path)
{
    if (strcmp(path, "/dev/dri")) return opendir(path);
    for (int i = 0; i < 32; ++i) if (!directories[i]) {
        directories[i] = calloc(1, sizeof(*directories[i]));
        return (DIR *)directories[i];
    }
    errno = EMFILE; return NULL;
}
static struct dirent *fake_readdir(DIR *dir)
{
    int slot = directory(dir);
    if (slot < 0) return readdir(dir);
    struct fixture_dir *d = directories[slot];
    if (d->position == 4) return NULL;
    memset(&d->entry, 0, sizeof(d->entry));
    strcpy(d->entry.d_name, names[d->position++]);
    d->entry.d_namlen = (uint16_t)strlen(d->entry.d_name);
    d->entry.d_type = DT_CHR;
    return &d->entry;
}
static int fake_closedir(DIR *dir)
{
    int slot = directory(dir);
    if (slot < 0) return closedir(dir);
    free(directories[slot]); directories[slot] = NULL; return 0;
}
static int fake_stat(const char *path, struct stat *st)
{
    int n = node(path);
    if (n < 0) {
        if (!strncmp(path, "/dev/dri", 8)) { errno = ENOENT; return -1; }
        return stat(path, st);
    }
    if (n == 1 && mode("removed")) { errno = ENOENT; return -1; }
    memset(st, 0, sizeof(*st)); st->st_mode = S_IFCHR | 0666;
    st->st_rdev = makedev(241, 51 + n); return 0;
}
static int fake_fstat(int fd, struct stat *st)
{
    if (!tracked(fd)) return fstat(fd, st);
    memset(st, 0, sizeof(*st)); st->st_mode = S_IFCHR | 0666;
    st->st_rdev = makedev(241, 1000 + fd); return 0;
}
static int fake_access(const char *path, int flags)
{
    if (node(path) >= 0) return 0;
    if (!strncmp(path, "/dev/dri", 8)) { errno = ENOENT; return -1; }
    return access(path, flags);
}
static int fake_open(const char *path, int flags, ...)
{
    int n = node(path);
    if (n < 0) {
        if (!strncmp(path, "/dev/dri", 8)) { errno = ENOENT; return -1; }
        mode_t permissions = 0;
        if (flags & O_CREAT) { va_list ap; va_start(ap, flags); permissions = va_arg(ap, int); va_end(ap); }
        return open(path, flags, permissions);
    }
    if (!(n & 1) && mode("deny-primary")) { errno = EACCES; return -1; }
    int fd = open("/dev/null", O_RDWR | O_CLOEXEC);
    if (fd >= 4096) { close(fd); errno = EMFILE; return -1; }
    if (fd >= 0) { descriptors[fd] = n + 1; replaced[fd] = mode("replaced"); }
    return fd;
}
static int fake_close(int fd)
{
    if (tracked(fd)) { descriptors[fd] = 0; replaced[fd] = 0; }
    return close(fd);
}
static int fake_ioctl(int fd, unsigned long command, ...)
{
    va_list ap; va_start(ap, command); void *argument = va_arg(ap, void *); va_end(ap);
    int n = tracked(fd) - 1;
    if (n < 0) return ioctl(fd, command, argument);
    if (command == NMX_DRM_IOCTL_NODE_INFO) {
        if (mode("legacy")) { errno = ENOTTY; return -1; }
        struct nmx_drm_node_info *info = argument;
        info->type = mode("bad-kind") ? 99 : (n & 1 ? NMX_DRM_NODE_RENDER : NMX_DRM_NODE_PRIMARY);
        info->index = n & 1 ? 128 + n / 2 : n / 2;
        return 0;
    }
    if (command == FIXTURE_PCI_IOCTL) {
        struct fixture_pci *info = argument;
        memset(info, 0, sizeof(*info));
        info->dev = (uint8_t)(2 + n / 2 + replaced[fd]);
        info->vendor_id = n < 2 ? 0x8086 : 0x1002;
        info->device_id = n < 2 ? 0x4680 : 0x73bf;
        info->revision_id = 0x0c;
        return 0;
    }
    errno = ENOTTY; return -1;
}
#define INTERPOSE(replacement, original) \
    __attribute__((used, section("__DATA,__interpose"))) \
    static const struct { const void *new_fn; const void *old_fn; } pair_##original = \
        { (const void *)(uintptr_t)&replacement, (const void *)(uintptr_t)&original }
INTERPOSE(fake_opendir, opendir);
INTERPOSE(fake_readdir, readdir);
INTERPOSE(fake_closedir, closedir);
INTERPOSE(fake_stat, stat);
INTERPOSE(fake_fstat, fstat);
INTERPOSE(fake_access, access);
INTERPOSE(fake_open, open);
INTERPOSE(fake_close, close);
INTERPOSE(fake_ioctl, ioctl);
#else
static void expect_name(char *actual, const char *expected)
{
    assert(actual && !strcmp(actual, expected)); free(actual);
}
static void expect_device(int fd, uint16_t vendor, uint16_t device)
{
    drmDevicePtr d = NULL;
    int result = drmGetDevice2(fd, DRM_DEVICE_GET_PCI_REVISION, &d);
    if (result) fprintf(stderr, "drmGetDevice2 failed: %d\n", result);
    assert(result == 0 && d && d->bustype == DRM_BUS_PCI);
    assert(d->deviceinfo.pci->vendor_id == vendor && d->deviceinfo.pci->device_id == device);
    assert(d->deviceinfo.pci->revision_id == 0x0c);
    drmFreeDevice(&d);
}
int main(void)
{
    assert(getenv("DYLD_INSERT_LIBRARIES"));
    assert(sizeof(struct nmx_drm_node_info) == 8 && NMX_DRM_IOCTL_NODE_INFO == 0x40084e44UL);
    assert(drmGetDevices2(0, NULL, 0) == 2);
    int a = open("/dev/dri/renderD128", O_RDWR), b = open("/dev/dri/renderD128", O_RDWR);
    int other = open("/dev/dri/renderD129", O_RDWR), primary = open("/dev/dri/card0", O_RDWR);
    assert(a >= 0 && b >= 0 && other >= 0 && primary >= 0);
    struct stat published, sa, sb;
    assert(!stat("/dev/dri/renderD128", &published) && !fstat(a, &sa) && !fstat(b, &sb));
    assert(published.st_rdev != sa.st_rdev && sa.st_rdev != sb.st_rdev);
    assert(drmGetNodeTypeFromDevId(published.st_rdev) == DRM_NODE_RENDER);
    assert(drmGetNodeTypeFromFd(a) == DRM_NODE_RENDER && drmGetNodeTypeFromFd(primary) == DRM_NODE_PRIMARY);
    expect_device(a, 0x8086, 0x4680); expect_device(b, 0x8086, 0x4680);
    expect_device(other, 0x1002, 0x73bf);
    expect_name(drmGetDeviceNameFromFd(a), "/dev/dri/renderD128");
    expect_name(drmGetDeviceNameFromFd2(b), "/dev/dri/renderD128");
    expect_name(drmGetPrimaryDeviceNameFromFd(a), "/dev/dri/card0");
    expect_name(drmGetRenderDeviceNameFromFd(primary), "/dev/dri/renderD128");
    setenv("NMX_NODE_TEST_MODE", "deny-primary", 1);
    expect_device(a, 0x8086, 0x4680);
    const char *failures[] = {"legacy", "bad-kind", "removed", "replaced"};
    const int errors[] = {ENOTTY, ENODEV, ENOENT, ENODEV};
    for (unsigned i = 0; i < 4; ++i) {
        setenv("NMX_NODE_TEST_MODE", failures[i], 1);
        drmDevicePtr d = NULL;
        int result = drmGetDevice2(a, 0, &d);
        if (result != -errors[i]) fprintf(stderr, "%s: actual=%d expected=%d\n", failures[i], result, -errors[i]);
        assert(result == -errors[i] && d == NULL);
    }
    unsetenv("NMX_NODE_TEST_MODE");
    close(a); expect_device(b, 0x8086, 0x4680);
    close(b); close(other); close(primary);
    puts("NMX Darwin node identity: compiled libdrm enumeration, clone fds, PCI isolation and failures passed; no GPU opened.");
    return 0;
}
#endif
