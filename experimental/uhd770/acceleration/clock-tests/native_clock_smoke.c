/* Native macOS smoke: compare the chosen kernel transport clock with the
 * actual mach_absolute_time epoch. No GPU, sleep or wall-clock change occurs.
 */
#include <assert.h>
#include <inttypes.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include "util/u_nmx_sync_clock.h"

static int64_t mach_nanoseconds(void) {
   mach_timebase_info_data_t info;
   assert(mach_timebase_info(&info) == KERN_SUCCESS);
   return (int64_t)((__uint128_t)mach_absolute_time() * info.numer / info.denom);
}
static int64_t clock_nanoseconds(clockid_t clock) {
   struct timespec now;
   int64_t ns;
   assert(clock_gettime(clock, &now) == 0);
   assert(util_nmx_timespec_ns(&now, &ns) == 0);
   return ns;
}
int main(void) {
   const int64_t mach_before = mach_nanoseconds();
   const int64_t uptime = clock_nanoseconds(CLOCK_UPTIME_RAW);
   const int64_t mach_after = mach_nanoseconds();
   assert(uptime >= mach_before && uptime <= mach_after);

   const int64_t mono_before = clock_nanoseconds(CLOCK_MONOTONIC);
   const int64_t raw_before = clock_nanoseconds(CLOCK_UPTIME_RAW);
   const int64_t deadline = mono_before + INT64_C(500000000);
   int64_t converted;
   assert(util_nmx_sync_abs_timeout(deadline, &converted) == 0);
   const int64_t raw_after = clock_nanoseconds(CLOCK_UPTIME_RAW);
   const int64_t mono_after = clock_nanoseconds(CLOCK_MONOTONIC);
   if (converted != 0) {
      const int64_t lower = raw_before + (deadline > mono_after ? deadline - mono_after : 0);
      const int64_t upper = raw_after + deadline - mono_before;
      assert(converted >= lower && converted <= upper);
   } else {
      assert(mono_after >= deadline);
   }
   printf("CLOCK_UPTIME_RAW matches mach_absolute_time; converted deadline=%" PRId64 "\n", converted);
   return 0;
}
