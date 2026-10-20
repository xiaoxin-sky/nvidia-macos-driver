/* Executes the production NMX mapping helper against an exact-range ioctl peer. */
#include <assert.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>
#include "anv_nmx_mmap.h"

struct peer_map { uint64_t addr, size; int fd; };
static struct peer_map maps[8];
static unsigned invocations, live;
static uint64_t last_offset, last_size;
static int fail_errno;
static uint64_t next_address = UINT64_C(0x100000000);

static int peer_ioctl(int fd, unsigned long command, void *argument)
{
   invocations++;
   if (fail_errno) { errno = fail_errno; return -1; }
   if (command == ANV_NMX_DRM_IOCTL_MMAP) {
      struct anv_nmx_drm_mmap *request = argument;
      assert(request->flags == 0);
      assert(request->addr == 0);
      assert(request->prot == (PROT_READ | PROT_WRITE));
      last_offset = request->offset;
      last_size = request->size;
      for (unsigned i = 0; i < 8; i++) {
         if (maps[i].addr) continue;
         request->addr = next_address;
         next_address += UINT64_C(0x1000000);
         maps[i] = (struct peer_map) { request->addr,
            (request->size + 4095) & ~UINT64_C(4095), fd };
         live++;
         return 0;
      }
      errno = ENOMEM;
      return -1;
   }
   assert(command == ANV_NMX_DRM_IOCTL_MUNMAP);
   struct anv_nmx_drm_munmap *request = argument;
   for (unsigned i = 0; i < 8; i++) {
      if (maps[i].addr == request->addr && maps[i].fd == fd &&
          maps[i].size == ((request->size + 4095) & ~UINT64_C(4095))) {
         memset(&maps[i], 0, sizeof(maps[i]));
         live--;
         return 0;
      }
   }
   errno = EINVAL;
   return -1;
}

int main(void)
{
   assert(sizeof(struct anv_nmx_drm_mmap) == 32);
   assert(offsetof(struct anv_nmx_drm_mmap, addr) == 24);
   assert(sizeof(struct anv_nmx_drm_munmap) == 16);
   assert(ANV_NMX_DRM_IOCTL_MMAP == 0xc0204e40UL);
   assert(ANV_NMX_DRM_IOCTL_MUNMAP == 0x80104e41UL);
   const uint64_t fake = UINT64_C(0x80000000);
   void *whole = anv_nmx_bo_mmap(7, fake, 0, 8192, NULL, peer_ioctl);
   assert(whole != MAP_FAILED && live == 1 && last_offset == fake && last_size == 8192);
   void *slice = anv_nmx_bo_mmap(7, fake, 4096, 4097, NULL, peer_ioctl);
   assert(slice != MAP_FAILED && slice != whole && live == 2);
   assert(last_offset == fake + 4096 && last_size == 4097);
   /* A second alias must be owned/released independently, with no prefix trim. */
   assert(anv_nmx_bo_munmap(7, slice, 4096, false, peer_ioctl) == -1 && live == 2);
   assert(anv_nmx_bo_munmap(8, slice, 4097, false, peer_ioctl) == -1 && live == 2);
   assert(anv_nmx_bo_munmap(7, slice, 4097, false, peer_ioctl) == 0 && live == 1);
   assert(anv_nmx_bo_munmap(7, whole, 8192, false, peer_ioctl) == 0 && live == 0);

   unsigned saved = invocations;
   assert(anv_nmx_bo_mmap(7, fake, 1, 4096, NULL, peer_ioctl) == MAP_FAILED && errno == EINVAL);
   assert(anv_nmx_bo_mmap(7, fake + 1, 0, 4096, NULL, peer_ioctl) == MAP_FAILED && errno == EINVAL);
   assert(anv_nmx_bo_mmap(7, fake, 0, 0, NULL, peer_ioctl) == MAP_FAILED && errno == EINVAL);
   assert(anv_nmx_bo_mmap(7, fake, 0, ANV_NMX_MAX_MAP_SIZE + 1, NULL, peer_ioctl) == MAP_FAILED && errno == EINVAL);
   assert(anv_nmx_bo_mmap(7, UINT64_MAX - 4095, 4096, 4096, NULL, peer_ioctl) == MAP_FAILED && errno == EINVAL);
   assert(anv_nmx_bo_mmap(7, UINT64_MAX - 4095, 0, 4096, NULL, peer_ioctl) == MAP_FAILED && errno == EINVAL);
   assert(anv_nmx_bo_mmap(7, fake, 0, 4096, whole, peer_ioctl) == MAP_FAILED && errno == EOPNOTSUPP);
   assert(anv_nmx_bo_munmap(7, whole, 8192, true, peer_ioctl) == -1 && errno == EOPNOTSUPP);
   assert(anv_nmx_bo_munmap(7, (void *)(uintptr_t)1, 4096, false, peer_ioctl) == -1 && errno == EINVAL);
   assert(anv_nmx_bo_munmap(7, NULL, 4096, false, peer_ioctl) == -1 && errno == EINVAL);
   assert(anv_nmx_bo_munmap(7, MAP_FAILED, 4096, false, peer_ioctl) == -1 && errno == EINVAL);
   assert(anv_nmx_bo_munmap(7, whole, 0, false, peer_ioctl) == -1 && errno == EINVAL);
   assert(invocations == saved);

   fail_errno = ENOMEM;
   assert(anv_nmx_bo_mmap(7, fake, 0, 4096, NULL, peer_ioctl) == MAP_FAILED && errno == ENOMEM);
   assert(live == 0);
   fail_errno = 0;
   whole = anv_nmx_bo_mmap(7, fake, 0, 4096, NULL, peer_ioctl);
   fail_errno = EBUSY;
   assert(anv_nmx_bo_munmap(7, whole, 4096, false, peer_ioctl) == -1 && errno == EBUSY);
   assert(live == 1); /* failure retains ownership and can be retried */
   fail_errno = 0;
   assert(anv_nmx_bo_munmap(7, whole, 4096, false, peer_ioctl) == 0 && live == 0);
   puts("NMX ANV mmap ABI, slice ownership and failure fixture passed");
   return 0;
}
