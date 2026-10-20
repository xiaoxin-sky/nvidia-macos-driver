/* Test the actual transport deadline converter with independently controlled
 * clock epochs. The global Mesa clock and timed-condition code are untouched.
 */
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>

#ifndef CLOCK_MONOTONIC
#define CLOCK_MONOTONIC 6
#endif
#ifndef CLOCK_UPTIME_RAW
#define CLOCK_UPTIME_RAW 8
#endif
static struct timespec fixture_monotonic, fixture_uptime;
static unsigned reads;
static int fail_clock;
static int fixture_clock_gettime(int which, struct timespec *value) {
   ++reads;
   if (which == fail_clock) {
      errno = EIO;
      return -1;
   }
   assert(which == CLOCK_MONOTONIC || which == CLOCK_UPTIME_RAW);
   *value = which == CLOCK_MONOTONIC ? fixture_monotonic : fixture_uptime;
   return 0;
}
#ifdef clock_gettime
#undef clock_gettime
#endif
#define clock_gettime fixture_clock_gettime
#include "util/u_nmx_sync_clock.h"
#undef clock_gettime

int main(void) {
   int64_t converted = -1;
   assert(util_nmx_sync_abs_timeout(0, &converted) == 0 && converted == 0);
   assert(util_nmx_sync_abs_timeout(-1, &converted) == 0 && converted == 0);
   assert(util_nmx_sync_abs_timeout(INT64_MAX, &converted) == 0 && converted == INT64_MAX);
   assert(reads == 0);

   /* A large historical epoch difference must not become extra wait time. */
   fixture_monotonic = (struct timespec) { .tv_sec = 5000, .tv_nsec = 100 };
   fixture_uptime = (struct timespec) { .tv_sec = 10, .tv_nsec = 200 };
   assert(util_nmx_sync_abs_timeout(INT64_C(5005000000100), &converted) == 0);
   assert(converted == INT64_C(15000000200));
   assert(util_nmx_sync_abs_timeout(INT64_C(5000000000100), &converted) == 0 && converted == 0);
   assert(util_nmx_sync_abs_timeout(INT64_C(4999000000000), &converted) == 0 && converted == 0);

   fail_clock = CLOCK_MONOTONIC;
   assert(util_nmx_sync_abs_timeout(INT64_C(5005000000100), &converted) == -1 && errno == EIO);
   fail_clock = CLOCK_UPTIME_RAW;
   assert(util_nmx_sync_abs_timeout(INT64_C(5005000000100), &converted) == -1 && errno == EIO);
   fail_clock = 0;

   fixture_uptime.tv_nsec = 1000000000;
   assert(util_nmx_sync_abs_timeout(INT64_C(5005000000100), &converted) == -1 && errno == EOVERFLOW);
   fixture_uptime = (struct timespec) { .tv_sec = 9223372036LL, .tv_nsec = 854775807 };
   assert(util_nmx_sync_abs_timeout(INT64_C(5005000000100), &converted) == -1 && errno == EOVERFLOW);
   fixture_monotonic.tv_sec = -1;
   assert(util_nmx_sync_abs_timeout(INT64_C(5005000000100), &converted) == -1 && errno == EOVERFLOW);
   puts("actual NMX deadline epoch, poll/infinite and error conversion passed");
   return 0;
}
