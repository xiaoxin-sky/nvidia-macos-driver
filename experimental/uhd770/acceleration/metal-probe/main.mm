/*
 * Opt-in UHD 770 Metal compute or render/readback diagnostic. CI compiles this executable
 * without running it. Device selection is tied to NMXAccel's real PCI ancestry;
 * a pass still needs matching kernel execution logs, not a device-name claim.
 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOSurface/IOSurface.h>
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
constexpr uint32_t kSide = 64;
constexpr uint32_t kRenderRounds = 2;

[[noreturn]] void fail(const std::string &message) { throw std::runtime_error(message); }
const char *utf8(NSString *value) { return value ? value.UTF8String : "(nil)"; }

struct Options { std::string metallib; uint32_t deadline = 45; bool render = false; bool suite = false; };

Options arguments(int argc, char **argv)
{
    Options result;
    for (int i = 1; i < argc; ++i) {
        const std::string option = argv[i];
        if (option == "--help") {
            std::puts("Usage: uhd770-metal-probe --metallib PATH [--mode compute|render|suite] [--deadline 45]\n"
                      "Requires the matched diagnostic package. --help does not enumerate Metal or I/O Registry.\n"
                      "compute (default) submits three 4096-word Metal compute dispatches on UHD 770;\n"
                      "render draws a 64x64 offscreen triangle twice and reads every pixel back;\n"
                      "suite runs texture, blend, depth, 1920x1080 and IOSurface render subtests.");
            std::exit(0);
        }
        if (i + 1 >= argc) fail("Missing value for " + option);
        const char *value = argv[++i];
        if (option == "--metallib") result.metallib = value;
        else if (option == "--mode") {
            const std::string mode = value;
            if (mode == "render") result.render = true;
            else if (mode == "suite") result.suite = true;
            else if (mode != "compute") fail("--mode must be compute, render or suite");
        }
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
uint32_t expectedPixel(uint32_t x, uint32_t y)
{
    // RGBA8Unorm bytes (4x, 4y, 128, 255) read as one little-endian word.
    return (x * 4u) | ((y * 4u) << 8) | (128u << 16) | (255u << 24);
}

void render(const Options &options)
{
    Identity identity;
    id<MTLDevice> device = selectDevice(identity);
    NSError *error = nil;
    NSString *path = [[NSString alloc] initWithBytes:options.metallib.data() length:options.metallib.size()
                                          encoding:NSUTF8StringEncoding];
    if (!path) fail("--metallib path is not UTF-8");
    id<MTLLibrary> library = [device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
    if (!library) fail(std::string("Cannot load precompiled render metallib: ") + utf8(error.localizedDescription));
    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"render_vertex"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"render_fragment"];
    if (!vertexFunction || vertexFunction.functionType != MTLFunctionTypeVertex ||
        !fragmentFunction || fragmentFunction.functionType != MTLFunctionTypeFragment)
        fail("Metallib lacks the render_vertex/render_fragment functions");
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    error = nil;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline) fail(std::string("Cannot create Metal render pipeline: ") + utf8(error.localizedDescription));
    MTLTextureDescriptor *textureDescriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:kSide height:kSide
                                                       mipmapped:NO];
    textureDescriptor.usage = MTLTextureUsageRenderTarget;
    textureDescriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> target = [device newTextureWithDescriptor:textureDescriptor];
    if (!target) fail("Cannot allocate the 64x64 render target");
    const NSUInteger rowBytes = kSide * 4, bytes = rowBytes * kSide;
    id<MTLBuffer> readback = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    if (!readback || readback.length < bytes || readback.storageMode != MTLStorageModeShared || !readback.contents)
        fail("Cannot allocate a CPU-visible Metal readback buffer");
    id<MTLCommandQueue> queue = [device newCommandQueue];
    if (!queue) fail("Cannot create Metal command queue");
    queue.label = @"UHD770 opt-in render/readback diagnostic";
    std::printf("pipeline: render target=%ux%u RGBA8Unorm private, readback via blit\n", kSide, kSide);
    // A different clear each round: a draw that did not run leaves that clear
    // color behind, and a stale previous result cannot match this round's check.
    const MTLClearColor clears[kRenderRounds] = { MTLClearColorMake(1, 0, 0, 1), MTLClearColorMake(0, 1, 0, 1) };
    auto *pixels = static_cast<const uint8_t *>(readback.contents);
    for (uint32_t round = 0; round < kRenderRounds; ++round) {
        std::memset(readback.contents, 0xa5, bytes);
        id<MTLCommandBuffer> command = [queue commandBuffer];
        if (!command) fail("Cannot create Metal command buffer");
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor = clears[round];
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
        if (!encoder) fail("Cannot create Metal render encoder");
        [encoder setRenderPipelineState:pipeline];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
        if (!blit) fail("Cannot create Metal blit encoder");
        [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(kSide, kSide, 1) toBuffer:readback destinationOffset:0
       destinationBytesPerRow:rowBytes destinationBytesPerImage:bytes];
        [blit endEncoding];
        std::printf("dispatch %u: render triangle %ux%u clear=%s\n", round + 1, kSide, kSide, round ? "green" : "red");
        const auto started = std::chrono::steady_clock::now();
        @try {
            [command commit];
        } @catch (NSException *exception) {
            std::fprintf(stderr, "FAIL: commit exception %s: %s; abandoning teardown (exit 2).\n",
                         utf8(exception.name), utf8(exception.reason));
            std::fflush(nullptr);
            std::_Exit(2);
        }
        complete(command);
        uint32_t mismatches = 0;
        for (uint32_t y = 0; y < kSide; ++y) {
            for (uint32_t x = 0; x < kSide; ++x) {
                uint32_t actual = 0;
                std::memcpy(&actual, pixels + y * rowBytes + x * 4, sizeof actual);
                const uint32_t expected = expectedPixel(x, y);
                if (actual == expected) continue;
                if (mismatches < 8) std::fprintf(stderr, "mismatch[%u,%u]: expected=%08x actual=%08x\n",
                                                x, y, expected, actual);
                ++mismatches;
            }
        }
        if (mismatches) fail("Metal render readback mismatch count=" + std::to_string(mismatches));
        const double milliseconds = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
        std::printf("round %u: verified=%u pixels elapsed_ms=%.3f\n", round + 1, kSide * kSide, milliseconds);
    }
}

// ---- render suite: independent subtests, lowest risk first --------------------------------------------------------

struct SuiteContext {
    id<MTLDevice> device;
    id<MTLLibrary> library;
    id<MTLCommandQueue> queue;
    uint32_t dispatches = 0;
};

using PixelRule = uint32_t (*)(uint32_t x, uint32_t y);

uint32_t rgba(uint32_t r, uint32_t g, uint32_t b, uint32_t a) { return r | (g << 8) | (b << 16) | (a << 24); }
uint32_t textureSource(uint32_t x, uint32_t y) { return rgba(x * 3u, y * 3u, (x ^ y) & 255u, 255u); }
uint32_t blendResult(uint32_t, uint32_t) { return rgba(144u, 80u, 16u, 255u); }
uint32_t depthResult(uint32_t, uint32_t) { return rgba(0u, 0u, 255u, 255u); }
uint32_t coordinateResult(uint32_t x, uint32_t y) { return rgba(x & 255u, y & 255u, (x >> 8) * 16u + (y >> 8), 255u); }

id<MTLRenderPipelineState> suitePipeline(SuiteContext &context, NSString *vertexName, NSString *fragmentName,
                                         bool additive, bool depth)
{
    id<MTLFunction> vertexFunction = [context.library newFunctionWithName:vertexName];
    id<MTLFunction> fragmentFunction = [context.library newFunctionWithName:fragmentName];
    if (!vertexFunction || !fragmentFunction)
        fail(std::string("Suite metallib lacks ") + utf8(vertexName) + "/" + utf8(fragmentName));
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    if (additive) {
        descriptor.colorAttachments[0].blendingEnabled = YES;
        descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
        descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorZero;
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
    }
    if (depth) descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [context.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipeline) fail(std::string("Cannot create suite pipeline: ") + utf8(error.localizedDescription));
    return pipeline;
}

id<MTLTexture> suiteTexture(SuiteContext &context, MTLPixelFormat format, uint32_t width, uint32_t height,
                            MTLTextureUsage usage)
{
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width
                                                                                         height:height mipmapped:NO];
    descriptor.usage = usage;
    descriptor.storageMode = MTLStorageModePrivate;
    id<MTLTexture> texture = [context.device newTextureWithDescriptor:descriptor];
    if (!texture) fail("Cannot allocate a suite texture");
    return texture;
}

id<MTLBuffer> suiteBuffer(SuiteContext &context, NSUInteger bytes)
{
    id<MTLBuffer> buffer = [context.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    if (!buffer || buffer.length < bytes || !buffer.contents) fail("Cannot allocate a CPU-visible suite buffer");
    std::memset(buffer.contents, 0xa5, bytes);
    return buffer;
}

MTLRenderPassDescriptor *suitePass(id<MTLTexture> target, MTLClearColor clear)
{
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = clear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    return pass;
}

void suiteReadback(id<MTLCommandBuffer> command, id<MTLTexture> target, id<MTLBuffer> buffer)
{
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (!blit) fail("Cannot create Metal blit encoder");
    const NSUInteger rowBytes = target.width * 4;
    [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(target.width, target.height, 1) toBuffer:buffer destinationOffset:0
   destinationBytesPerRow:rowBytes destinationBytesPerImage:rowBytes * target.height];
    [blit endEncoding];
}

void suiteSubmit(SuiteContext &context, id<MTLCommandBuffer> command, const char *name)
{
    std::printf("dispatch %u: suite %s\n", ++context.dispatches, name);
    @try {
        [command commit];
    } @catch (NSException *exception) {
        std::fprintf(stderr, "FAIL: commit exception %s: %s; abandoning teardown (exit 2).\n",
                     utf8(exception.name), utf8(exception.reason));
        std::fflush(nullptr);
        std::_Exit(2);
    }
    complete(command);
}

uint32_t suiteVerify(const uint8_t *pixels, NSUInteger rowBytes, uint32_t width, uint32_t height, PixelRule rule,
                     const char *name)
{
    uint32_t mismatches = 0;
    for (uint32_t y = 0; y < height; ++y) {
        for (uint32_t x = 0; x < width; ++x) {
            uint32_t actual = 0;
            std::memcpy(&actual, pixels + y * rowBytes + x * 4, sizeof actual);
            const uint32_t expected = rule(x, y);
            if (actual == expected) continue;
            if (mismatches < 4) std::fprintf(stderr, "%s mismatch[%u,%u]: expected=%08x actual=%08x\n",
                                            name, x, y, expected, actual);
            ++mismatches;
        }
    }
    if (mismatches) fail(std::string(name) + " readback mismatch count=" + std::to_string(mismatches));
    return width * height;
}

uint32_t suiteTextureCase(SuiteContext &context)
{
    const uint32_t side = kSide;
    const NSUInteger rowBytes = side * 4, bytes = rowBytes * side;
    id<MTLBuffer> upload = suiteBuffer(context, bytes);
    auto *words = static_cast<uint32_t *>(upload.contents);
    for (uint32_t y = 0; y < side; ++y)
        for (uint32_t x = 0; x < side; ++x) words[y * side + x] = textureSource(x, y);
    id<MTLTexture> source = suiteTexture(context, MTLPixelFormatRGBA8Unorm, side, side, MTLTextureUsageShaderRead);
    id<MTLTexture> target = suiteTexture(context, MTLPixelFormatRGBA8Unorm, side, side, MTLTextureUsageRenderTarget);
    id<MTLBuffer> readback = suiteBuffer(context, bytes);
    id<MTLRenderPipelineState> pipeline = suitePipeline(context, @"suite_cover_vertex", @"suite_texture_fragment", false, false);
    id<MTLCommandBuffer> command = [context.queue commandBuffer];
    if (!command) fail("Cannot create Metal command buffer");
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (!blit) fail("Cannot create Metal blit encoder");
    [blit copyFromBuffer:upload sourceOffset:0 sourceBytesPerRow:rowBytes sourceBytesPerImage:bytes
              sourceSize:MTLSizeMake(side, side, 1) toTexture:source destinationSlice:0 destinationLevel:0
       destinationOrigin:MTLOriginMake(0, 0, 0)];
    [blit endEncoding];
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:suitePass(target, MTLClearColorMake(1, 0, 1, 1))];
    if (!encoder) fail("Cannot create Metal render encoder");
    [encoder setRenderPipelineState:pipeline];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    suiteReadback(command, target, readback);
    suiteSubmit(context, command, "texture");
    return suiteVerify(static_cast<const uint8_t *>(readback.contents), rowBytes, side, side, textureSource, "texture");
}

uint32_t suiteBlendCase(SuiteContext &context)
{
    const uint32_t side = kSide;
    const NSUInteger rowBytes = side * 4;
    id<MTLTexture> target = suiteTexture(context, MTLPixelFormatRGBA8Unorm, side, side, MTLTextureUsageRenderTarget);
    id<MTLBuffer> readback = suiteBuffer(context, rowBytes * side);
    id<MTLRenderPipelineState> pipeline = suitePipeline(context, @"suite_cover_vertex", @"suite_blend_fragment", true, false);
    id<MTLCommandBuffer> command = [context.queue commandBuffer];
    if (!command) fail("Cannot create Metal command buffer");
    const MTLClearColor clear = MTLClearColorMake(16.0 / 255.0, 16.0 / 255.0, 16.0 / 255.0, 1.0);
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:suitePass(target, clear)];
    if (!encoder) fail("Cannot create Metal render encoder");
    [encoder setRenderPipelineState:pipeline];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [encoder endEncoding];
    suiteReadback(command, target, readback);
    suiteSubmit(context, command, "blend");
    return suiteVerify(static_cast<const uint8_t *>(readback.contents), rowBytes, side, side, blendResult, "blend");
}

uint32_t suiteDepthCase(SuiteContext &context)
{
    const uint32_t side = kSide;
    const NSUInteger rowBytes = side * 4;
    id<MTLTexture> target = suiteTexture(context, MTLPixelFormatRGBA8Unorm, side, side, MTLTextureUsageRenderTarget);
    id<MTLTexture> depth = suiteTexture(context, MTLPixelFormatDepth32Float, side, side, MTLTextureUsageRenderTarget);
    id<MTLBuffer> readback = suiteBuffer(context, rowBytes * side);
    id<MTLRenderPipelineState> nearPipeline = suitePipeline(context, @"suite_depth_near_vertex", @"suite_color_fragment", false, true);
    id<MTLRenderPipelineState> farPipeline = suitePipeline(context, @"suite_depth_far_vertex", @"suite_color_fragment", false, true);
    MTLDepthStencilDescriptor *depthDescriptor = [[MTLDepthStencilDescriptor alloc] init];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionLess;
    depthDescriptor.depthWriteEnabled = YES;
    id<MTLDepthStencilState> depthState = [context.device newDepthStencilStateWithDescriptor:depthDescriptor];
    if (!depthState) fail("Cannot create depth state");
    id<MTLCommandBuffer> command = [context.queue commandBuffer];
    if (!command) fail("Cannot create Metal command buffer");
    MTLRenderPassDescriptor *pass = suitePass(target, MTLClearColorMake(1, 0, 0, 1));
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.clearDepth = 1.0;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    if (!encoder) fail("Cannot create Metal render encoder");
    [encoder setDepthStencilState:depthState];
    [encoder setRenderPipelineState:nearPipeline];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder setRenderPipelineState:farPipeline];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    suiteReadback(command, target, readback);
    suiteSubmit(context, command, "depth");
    return suiteVerify(static_cast<const uint8_t *>(readback.contents), rowBytes, side, side, depthResult, "depth");
}

uint32_t suiteLargeCase(SuiteContext &context)
{
    const uint32_t width = 1920, height = 1080;
    const NSUInteger rowBytes = width * 4;
    id<MTLTexture> target = suiteTexture(context, MTLPixelFormatRGBA8Unorm, width, height, MTLTextureUsageRenderTarget);
    id<MTLBuffer> readback = suiteBuffer(context, rowBytes * height);
    id<MTLRenderPipelineState> pipeline = suitePipeline(context, @"suite_cover_vertex", @"suite_coordinate_fragment", false, false);
    id<MTLCommandBuffer> command = [context.queue commandBuffer];
    if (!command) fail("Cannot create Metal command buffer");
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:suitePass(target, MTLClearColorMake(1, 0, 0, 1))];
    if (!encoder) fail("Cannot create Metal render encoder");
    [encoder setRenderPipelineState:pipeline];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    suiteReadback(command, target, readback);
    suiteSubmit(context, command, "large");
    return suiteVerify(static_cast<const uint8_t *>(readback.contents), rowBytes, width, height, coordinateResult, "large");
}

uint32_t suiteIOSurfaceCase(SuiteContext &context)
{
    // WindowServer composes into IOSurfaces; here the target is one, read back through the surface's own lock.
    const uint32_t side = kSide;
    NSDictionary *properties = @{
        (__bridge NSString *)kIOSurfaceWidth: @(side), (__bridge NSString *)kIOSurfaceHeight: @(side),
        (__bridge NSString *)kIOSurfaceBytesPerElement: @4, (__bridge NSString *)kIOSurfacePixelFormat: @(0x52474241u),
    };
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!surface) fail("Cannot create a 64x64 RGBA IOSurface");
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                          width:side height:side mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModeManaged;
    id<MTLTexture> target = [context.device newTextureWithDescriptor:descriptor iosurface:surface plane:0];
    if (!target) { CFRelease(surface); fail("Metal refused an IOSurface-backed render target"); }
    id<MTLRenderPipelineState> pipeline = suitePipeline(context, @"suite_cover_vertex", @"suite_coordinate_fragment", false, false);
    id<MTLCommandBuffer> command = [context.queue commandBuffer];
    if (!command) { CFRelease(surface); fail("Cannot create Metal command buffer"); }
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:suitePass(target, MTLClearColorMake(1, 0, 0, 1))];
    if (!encoder) { CFRelease(surface); fail("Cannot create Metal render encoder"); }
    [encoder setRenderPipelineState:pipeline];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (!blit) { CFRelease(surface); fail("Cannot create Metal blit encoder"); }
    [blit synchronizeResource:target];
    [blit endEncoding];
    suiteSubmit(context, command, "iosurface");
    if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr) != kIOReturnSuccess) {
        CFRelease(surface);
        fail("Cannot lock the IOSurface for CPU reading");
    }
    uint32_t verified = 0;
    std::string error;
    try {
        verified = suiteVerify(static_cast<const uint8_t *>(IOSurfaceGetBaseAddress(surface)), IOSurfaceGetBytesPerRow(surface),
                               side, side, coordinateResult, "iosurface");
    } catch (const std::exception &failure) {
        error = failure.what();
    }
    IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);
    CFRelease(surface);
    if (!error.empty()) fail(error);
    return verified;
}

// Returns the number of failed subtests. A GPU timeout inside complete() still ends the process (exit 124).
uint32_t suite(const Options &options)
{
    Identity identity;
    SuiteContext context;
    context.device = selectDevice(identity);
    NSError *error = nil;
    NSString *path = [[NSString alloc] initWithBytes:options.metallib.data() length:options.metallib.size()
                                          encoding:NSUTF8StringEncoding];
    if (!path) fail("--metallib path is not UTF-8");
    context.library = [context.device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
    if (!context.library) fail(std::string("Cannot load precompiled suite metallib: ") + utf8(error.localizedDescription));
    context.queue = [context.device newCommandQueue];
    if (!context.queue) fail("Cannot create Metal command queue");
    context.queue.label = @"UHD770 opt-in render suite diagnostic";
    const struct { const char *name; uint32_t (*run)(SuiteContext &); } cases[] = {
        {"texture", suiteTextureCase}, {"blend", suiteBlendCase}, {"depth", suiteDepthCase},
        {"large", suiteLargeCase}, {"iosurface", suiteIOSurfaceCase},
    };
    uint32_t failed = 0;
    for (const auto &item : cases) {
        const auto started = std::chrono::steady_clock::now();
        std::string failure;
        uint32_t verified = 0;
        @try {
            try {
                verified = item.run(context);
            } catch (const std::exception &caught) {
                failure = caught.what();
            }
        } @catch (NSException *exception) {
            failure = std::string("Objective-C exception ") + utf8(exception.name) + ": " + utf8(exception.reason);
        }
        const double milliseconds = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
        if (failure.empty()) {
            std::printf("subtest %s: PASS verified=%u pixels elapsed_ms=%.3f\n", item.name, verified, milliseconds);
        } else {
            ++failed;
            std::printf("subtest %s: FAIL %s\n", item.name, failure.c_str());
        }
    }
    return failed;
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
                std::printf("probe_version=1 scope=%s deadline_s=%u\n",
                            options.suite ? "Metal-render-suite-readback-only" :
                            options.render ? "Metal-render-readback-only" : "Metal-compute-readback-only", options.deadline);
                struct utsname system{};
                if (uname(&system) == 0) std::printf("os=%s release=%s machine=%s\n", system.sysname, system.release, system.machine);
                char version[128]{};
                size_t length = sizeof version;
                if (sysctlbyname("kern.osproductversion", version, &length, nullptr, 0) == 0)
                    std::printf("macOS=%s\n", version);
                std::puts("Kernel GPU submission/completion logs must corroborate any successful result.");
                if (options.suite) {
                    const uint32_t failed = suite(options);
                    if (failed) std::printf("METAL_RENDER_SUITE_FAILED: failed=%u of 5\n", failed);
                    result = failed ? 3 : 0;
                } else if (options.render) {
                    render(options);
                    result = 0;
                } else {
                    compute(options);
                    result = 0;
                }
            } @catch (NSException *exception) {
                std::fprintf(stderr, "FAIL: Objective-C exception %s: %s\n", utf8(exception.name), utf8(exception.reason));
            }
        }
        if (result == 0 && options.suite) {
            std::puts("METAL_RENDER_SUITE_VERIFIED: vendor=8086 device=4680 subtests=5");
            std::puts("Scope: offscreen texture/blend/depth/1920x1080/IOSurface render; display and WindowServer are untested.");
        } else if (result == 0 && options.render) {
            std::printf("METAL_RENDER_READBACK_VERIFIED: vendor=8086 device=4680 rounds=%u total_pixels=%u\n",
                        kRenderRounds, kSide * kSide * kRenderRounds);
            std::puts("Scope: one offscreen Metal triangle per round; display and WindowServer are untested.");
        } else if (result == 0) {
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
