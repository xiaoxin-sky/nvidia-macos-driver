/* Exercise the actual attach/stop admission state with real host threads.
 * IOKit lock operations are mocked; device lifetime is represented by an atomic
 * flag so no operation may be admitted once teardown has claimed the device. */
#include <atomic>
#include <cassert>
#include <cstdio>
#include <future>
#include <mutex>
#include <thread>
struct IOLock { std::mutex mutex; };
static void IOLockLock(IOLock *lock) { lock->mutex.lock(); }
static void IOLockUnlock(IOLock *lock) { lock->mutex.unlock(); }
#include "nmx_attach_lifecycle.h"

int main() {
    IOLock lock;
    NmxAttachLifecycle pending;
    pending.initialize(&lock);
    assert(pending.busy() && !pending.enterPower());
    pending.requestStop();
    assert(pending.stopping() && !pending.beginDetach());
    pending.complete(-1);
    assert(!pending.busy() && pending.beginDetach());
    assert(!pending.enterPower() && !pending.enterShutdown());

    NmxAttachLifecycle ready;
    ready.initialize(&lock);
    ready.complete(1);
    assert(ready.enterPower());
    ready.requestStop();
    assert(ready.busy() && !ready.beginDetach() && !ready.enterPower());
    ready.leavePower();
    assert(ready.enterShutdown() && ready.busy() && !ready.beginDetach());
    ready.leavePower();
    assert(ready.beginDetach() && !ready.enterShutdown());

    // Completion racing with a stop request must never reopen power admission.
    // A successful power admission holds teardown off until that operation ends.
    for (unsigned iteration = 0; iteration < 200; ++iteration) {
        NmxAttachLifecycle state;
        state.initialize(&lock);
        std::promise<void> start;
        auto go = start.get_future().share();
        std::atomic<bool> detached{false};
        auto completing = std::async(std::launch::async, [&] {
            go.wait();
            state.complete(1);
            if (state.enterPower()) {
                assert(!detached);
                std::this_thread::yield();
                assert(!detached);
                state.leavePower();
            }
        });
        auto stopping = std::async(std::launch::async, [&] {
            go.wait();
            state.requestStop();
            while (!state.beginDetach()) std::this_thread::yield();
            detached = true;
        });
        start.set_value();
        completing.get();
        stopping.get();
        assert(detached && !state.enterPower() && !state.enterShutdown());
    }
    std::puts("Attach lifecycle fixture passed: pending cancellation, active power/shutdown drain and 200 stop/completion races");
}
