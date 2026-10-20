/* Host behavioral/concurrency tests for the exact callback helper patched into
 * NMXGPUFB. Only IOKit locking, references and the timer scheduler are mocked;
 * registration, disabling, dispatch and unregister synchronization are real. */
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <future>
#include <mutex>
#include <thread>

using UInt32 = unsigned;
using IOSelect = unsigned;
using IOReturn = int;
using thread_t = std::thread::id;
using thread_call_t = void *;
#define THREAD_NULL std::thread::id{}
constexpr int THREAD_UNINT = 0;
constexpr IOReturn kIOReturnSuccess = 0, kIOReturnBadArgument = 1,
    kIOReturnUnsupported = 2, kIOReturnNotReady = 3, kIOReturnExclusiveAccess = 4;
constexpr IOSelect kIOFBVBLInterruptType = 1, kIOFBConnectInterruptType = 2;
struct OSObject {
    std::atomic<int> references{1};
    void retain() { ++references; }
    void release() { assert(--references >= 1); }
};
using IOFBInterruptProc = void (*)(OSObject *, void *);
struct IOLock {
    std::mutex mutex;
    std::condition_variable condition;
    std::atomic<unsigned> sleeping{0};
};
static void IOLockLock(IOLock *lock) { lock->mutex.lock(); }
static void IOLockUnlock(IOLock *lock) { lock->mutex.unlock(); }
static void IOLockSleep(IOLock *lock, void *, int) {
    std::unique_lock<std::mutex> guard(lock->mutex, std::adopt_lock);
    ++lock->sleeping;
    lock->condition.notify_all();
    lock->condition.wait(guard);
    --lock->sleeping;
    guard.release();
}
static void IOLockWakeup(IOLock *lock, void *, bool) { lock->condition.notify_all(); }
static thread_t current_thread() { return std::this_thread::get_id(); }
static std::atomic<unsigned> timer_arms{0};
static void thread_call_enter_delayed(thread_call_t, uint64_t) { ++timer_arms; }

#include "nmx_fb_interrupts.h"

static void count(OSObject *, void *ref) { ++*static_cast<unsigned *>(ref); }

int main() {
    using namespace std::chrono_literals;
    IOLock lock;
    NmxFbInterrupts interrupts;
    interrupts.initialize(&lock);
    OSObject target;
    unsigned calls = 0;
    void *reference = nullptr, *other = nullptr;
    assert(interrupts.install(99, count, &target, &calls, &reference) == kIOReturnUnsupported);
    assert(!reference);
    assert(interrupts.install(kIOFBVBLInterruptType, nullptr, &target, &calls, &reference) == kIOReturnBadArgument);
    assert(interrupts.install(kIOFBVBLInterruptType, count, &target, &calls, nullptr) == kIOReturnBadArgument);
    assert(interrupts.install(kIOFBVBLInterruptType, count, &target, &calls, &reference) == kIOReturnSuccess);
    assert(interrupts.install(kIOFBVBLInterruptType, count, &target, &calls, &other) == kIOReturnExclusiveAccess);
    NmxFbInterrupts::Call call;
    assert(interrupts.beginVbl(call));
    assert(target.references == 2);
    call.proc(call.target, call.ref);
    interrupts.end(call);
    assert(calls == 1 && target.references == 1);
    assert(interrupts.setState(reference, 0) == kIOReturnSuccess);
    assert(!interrupts.beginVbl(call));
    assert(interrupts.setState(reference, 1) == kIOReturnSuccess);
    assert(interrupts.setState(&target, 1) == kIOReturnBadArgument);
    assert(interrupts.remove(&target) == kIOReturnBadArgument);

    // Prove unregister waits for another thread's active callback. The test
    // observes a real wait, rather than assuming a delay means it was blocked.
    std::promise<void> entered, finish;
    auto finished = finish.get_future();
    auto dispatch = std::async(std::launch::async, [&] {
        NmxFbInterrupts::Call pending;
        assert(interrupts.beginVbl(pending));
        entered.set_value();
        finished.wait();
        pending.proc(pending.target, pending.ref);
        interrupts.end(pending);
    });
    entered.get_future().wait();
    auto removing = std::async(std::launch::async, [&] { return interrupts.remove(reference); });
    {
        std::unique_lock<std::mutex> guard(lock.mutex);
        assert(lock.condition.wait_for(guard, 2s, [&] { return lock.sleeping != 0; }));
    }
    assert(removing.wait_for(0s) == std::future_status::timeout);
    assert(interrupts.install(kIOFBVBLInterruptType, count, &target, &calls, &other) == kIOReturnExclusiveAccess);
    finish.set_value();
    dispatch.get();
    assert(removing.get() == kIOReturnSuccess);
    assert(target.references == 1 && !interrupts.beginVbl(call));

    // Self-unregister cannot wait for its own callback to return. A replacement
    // must remain blocked until the old call completes and releases its target.
    assert(interrupts.install(kIOFBVBLInterruptType, count, &target, &calls, &reference) == kIOReturnSuccess);
    assert(interrupts.beginVbl(call));
    assert(interrupts.remove(reference) == kIOReturnSuccess);
    assert(interrupts.install(kIOFBVBLInterruptType, count, &target, &calls, &other) == kIOReturnExclusiveAccess);
    interrupts.end(call);
    assert(interrupts.install(kIOFBVBLInterruptType, count, &target, &calls, &reference) == kIOReturnSuccess);
    assert(interrupts.install(kIOFBConnectInterruptType, count, &target, &calls, &other) == kIOReturnSuccess);
    assert(interrupts.beginConnect(call));
    assert(target.references == 2);
    call.proc(call.target, call.ref);
    interrupts.end(call);
    assert(!interrupts.begin(99, call));
    assert(interrupts.setState(other, 0) == kIOReturnSuccess);
    assert(!interrupts.beginConnect(call));
    assert(interrupts.remove(other) == kIOReturnSuccess);
    interrupts.arm(nullptr, 1);
    assert(timer_arms == 1);
    interrupts.stop();
    interrupts.arm(nullptr, 2);
    assert(timer_arms == 1 && !interrupts.beginVbl(call));
    assert(interrupts.install(kIOFBConnectInterruptType, count, &target, &calls, &other) == kIOReturnNotReady);
    assert(interrupts.remove(reference) == kIOReturnSuccess);
    assert(target.references == 1);
    std::puts("Framebuffer callback fixture passed: VBL/connect dispatch, disable, invalid handles, concurrent/self unregister, stop/rearm");
}
