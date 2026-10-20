/*
 * Opt-in UHD 770 Metal compute/readback diagnostic. CI compiles this executable
 * without running it. Device selection is tied to NMXAccel's real PCI ancestry;
 * a pass still needs matching kernel execution logs, not a device-name claim.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <objc/runtime.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/utsname.h>

namespace {
constexpr uint32_t kCount = 4096;
constexpr uint32_t kRounds = 3;
constexpr uint32_t kThreads = 64;

[[noreturn]] void fail(const std::string &message) { throw std::runtime_error(message); }
const char *utf8(NSString *value) { return value ? value.UTF8String : "(nil)"; }

struct Options { std::string metallib; uint32_t deadline = 45; };

Options arguments(int argc, char **argv)
{
    Options result;
    for (int i = 1; i < argc; ++i) {
        const std::string option = argv[i];
        if (option == "--help") {
            std::puts("Usage: uhd770-metal-probe --metallib PATH [--deadline 45]\n"
                      "Requires the matched diagnostic package. --help does not enumerate Metal or I/O Registry.\n"
                      "A normal run submits three 4096-word Metal compute dispatches on UHD 770.");
            std::exit(0);
        }
        if (i + 1 >= argc) fail("Missing value for " + option);
        const char *value = argv[++i];
        if (option == "--metallib") result.metallib = value;
        else if (option == "--deadline") {
            if (!value[0] || value[0] == '-') fail("Invalid deadline");
            size_t consumed = 0;
            const unsigned long seconds = std::stoul(value, &consumed, 10);
            if (value[consumed] || seconds < 5 || seconds > 120) fail("Deadline must be 5..120 seconds");
            result.deadline = static_cast<uint32_t>(seconds);
        } else fail("Unknown option " + option);
    }
    if (result.metallib.empty()) fail("--metallib is required; no GPU has been enumerated");
    struct stat information{};
    if (stat(result.metallib.c_str(), &information) || !S_ISREG(information.st_mode) ||
        information.st_size < 4 || information.st_size > 64 * 1024 * 1024)
        fail("--metallib must be a regular file between 4 bytes and 64 MiB");
    std::ifstream input(result.metallib, std::ios::binary);
    char magic[4]{};
    if (!input.read(magic, sizeof magic) || std::memcmp(magic, "MTLB", sizeof magic))
        fail("--metallib is not an Apple Metal library container");
    return result;
}

void cleanEnvironment()
{
    // Do not print values: injected-library/driver paths can contain private data.
    // This rejects common overrides; a user-space diagnostic cannot attest against
    // a malicious library that already entered the process before main().
    const char *rejected[] = {
        "NVMTL_ICD_LIB", "VK_DRIVER_FILES", "VK_ADD_DRIVER_FILES", "VK_ICD_FILENAMES",
        "VK_INSTANCE_LAYERS", "VK_LAYER_PATH", "VK_ADD_LAYER_PATH",
        "VK_LOADER_DRIVERS_SELECT", "VK_LOADER_DRIVERS_DISABLE",
        "INTEL_NO_HW", "INTEL_DEVID_OVERRIDE", "INTEL_DEBUG", "ANV_NO_HW", "ANV_NULL_RENDERING",
        "MESA_LOADER_DRIVER_OVERRIDE", "MESA_VK_DEVICE_SELECT", "DRI_PRIME",
        "LIBGL_ALWAYS_SOFTWARE", "GALLIUM_DRIVER", "DRM_SHIM", "LD_PRELOAD",
        "DYLD_INSERT_LIBRARIES", "DYLD_LIBRARY_PATH", "DYLD_FRAMEWORK_PATH",
        "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_FALLBACK_FRAMEWORK_PATH"
    };
    for (const char *name : rejected) {
        const char *value = std::getenv(name);
        if (value && value[0]) fail(std::string("Rejected execution override: ") + name);
    }
    if (setenv("NVMTL_ENABLE", "1", 1) || setenv("VK_LOADER_LAYERS_DISABLE", "~all~", 1))
        fail("Cannot set process-local diagnostic environment");
}

class Deadline {
    std::atomic<bool> finished{false};
    std::thread worker;
public:
    explicit Deadline(uint32_t seconds) : worker([this, seconds] {
        const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
        while (!finished.load(std::memory_order_acquire)) {
            if (std::chrono::steady_clock::now() >= end) {
                std::fputs("FAIL: Metal probe overall deadline exceeded; abandoning teardown (exit 124).\n", stderr);
                std::fflush(nullptr);
                std::_Exit(124);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    }) {}
    ~Deadline() { finished.store(true, std::memory_order_release); worker.join(); }
};

// IOKit copy/get APIs below return retained handles, independently of ARC.
class IOHandle {
    io_object_t object;
public:
    explicit IOHandle(io_object_t value = IO_OBJECT_NULL) : object(value) {}
    IOHandle(const IOHandle &) = delete;
    IOHandle &operator=(const IOHandle &) = delete;
    ~IOHandle() { if (object) IOObjectRelease(object); }
    io_object_t get() const { return object; }
    void reset(io_object_t value)
    {
        if (object) IOObjectRelease(object);
        object = value;
    }
};

bool pciNumber(io_registry_entry_t entry, CFStringRef key, uint32_t &result)
{
    CFTypeRef property = IORegistryEntryCreateCFProperty(entry, key, kCFAllocatorDefault, 0);
    if (!property) return false;
    bool valid = false;
    if (CFGetTypeID(property) == CFDataGetTypeID()) {
        const auto data = static_cast<CFDataRef>(property);
        const CFIndex count = CFDataGetLength(data);
        if (count >= 2 && count <= 4) {
            const UInt8 *bytes = CFDataGetBytePtr(data);
            result = 0;
            for (CFIndex i = 0; i < count; ++i) result |= static_cast<uint32_t>(bytes[i]) << (8 * i);
            valid = true;
        }
    } else if (CFGetTypeID(property) == CFNumberGetTypeID()) {
        int64_t value = -1;
        valid = CFNumberGetValue(static_cast<CFNumberRef>(property), kCFNumberSInt64Type, &value) &&
                value >= 0 && static_cast<uint64_t>(value) <= UINT32_MAX;
        if (valid) result = static_cast<uint32_t>(value);
    }
    CFRelease(property);
    return valid;
}

struct Identity {
    uint64_t acceleratorID = 0, pciID = 0;
    uint32_t vendor = 0, device = 0, classCode = 0;
};

bool pciIdentity(io_service_t accelerator, Identity &identity)
{
    if (IORegistryEntryGetRegistryEntryID(accelerator, &identity.acceleratorID) != KERN_SUCCESS ||
        IOObjectRetain(accelerator) != KERN_SUCCESS) return false;
    IOHandle current(accelerator);
    for (unsigned depth = 0; depth < 8; ++depth) {
        if (IOObjectConformsTo(current.get(), "IOPCIDevice")) {
            return IORegistryEntryGetRegistryEntryID(current.get(), &identity.pciID) == KERN_SUCCESS &&
                   pciNumber(current.get(), CFSTR("vendor-id"), identity.vendor) &&
                   pciNumber(current.get(), CFSTR("device-id"), identity.device) &&
                   pciNumber(current.get(), CFSTR("class-code"), identity.classCode);
        }
        io_registry_entry_t parent = IO_OBJECT_NULL;
        if (IORegistryEntryGetParentEntry(current.get(), kIOServicePlane, &parent) != KERN_SUCCESS) return false;
        current.reset(parent);
    }
    return false;
}

std::vector<Identity> intelAccelerators()
{
    CFMutableDictionaryRef matching = IOServiceMatching("NMXAccel");
    if (!matching) fail("Cannot create NMXAccel registry match");
    io_iterator_t raw = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &raw) != KERN_SUCCESS)
        fail("Cannot enumerate NMXAccel services");
    IOHandle iterator(raw);
    std::vector<Identity> identities;
    while (io_service_t service = IOIteratorNext(iterator.get())) {
        IOHandle accelerator(service);
        Identity identity;
        if (!pciIdentity(service, identity)) {
            std::puts("NMXAccel candidate rejected: incomplete PCI ancestry/identity");
            continue;
        }
        std::printf("NMXAccel registry: accelerator=0x%llx pci=0x%llx vendor=%04x device=%04x class=%06x\n",
                    static_cast<unsigned long long>(identity.acceleratorID),
                    static_cast<unsigned long long>(identity.pciID), identity.vendor, identity.device, identity.classCode);
        if (identity.vendor == 0x8086 && identity.device == 0x4680 &&
            ((identity.classCode >> 16) & 0xff) == 0x03) identities.push_back(identity);
    }
    if (!IOIteratorIsValid(iterator.get())) fail("NMXAccel registry iterator became invalid; retry explicitly");
    if (identities.empty()) fail("No NMXAccel bound to a display-class Intel PCI 8086:4680");
    return identities;
}

id<MTLDevice> selectDevice(Identity &selected)
{
    const auto identities = intelAccelerators();
    NSArray<id<MTLDevice>> *devices = MTLCopyAllDevices();
    Class expected = NSClassFromString(@"NVMTLDevice");
    id<MTLDevice> result = nil;
    unsigned matches = 0;
    for (id<MTLDevice> device in devices) {
        const uint64_t registry = device.registryID;
        const char *className = object_getClassName(device);
        std::printf("Metal candidate: class=%s name=%s registry=0x%llx\n", className ? className : "(nil)",
                    utf8(device.name), static_cast<unsigned long long>(registry));
        if (!expected || ![(NSObject *)device isKindOfClass:expected] || !registry) continue;
        for (const auto &identity : identities) {
            if (registry != identity.acceleratorID && registry != identity.pciID) continue;
            selected = identity; result = device; ++matches;
        }
    }
    if (matches != 1) fail("Expected exactly one NVMTLDevice tied to UHD 770 NMXAccel; matches=" + std::to_string(matches));
    std::printf("selected: class=%s name=%s registry=0x%llx vendor=8086 device=4680 pciClass=%06x\n",
                object_getClassName(result), utf8(result.name),
                static_cast<unsigned long long>(result.registryID), selected.classCode);
    return result;
}

uint32_t inputWord(uint32_t index, uint32_t seed)
{
    return seed ^ (index * 747796405u + 2891336453u);
}

void complete(id<MTLCommandBuffer> command)
{
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    for (;;) {
        const MTLCommandBufferStatus status = command.status;
        if (status == MTLCommandBufferStatusCompleted) return;
        if (status == MTLCommandBufferStatusError)
            fail(std::string("Metal command buffer failed: ") + utf8(command.error.localizedDescription));
        if (std::chrono::steady_clock::now() >= deadline) {
            std::fputs("FAIL: Metal command deadline exceeded; abandoning in-flight teardown (exit 124).\n", stderr);
            std::fflush(nullptr);
            std::_Exit(124);
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(10));
    }
}

void compute(const Options &options)
{
    Identity identity;
    id<MTLDevice> device = selectDevice(identity);
    NSError *error = nil;
    NSString *path = [[NSString alloc] initWithBytes:options.metallib.data() length:options.metallib.size()
                                          encoding:NSUTF8StringEncoding];
    if (!path) fail("--metallib path is not UTF-8");
    id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
    if (!library) fail(std::string("Cannot load precompiled smoke metallib: ") + utf8(error.localizedDescription));
    id<MTLFunction> function = [library newFunctionWithName:@"smoke"];
    if (!function || function.functionType != MTLFunctionTypeKernel) fail("Metallib lacks the smoke compute kernel");
    error = nil;
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
    if (!pipeline) fail(std::string("Cannot create Metal compute pipeline: ") + utf8(error.localizedDescription));
    if (pipeline.maxTotalThreadsPerThreadgroup < kThreads) fail("Compute pipeline cannot support 64 threads per group");
    std::printf("pipeline: threadExecutionWidth=%lu maxThreads=%lu fixedDispatch=64 groups x 64 threads\n",
                static_cast<unsigned long>(pipeline.threadExecutionWidth),
                static_cast<unsigned long>(pipeline.maxTotalThreadsPerThreadgroup));
    const NSUInteger bytes = kCount * sizeof(uint32_t);
    id<MTLBuffer> input = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    if (!input || !output || input.length < bytes || output.length < bytes ||
        input.storageMode != MTLStorageModeShared || output.storageMode != MTLStorageModeShared ||
        !input.contents || !output.contents) fail("Cannot allocate CPU-visible Metal shared buffers");
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) fail("Cannot create Metal command queue");
    queue.label = @"UHD770 opt-in compute/readback diagnostic";
    auto *in = static_cast<uint32_t *>(input.contents);
    auto *out = static_cast<uint32_t *>(output.contents);
    for (uint32_t round = 0; round < kRounds; ++round) {
        const uint32_t seed = 0x2468ace1u + round * 0x6d2b79f5u;
        for (uint32_t i = 0; i < kCount; ++i) { in[i] = inputWord(i, seed); out[i] = 0xcdfefeedu ^ round; }
        id<MTLCommandBuffer> command = [queue commandBuffer];
        if (!command) fail("Cannot create Metal command buffer");
        id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
        if (!encoder) fail("Cannot create Metal compute encoder");
        [encoder setComputePipelineState:pipeline];
        [encoder setBuffer:input offset:0 atIndex:0];
        [encoder setBuffer:output offset:0 atIndex:1];
        [encoder dispatchThreadgroups:MTLSizeMake(kCount / kThreads, 1, 1)
               threadsPerThreadgroup:MTLSizeMake(kThreads, 1, 1)];
        [encoder endEncoding];
        std::printf("dispatch %u: seed=%08x words=%u\n", round + 1, seed, kCount);
        const auto started = std::chrono::steady_clock::now();
        @try {
            [command commit];
        } @catch (NSException *exception) {
            // A throwing commit can have partially submitted work. Do not unwind
            // buffers whose lifetime the experimental driver may still depend on.
            std::fprintf(stderr, "FAIL: commit exception %s: %s; abandoning teardown (exit 2).\n",
                         utf8(exception.name), utf8(exception.reason));
            std::fflush(nullptr);
            std::_Exit(2);
        }
        complete(command);
        uint32_t mismatches = 0;
        for (uint32_t i = 0; i < kCount; ++i) {
            const uint32_t expected = (inputWord(i, seed) ^ 0x13579bdfu) + i * 17u;
            if (out[i] == expected && in[i] == inputWord(i, seed)) continue;
            if (mismatches < 8) std::fprintf(stderr, "mismatch[%u]: expected=%08x actual=%08x input_intact=%s\n",
                                            i, expected, out[i], in[i] == inputWord(i, seed) ? "yes" : "no");
            ++mismatches;
        }
        if (mismatches) fail("Metal readback mismatch count=" + std::to_string(mismatches));
        const double milliseconds = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
        std::printf("round %u: verified=%u elapsed_ms=%.3f\n", round + 1, kCount, milliseconds);
    }
}
} // namespace

int main(int argc, char **argv)
{
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::setvbuf(stderr, nullptr, _IONBF, 0);
    try {
        const Options options = arguments(argc, argv);
        Deadline deadline(options.deadline);
        int result = 2;
        @autoreleasepool {
            @try {
                cleanEnvironment();
                std::printf("probe_version=1 scope=Metal-compute-readback-only deadline_s=%u\n", options.deadline);
                struct utsname system{};
                if (uname(&system) == 0) std::printf("os=%s release=%s machine=%s\n", system.sysname, system.release, system.machine);
                char version[128]{};
                size_t length = sizeof version;
                if (sysctlbyname("kern.osproductversion", version, &length, nullptr, 0) == 0)
                    std::printf("macOS=%s\n", version);
                std::puts("Kernel GPU submission/completion logs must corroborate any successful result.");
                compute(options);
                result = 0;
            } @catch (NSException *exception) {
                std::fprintf(stderr, "FAIL: Objective-C exception %s: %s\n", utf8(exception.name), utf8(exception.reason));
            }
        }
        if (result == 0) {
            std::printf("METAL_COMPUTE_READBACK_VERIFIED: vendor=8086 device=4680 rounds=%u total_words=%u\n",
                        kRounds, kCount * kRounds);
            std::puts("Scope: offscreen Metal compute only; rendering, display and WindowServer are untested.");
        }
        return result;
    } catch (const std::exception &error) {
        std::fprintf(stderr, "FAIL: %s\n", error.what());
        return 2;
    }
}
