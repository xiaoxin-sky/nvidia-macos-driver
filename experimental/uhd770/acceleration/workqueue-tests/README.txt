NMX taskqueue concurrency fixture

prepare_fixture.py extracts the actual task layout, taskqueue state and twelve
scheduling/lifecycle functions from the patched xkpi tree. Intrusive queue
storage and kernel services are host adapters; scheduling decisions are not
reimplemented. Use C++20 because the actual C bodies use designated initializers.

Example on the macOS CI runner:

python3 prepare_fixture.py --port "$PORT" --template taskqueue_fixture.cpp.in --output "$OUT/taskqueue_fixture.cpp"
clang++ -std=c++20 -Wall -Wextra -Werror -pthread "$OUT/taskqueue_fixture.cpp" -o "$OUT/taskqueue_fixture"
"$OUT/taskqueue_fixture"

The same generated source is checked with MSVC /std:c++20 /EHsc /W4 /WX.
Five-second failure limits keep unexpected deadlocks bounded. Explicit barriers
establish that callbacks have entered and drains are sleeping before checking
whether cancel/drain/free completed early; no fixed sleep guesses are used.

Coverage:
- Two callbacks concurrently active; cancel and poll see both; completing one
  cannot make the other's task-specific drain or whole-queue drain return.
- Active task requeued/coalesced behind itself never executes concurrently and
  does not block runnable tasks behind it. Its pending invocation still runs.
- Removing a queued task wakes both task-specific and whole-queue drains.
- The actual worker exit and queue-free functions wait for both callbacks to
  finish before freeing the queue; post-unlock thread cleanup does not use it.
- Queue free also waits for an already active synchronous taskqueue_run caller,
  which is not counted as an owned worker thread.

As with FreeBSD, callers must stop external producers/new run calls before
freeing a queue; calls that begin after lifetime teardown are not permitted.
Self-cancel reports EBUSY. Self-drain or freeing from the queue's own worker is
not a supported call: it would wait for the currently executing caller itself.
This fixture does not validate GPU IRQ delivery or real XNU thread primitives.
