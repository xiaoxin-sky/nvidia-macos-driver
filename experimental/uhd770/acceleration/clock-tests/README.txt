NMX absolute-wait transport clock checks

Mesa deadlines and timed conditions keep their existing CLOCK_MONOTONIC epoch.
Only Darwin/i915's explicitly selected NMX sync provider converts a deadline's
remaining duration to CLOCK_UPTIME_RAW immediately before binary/timeline wait
ioctls. Provider cloning retains this choice. Other providers are unchanged.
This matches the NMX kernel's mach_absolute_time-based nanouptime without
requiring CLOCK_MONOTONIC and kernel uptime to have the same historical epoch.

Compile against the patched Mesa source, not a duplicate helper:

clang -std=c11 -Wall -Wextra -Werror -I "$MESA/src" clock_fixture.c -o "$OUT/clock_fixture"
"$OUT/clock_fixture"
clang -std=c11 -Wall -Wextra -Werror -I "$MESA/src" native_clock_smoke.c -o "$OUT/native_clock_smoke"
"$OUT/native_clock_smoke"

clock_fixture.c also passes MSVC /std:c11 /W4 /WX. Its independent fake clocks
cover differing epochs, finite waits, expiry, poll/infinite sentinels, read
failure and arithmetic overflow. Overflow/error returns never create an
unbounded wait.

native_clock_smoke.c uses macOS clocks and mach_absolute_time directly. It
brackets clock samples instead of imposing timing guesses, checks the selected
clock's epoch against the kernel's source clock, and checks deadline conversion
within the observed sampling interval. It does not contact a GPU, sleep the
machine or change the wall clock. Full real GPU wait completion remains unproven.
