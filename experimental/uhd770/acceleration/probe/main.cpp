/*
 * Opt-in Intel Vulkan compute/readback diagnostic. This exercises a caller-selected
 * loader/ICD only; it installs nothing and is never a CI runtime test. Device metadata
 * is a selection guard, not cryptographic proof of real GPU execution: correlate a
 * successful result with kernel submission/completion logs on the target machine.
 */
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <limits>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#else
#include <dlfcn.h>
#include <sys/utsname.h>
#ifdef __APPLE__
#include <sys/sysctl.h>
#endif
#endif

namespace {
struct Options {
    std::string loader, icd, shader;
    uint32_t device = 0x4680, count = 4099, iterations = 3, deadline = 45;
};

[[noreturn]] void fail(const std::string &message) { throw std::runtime_error(message); }
void check(VkResult result, const char *operation)
{
    if (result != VK_SUCCESS) fail(std::string(operation) + ": VkResult=" + std::to_string(result));
}

bool absolutePath(const std::string &path)
{
#ifdef _WIN32
    return path.size() > 2 && path[1] == ':' && (path[2] == '\\' || path[2] == '/');
#else
    return !path.empty() && path[0] == '/';
#endif
}

uint32_t parseNumber(const char *text, uint32_t low, uint32_t high)
{
    if (!text[0] || text[0] == '-') fail("Invalid numeric option");
    size_t consumed = 0;
    unsigned long value = std::stoul(text, &consumed, 0);
    if (text[consumed] || value < low || value > high) fail("Numeric option out of range");
    return static_cast<uint32_t>(value);
}

Options options(int argc, char **argv)
{
    Options o;
    for (int i = 1; i < argc; ++i) {
        const std::string name = argv[i];
        if (name == "--help") {
            std::puts("Usage: uhd770-compute-probe --loader ABS_PATH --icd ABS_JSON --shader PATH\n"
                      "       [--device-id 0x4680] [--count 4099] [--iterations 3] [--deadline 45]\n"
                      "No installation or GPU operation occurs with --help. Other runs submit GPU work.");
            std::exit(0);
        }
        if (i + 1 >= argc) fail("Missing value for " + name);
        const char *value = argv[++i];
        if (name == "--loader") o.loader = value;
        else if (name == "--icd") o.icd = value;
        else if (name == "--shader") o.shader = value;
        else if (name == "--device-id") o.device = parseNumber(value, 1, 0xffff);
        else if (name == "--count") o.count = parseNumber(value, 1, 1048576);
        else if (name == "--iterations") o.iterations = parseNumber(value, 1, 32);
        else if (name == "--deadline") o.deadline = parseNumber(value, 5, 120);
        else fail("Unknown option " + name);
    }
    if (!absolutePath(o.loader) || !absolutePath(o.icd) || o.shader.empty())
        fail("Explicit absolute --loader and --icd paths, plus --shader, are required");
    return o;
}

void environment(const char *name, const char *value)
{
#ifdef _WIN32
    if (_putenv_s(name, value)) fail(std::string("Cannot set ") + name);
#else
    if (setenv(name, value, 1)) fail(std::string("Cannot set ") + name);
#endif
}

// Includes teardown in the deadline: a driver can block in calls other than fence wait.
class Deadline {
    std::atomic<bool> finished{false};
    std::thread worker;
public:
    explicit Deadline(uint32_t seconds) : worker([this, seconds] {
        const auto end = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
        while (!finished.load(std::memory_order_acquire)) {
            if (std::chrono::steady_clock::now() >= end) {
                std::fputs("FAIL: overall deadline exceeded; abandoning driver teardown (exit 124).\n", stderr);
                std::fflush(nullptr);
                std::_Exit(124);
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
        }
    }) {}
    ~Deadline() { finished.store(true, std::memory_order_release); worker.join(); }
};

class Library {
#ifdef _WIN32
    HMODULE handle = nullptr;
#else
    void *handle = nullptr;
#endif
public:
    explicit Library(const char *path)
    {
#ifdef _WIN32
        handle = LoadLibraryA(path);
#else
        handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
#endif
        if (!handle) fail("Could not open explicitly selected Vulkan loader");
    }
    ~Library()
    {
#ifdef _WIN32
        FreeLibrary(handle);
#else
        dlclose(handle);
#endif
    }
    PFN_vkGetInstanceProcAddr entry() const
    {
#ifdef _WIN32
        const auto address = GetProcAddress(handle, "vkGetInstanceProcAddr");
        PFN_vkGetInstanceProcAddr p = nullptr;
        static_assert(sizeof(p) == sizeof(address), "Windows function pointer size mismatch");
        std::memcpy(&p, &address, sizeof(p));
#else
        auto p = reinterpret_cast<PFN_vkGetInstanceProcAddr>(dlsym(handle, "vkGetInstanceProcAddr"));
#endif
        if (!p) fail("Loader has no vkGetInstanceProcAddr");
        return p;
    }
};

#define INSTANCE_FUNCTIONS(X) \
    X(DestroyInstance) X(EnumeratePhysicalDevices) X(GetPhysicalDeviceProperties) \
    X(GetPhysicalDeviceProperties2) X(EnumerateDeviceExtensionProperties) \
    X(GetPhysicalDeviceQueueFamilyProperties) X(GetPhysicalDeviceMemoryProperties) \
    X(CreateDevice) X(GetDeviceProcAddr)
#define DEVICE_FUNCTIONS(X) \
    X(DestroyDevice) X(GetDeviceQueue) X(CreateBuffer) X(DestroyBuffer) \
    X(GetBufferMemoryRequirements) X(AllocateMemory) X(FreeMemory) X(BindBufferMemory) \
    X(MapMemory) X(UnmapMemory) X(FlushMappedMemoryRanges) X(InvalidateMappedMemoryRanges) \
    X(CreateDescriptorSetLayout) X(DestroyDescriptorSetLayout) X(CreatePipelineLayout) \
    X(DestroyPipelineLayout) X(CreateShaderModule) X(DestroyShaderModule) \
    X(CreateComputePipelines) X(DestroyPipeline) X(CreateDescriptorPool) X(DestroyDescriptorPool) \
    X(AllocateDescriptorSets) X(UpdateDescriptorSets) X(CreateCommandPool) X(DestroyCommandPool) \
    X(AllocateCommandBuffers) X(ResetCommandBuffer) X(BeginCommandBuffer) X(EndCommandBuffer) \
    X(CmdPipelineBarrier) X(CmdBindPipeline) X(CmdBindDescriptorSets) X(CmdPushConstants) \
    X(CmdDispatch) X(CreateFence) X(DestroyFence) X(ResetFences) X(QueueSubmit) X(WaitForFences)

struct Context {
    VkInstance instance = VK_NULL_HANDLE;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkQueue queue = VK_NULL_HANDLE;
    VkDebugUtilsMessengerEXT diagnostic = VK_NULL_HANDLE;
    PFN_vkDestroyDebugUtilsMessengerEXT destroyDiagnostic = nullptr;
    uint32_t family = 0;
    VkPhysicalDeviceProperties properties{};
    VkPhysicalDeviceMemoryProperties memory{};
#define FIELD(name) PFN_vk##name name = nullptr;
    INSTANCE_FUNCTIONS(FIELD)
    DEVICE_FUNCTIONS(FIELD)
#undef FIELD
    ~Context()
    {
        if (device && DestroyDevice) DestroyDevice(device, nullptr);
        if (diagnostic && destroyDiagnostic) destroyDiagnostic(instance, diagnostic, nullptr);
        if (instance && DestroyInstance) DestroyInstance(instance, nullptr);
    }
};

// Capture the driver's explanation of initialization failures, including errors
// before device enumeration succeeds. This callback observes only and must never
// abort an API call. No validation layer or global driver configuration is used.
VKAPI_ATTR VkBool32 VKAPI_CALL diagnosticMessage(
    VkDebugUtilsMessageSeverityFlagBitsEXT severity, VkDebugUtilsMessageTypeFlagsEXT,
    const VkDebugUtilsMessengerCallbackDataEXT *data, void *)
{
    std::fprintf(stderr, "VULKAN_DIAGNOSTIC severity=0x%x id=%.256s message=%.4096s\n",
                 static_cast<unsigned>(severity),
                 data && data->pMessageIdName ? data->pMessageIdName : "unknown",
                 data && data->pMessage ? data->pMessage : "no message");
    return VK_FALSE;
}

// Optional instance diagnostics must not become another prerequisite for GPU
// discovery. The caller still checks every Vulkan result and candidate identity.
bool supportsDiagnostics(PFN_vkGetInstanceProcAddr get)
{
    const auto enumerate = reinterpret_cast<PFN_vkEnumerateInstanceExtensionProperties>(
        get(VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties"));
    uint32_t count = 0;
    if (!enumerate || enumerate(nullptr, &count, nullptr) != VK_SUCCESS || count > 512)
        return false;
    std::vector<VkExtensionProperties> extensions(count);
    if (enumerate(nullptr, &count, extensions.data()) != VK_SUCCESS) return false;
    for (const auto &item : extensions)
        if (std::strcmp(item.extensionName, VK_EXT_DEBUG_UTILS_EXTENSION_NAME) == 0) return true;
    return false;
}

void createInstance(Context &c, PFN_vkGetInstanceProcAddr get)
{
    const auto version = reinterpret_cast<PFN_vkEnumerateInstanceVersion>(get(VK_NULL_HANDLE, "vkEnumerateInstanceVersion"));
    uint32_t api = VK_API_VERSION_1_0;
    if (version) check(version(&api), "vkEnumerateInstanceVersion");
    if (api < VK_API_VERSION_1_1) fail("Vulkan 1.1 loader is required");
    const auto create = reinterpret_cast<PFN_vkCreateInstance>(get(VK_NULL_HANDLE, "vkCreateInstance"));
    if (!create) fail("Loader has no vkCreateInstance");
    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "UHD770 real compute/readback probe";
    app.applicationVersion = 1;
    app.apiVersion = VK_API_VERSION_1_1;
    VkInstanceCreateInfo info{};
    info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    info.pApplicationInfo = &app;
    const bool diagnostics = supportsDiagnostics(get);
    const char *diagnosticExtension = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    VkDebugUtilsMessengerCreateInfoEXT diagnostic{};
    diagnostic.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT;
    diagnostic.messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                                 VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    diagnostic.messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                             VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                             VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT;
    diagnostic.pfnUserCallback = diagnosticMessage;
    if (diagnostics) {
        info.enabledExtensionCount = 1;
        info.ppEnabledExtensionNames = &diagnosticExtension;
        info.pNext = &diagnostic;
    }
    check(create(&info, nullptr, &c.instance), "vkCreateInstance");
#define LOAD(name) c.name = reinterpret_cast<PFN_vk##name>(get(c.instance, "vk" #name)); \
    if (!c.name) fail("Missing instance function vk" #name);
    INSTANCE_FUNCTIONS(LOAD)
#undef LOAD
    if (diagnostics) {
        const auto attach = reinterpret_cast<PFN_vkCreateDebugUtilsMessengerEXT>(
            get(c.instance, "vkCreateDebugUtilsMessengerEXT"));
        c.destroyDiagnostic = reinterpret_cast<PFN_vkDestroyDebugUtilsMessengerEXT>(
            get(c.instance, "vkDestroyDebugUtilsMessengerEXT"));
        if (attach && c.destroyDiagnostic) {
            const VkResult result = attach(c.instance, &diagnostic, nullptr, &c.diagnostic);
            if (result != VK_SUCCESS) c.diagnostic = VK_NULL_HANDLE;
            std::printf("debug_utils_attach=%d\n", result);
        }
    }
    std::printf("debug_utils=%s\n", c.diagnostic ? "active" : "unavailable");
}

bool extension(const std::vector<VkExtensionProperties> &items, const char *name)
{
    for (const auto &item : items) if (std::strcmp(item.extensionName, name) == 0) return true;
    return false;
}

void selectDevice(Context &c, const Options &o)
{
    uint32_t count = 0;
    check(c.EnumeratePhysicalDevices(c.instance, &count, nullptr), "enumerate physical count");
    if (!count || count > 256) fail("Unexpected physical device count");
    std::vector<VkPhysicalDevice> devices(count);
    check(c.EnumeratePhysicalDevices(c.instance, &count, devices.data()), "enumerate physical devices");
    uint32_t matches = 0;
    for (uint32_t i = 0; i < count; ++i) {
        VkPhysicalDeviceProperties p{};
        c.GetPhysicalDeviceProperties(devices[i], &p);
        std::printf("enumerated: vendor=%04x device=%04x type=%u name=%s\n",
                    p.vendorID, p.deviceID, static_cast<unsigned>(p.deviceType), p.deviceName);
        if (p.vendorID != 0x8086 || p.deviceID != o.device || p.deviceType != VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU)
            continue;
        if (p.apiVersion < VK_API_VERSION_1_1) fail("Selected device lacks Vulkan 1.1");
        uint32_t n = 0;
        check(c.EnumerateDeviceExtensionProperties(devices[i], nullptr, &n, nullptr), "device extension count");
        std::vector<VkExtensionProperties> extensions(n);
        check(c.EnumerateDeviceExtensionProperties(devices[i], nullptr, &n, extensions.data()), "device extensions");
        if (p.apiVersion < VK_API_VERSION_1_2 && !extension(extensions, VK_KHR_DRIVER_PROPERTIES_EXTENSION_NAME))
            fail("Cannot verify driver ID: VK_KHR_driver_properties is missing");
        VkPhysicalDeviceDriverProperties driver{};
        driver.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES;
        VkPhysicalDevicePCIBusInfoPropertiesEXT pci{};
        pci.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PCI_BUS_INFO_PROPERTIES_EXT;
        const bool hasPci = extension(extensions, VK_EXT_PCI_BUS_INFO_EXTENSION_NAME);
        if (hasPci) driver.pNext = &pci;
        VkPhysicalDeviceProperties2 props{};
        props.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
        props.pNext = &driver;
        c.GetPhysicalDeviceProperties2(devices[i], &props);
        std::printf("selected metadata: driverID=%u name=%s info=%s api=%u.%u.%u driverVersion=0x%08x\n",
                    static_cast<unsigned>(driver.driverID), driver.driverName, driver.driverInfo,
                    VK_API_VERSION_MAJOR(p.apiVersion), VK_API_VERSION_MINOR(p.apiVersion),
                    VK_API_VERSION_PATCH(p.apiVersion), p.driverVersion);
        if (driver.driverID != VK_DRIVER_ID_INTEL_OPEN_SOURCE_MESA)
            fail("Only Mesa Intel ANV is accepted; software, translation and other driver paths are rejected");
        if (hasPci) std::printf("pci BDF: %04x:%02x:%02x.%u\n", pci.pciDomain, pci.pciBus, pci.pciDevice, pci.pciFunction);
        else std::puts("pci BDF: unavailable (vendor/device identity above is driver-reported)");
        c.physical = devices[i];
        c.properties = p;
        ++matches;
    }
    if (matches != 1) fail("Expected exactly one matching integrated Intel device; matches=" + std::to_string(matches));
    const auto &limits = c.properties.limits;
    if (limits.maxComputeWorkGroupInvocations < 64 || limits.maxComputeWorkGroupSize[0] < 64 ||
        limits.maxComputeWorkGroupCount[0] < (o.count + 63) / 64 ||
        limits.maxStorageBufferRange < static_cast<VkDeviceSize>(o.count) * sizeof(uint32_t) || limits.maxPushConstantsSize < 8)
        fail("Selected device limits cannot execute this probe");
    uint32_t n = 0;
    c.GetPhysicalDeviceQueueFamilyProperties(c.physical, &n, nullptr);
    std::vector<VkQueueFamilyProperties> queues(n);
    c.GetPhysicalDeviceQueueFamilyProperties(c.physical, &n, queues.data());
    bool found = false;
    for (uint32_t i = 0; i < n; ++i) if (queues[i].queueCount && (queues[i].queueFlags & VK_QUEUE_COMPUTE_BIT)) {
        c.family = i; found = true; break;
    }
    if (!found) fail("No compute queue family");
    c.GetPhysicalDeviceMemoryProperties(c.physical, &c.memory);
}

void createDevice(Context &c)
{
    const float priority = 1.0f;
    VkDeviceQueueCreateInfo queue{};
    queue.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue.queueFamilyIndex = c.family; queue.queueCount = 1; queue.pQueuePriorities = &priority;
    VkDeviceCreateInfo info{};
    info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    info.queueCreateInfoCount = 1; info.pQueueCreateInfos = &queue;
    check(c.CreateDevice(c.physical, &info, nullptr, &c.device), "vkCreateDevice");
#define LOAD(name) c.name = reinterpret_cast<PFN_vk##name>(c.GetDeviceProcAddr(c.device, "vk" #name)); \
    if (!c.name) fail("Missing device function vk" #name);
    DEVICE_FUNCTIONS(LOAD)
#undef LOAD
    c.GetDeviceQueue(c.device, c.family, 0, &c.queue);
    if (!c.queue) fail("Null compute queue");
}

struct Buffer {
    Context &c;
    VkBuffer buffer = VK_NULL_HANDLE;
    VkDeviceMemory memory = VK_NULL_HANDLE;
    void *mapped = nullptr;
    bool coherent = false;
    explicit Buffer(Context &context) : c(context) {}
    ~Buffer()
    {
        if (mapped) c.UnmapMemory(c.device, memory);
        if (buffer) c.DestroyBuffer(c.device, buffer, nullptr);
        if (memory) c.FreeMemory(c.device, memory, nullptr);
    }
    void allocate(VkDeviceSize size)
    {
        VkBufferCreateInfo info{};
        info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = size; info.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT; info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
        check(c.CreateBuffer(c.device, &info, nullptr, &buffer), "vkCreateBuffer");
        VkMemoryRequirements requirements{};
        c.GetBufferMemoryRequirements(c.device, buffer, &requirements);
        uint32_t chosen = UINT32_MAX;
        for (uint32_t i = 0; i < c.memory.memoryTypeCount; ++i) {
            const auto flags = c.memory.memoryTypes[i].propertyFlags;
            if (!(requirements.memoryTypeBits & (1u << i)) || !(flags & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)) continue;
            chosen = i;
            if (flags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) break;
        }
        if (chosen == UINT32_MAX) fail("No HOST_VISIBLE storage buffer memory type");
        coherent = (c.memory.memoryTypes[chosen].propertyFlags & VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) != 0;
        VkMemoryAllocateInfo allocation{};
        allocation.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocation.allocationSize = requirements.size; allocation.memoryTypeIndex = chosen;
        check(c.AllocateMemory(c.device, &allocation, nullptr, &memory), "vkAllocateMemory");
        check(c.BindBufferMemory(c.device, buffer, memory, 0), "vkBindBufferMemory");
        check(c.MapMemory(c.device, memory, 0, VK_WHOLE_SIZE, 0, &mapped), "vkMapMemory");
        std::printf("buffer: bytes=%llu allocation=%llu memoryType=%u coherent=%s\n",
                    static_cast<unsigned long long>(size), static_cast<unsigned long long>(requirements.size), chosen, coherent ? "yes" : "no");
    }
    void hostTransfer(bool invalidate)
    {
        if (coherent) return;
        VkMappedMemoryRange range{};
        range.sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
        range.memory = memory; range.offset = 0; range.size = VK_WHOLE_SIZE;
        check(invalidate ? c.InvalidateMappedMemoryRanges(c.device, 1, &range) : c.FlushMappedMemoryRanges(c.device, 1, &range),
              invalidate ? "vkInvalidateMappedMemoryRanges" : "vkFlushMappedMemoryRanges");
    }
};

std::vector<uint32_t> loadShader(const std::string &path)
{
    std::ifstream file(path, std::ios::binary | std::ios::ate);
    if (!file) fail("Cannot open --shader file");
    const auto size = file.tellg();
    if (size < 20 || size > 1048576 || size % 4 != 0) fail("Invalid SPIR-V byte length");
    std::vector<uint32_t> words(static_cast<size_t>(size) / 4);
    file.seekg(0);
    if (!file.read(reinterpret_cast<char *>(words.data()), static_cast<std::streamsize>(size))) fail("Cannot read SPIR-V");
    if (words[0] != 0x07230203) fail("Shader is not native-endian SPIR-V");
    return words;
}

struct Program {
    Context &c;
    VkDescriptorSetLayout descriptors = VK_NULL_HANDLE;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    VkShaderModule shader = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkDescriptorPool descriptorPool = VK_NULL_HANDLE;
    VkCommandPool commandPool = VK_NULL_HANDLE;
    VkFence fence = VK_NULL_HANDLE;
    explicit Program(Context &context) : c(context) {}
    ~Program()
    {
        if (fence) c.DestroyFence(c.device, fence, nullptr);
        if (commandPool) c.DestroyCommandPool(c.device, commandPool, nullptr);
        if (descriptorPool) c.DestroyDescriptorPool(c.device, descriptorPool, nullptr);
        if (pipeline) c.DestroyPipeline(c.device, pipeline, nullptr);
        if (shader) c.DestroyShaderModule(c.device, shader, nullptr);
        if (layout) c.DestroyPipelineLayout(c.device, layout, nullptr);
        if (descriptors) c.DestroyDescriptorSetLayout(c.device, descriptors, nullptr);
    }
};

uint32_t uploaded(uint32_t i, uint32_t seed) { return seed ^ (i * 747796405u + 2891336453u); }
uint32_t expected(uint32_t i, uint32_t seed)
{
    const uint32_t input = uploaded(i, seed), value = input ^ seed, shift = i % 31u + 1u;
    return (((value << shift) | (value >> (32u - shift))) + i * 0x9e3779b9u) ^ (input >> 7u);
}

void run(Context &c, const Options &o, const std::vector<uint32_t> &code)
{
    const VkDeviceSize bytes = static_cast<VkDeviceSize>(o.count) * sizeof(uint32_t);
    Buffer input(c), output(c);
    input.allocate(bytes); output.allocate(bytes);
    Program p(c);
    VkDescriptorSetLayoutBinding bindings[2]{};
    for (uint32_t i = 0; i < 2; ++i) {
        bindings[i].binding = i; bindings[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        bindings[i].descriptorCount = 1; bindings[i].stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
    }
    VkDescriptorSetLayoutCreateInfo descriptorInfo{};
    descriptorInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    descriptorInfo.bindingCount = 2; descriptorInfo.pBindings = bindings;
    check(c.CreateDescriptorSetLayout(c.device, &descriptorInfo, nullptr, &p.descriptors), "vkCreateDescriptorSetLayout");
    VkPushConstantRange push{VK_SHADER_STAGE_COMPUTE_BIT, 0, 8};
    VkPipelineLayoutCreateInfo layout{};
    layout.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    layout.setLayoutCount = 1; layout.pSetLayouts = &p.descriptors; layout.pushConstantRangeCount = 1; layout.pPushConstantRanges = &push;
    check(c.CreatePipelineLayout(c.device, &layout, nullptr, &p.layout), "vkCreatePipelineLayout");
    VkShaderModuleCreateInfo module{};
    module.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    module.codeSize = code.size() * sizeof(uint32_t); module.pCode = code.data();
    check(c.CreateShaderModule(c.device, &module, nullptr, &p.shader), "vkCreateShaderModule");
    VkComputePipelineCreateInfo pipeline{};
    pipeline.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
    pipeline.layout = p.layout; pipeline.stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    pipeline.stage.stage = VK_SHADER_STAGE_COMPUTE_BIT; pipeline.stage.module = p.shader; pipeline.stage.pName = "main";
    check(c.CreateComputePipelines(c.device, VK_NULL_HANDLE, 1, &pipeline, nullptr, &p.pipeline), "vkCreateComputePipelines");
    VkDescriptorPoolSize poolSize{VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 2};
    VkDescriptorPoolCreateInfo pool{};
    pool.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    pool.maxSets = 1; pool.poolSizeCount = 1; pool.pPoolSizes = &poolSize;
    check(c.CreateDescriptorPool(c.device, &pool, nullptr, &p.descriptorPool), "vkCreateDescriptorPool");
    VkDescriptorSet set = VK_NULL_HANDLE;
    VkDescriptorSetAllocateInfo allocate{};
    allocate.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    allocate.descriptorPool = p.descriptorPool; allocate.descriptorSetCount = 1; allocate.pSetLayouts = &p.descriptors;
    check(c.AllocateDescriptorSets(c.device, &allocate, &set), "vkAllocateDescriptorSets");
    VkDescriptorBufferInfo buffers[2]{{input.buffer, 0, bytes}, {output.buffer, 0, bytes}};
    VkWriteDescriptorSet writes[2]{};
    for (uint32_t i = 0; i < 2; ++i) {
        writes[i].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET; writes[i].dstSet = set; writes[i].dstBinding = i;
        writes[i].descriptorCount = 1; writes[i].descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_BUFFER; writes[i].pBufferInfo = &buffers[i];
    }
    c.UpdateDescriptorSets(c.device, 2, writes, 0, nullptr);
    VkCommandPoolCreateInfo commandPool{};
    commandPool.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    commandPool.queueFamilyIndex = c.family; commandPool.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    check(c.CreateCommandPool(c.device, &commandPool, nullptr, &p.commandPool), "vkCreateCommandPool");
    VkCommandBuffer command = VK_NULL_HANDLE;
    VkCommandBufferAllocateInfo commandInfo{};
    commandInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    commandInfo.commandPool = p.commandPool; commandInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; commandInfo.commandBufferCount = 1;
    check(c.AllocateCommandBuffers(c.device, &commandInfo, &command), "vkAllocateCommandBuffers");
    VkFenceCreateInfo fence{};
    fence.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    check(c.CreateFence(c.device, &fence, nullptr, &p.fence), "vkCreateFence");
    uint64_t verified = 0;
    for (uint32_t iteration = 0; iteration < o.iterations; ++iteration) {
        const uint32_t seed = 0x13579bdfu + iteration * 0x6d2b79f5u;
        auto *in = static_cast<uint32_t *>(input.mapped), *out = static_cast<uint32_t *>(output.mapped);
        for (uint32_t i = 0; i < o.count; ++i) { in[i] = uploaded(i, seed); out[i] = 0xcdcdcdcdu ^ iteration; }
        input.hostTransfer(false); output.hostTransfer(false);
        check(c.ResetCommandBuffer(command, 0), "vkResetCommandBuffer");
        VkCommandBufferBeginInfo begin{};
        begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        check(c.BeginCommandBuffer(command, &begin), "vkBeginCommandBuffer");
        VkMemoryBarrier upload{};
        upload.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        upload.srcAccessMask = VK_ACCESS_HOST_WRITE_BIT; upload.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_SHADER_WRITE_BIT;
        c.CmdPipelineBarrier(command, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &upload, 0, nullptr, 0, nullptr);
        c.CmdBindPipeline(command, VK_PIPELINE_BIND_POINT_COMPUTE, p.pipeline);
        c.CmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_COMPUTE, p.layout, 0, 1, &set, 0, nullptr);
        const uint32_t constants[2]{o.count, seed};
        c.CmdPushConstants(command, p.layout, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(constants), constants);
        c.CmdDispatch(command, (o.count + 63) / 64, 1, 1);
        VkMemoryBarrier download{};
        download.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        download.srcAccessMask = VK_ACCESS_SHADER_WRITE_BIT; download.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
        c.CmdPipelineBarrier(command, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &download, 0, nullptr, 0, nullptr);
        check(c.EndCommandBuffer(command), "vkEndCommandBuffer");
        check(c.ResetFences(c.device, 1, &p.fence), "vkResetFences");
        VkSubmitInfo submit{};
        submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit.commandBufferCount = 1; submit.pCommandBuffers = &command;
        std::printf("dispatch %u: seed=0x%08x words=%u groups=%u\n", iteration + 1, seed, o.count, (o.count + 63) / 64);
        const auto start = std::chrono::steady_clock::now();
        const VkResult submitted = c.QueueSubmit(c.queue, 1, &submit, p.fence);
        // A failed submit has unspecified partial driver progress. Avoid destroying
        // potentially in-flight resources or waiting forever during error cleanup.
        if (submitted != VK_SUCCESS) {
            std::fprintf(stderr, "FAIL: vkQueueSubmit=%d; abandoning teardown (exit 2).\n", submitted);
            std::fflush(nullptr); std::_Exit(2);
        }
        const VkResult completed = c.WaitForFences(c.device, 1, &p.fence, VK_TRUE, 10000000000ull);
        if (completed != VK_SUCCESS) {
            std::fprintf(stderr, "FAIL: fence result=%d; abandoning in-flight teardown (exit %d).\n", completed, completed == VK_TIMEOUT ? 124 : 2);
            std::fflush(nullptr); std::_Exit(completed == VK_TIMEOUT ? 124 : 2);
        }
        output.hostTransfer(true);
        uint32_t mismatches = 0;
        for (uint32_t i = 0; i < o.count; ++i) if (out[i] != expected(i, seed)) {
            if (mismatches < 8) std::fprintf(stderr, "mismatch[%u]: expected=%08x actual=%08x\n", i, expected(i, seed), out[i]);
            ++mismatches;
        }
        if (mismatches) fail("Readback mismatch count=" + std::to_string(mismatches));
        verified += o.count;
        const auto elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
        std::printf("iteration %u: verified=%u elapsed_ms=%.3f\n", iteration + 1, o.count, elapsed);
    }
    std::printf("COMPUTE_READBACK_VERIFIED: vendor=8086 device=%04x iterations=%u total_words=%llu\n",
                o.device, o.iterations, static_cast<unsigned long long>(verified));
    std::puts("Scope: selected ANV compute/readback only. Metal, scanout and WindowServer are untested.");
}
} // namespace

int main(int argc, char **argv)
{
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::setvbuf(stderr, nullptr, _IONBF, 0);
    try {
        const Options o = options(argc, argv);
        const auto shader = loadShader(o.shader);
        Deadline deadline(o.deadline);
        environment("VK_DRIVER_FILES", o.icd.c_str());
        environment("VK_ICD_FILENAMES", o.icd.c_str());
        environment("VK_INSTANCE_LAYERS", "");
        environment("VK_LOADER_LAYERS_DISABLE", "~all~");
        environment("VK_LOADER_DEBUG", "error,warn,driver");
        std::printf("probe_version=1 loader=%s icd=%s shader=%s deadline_s=%u\n",
                    o.loader.c_str(), o.icd.c_str(), o.shader.c_str(), o.deadline);
#ifndef _WIN32
        struct utsname system{};
        if (uname(&system) == 0) std::printf("os=%s release=%s machine=%s\n", system.sysname, system.release, system.machine);
#ifdef __APPLE__
        char productVersion[128]{};
        size_t productVersionLength = sizeof(productVersion);
        if (sysctlbyname("kern.osproductversion", productVersion, &productVersionLength, nullptr, 0) == 0)
            std::printf("macOS=%s\n", productVersion);
#endif
#endif
        std::puts("Identity is driver-reported. Correlate successful dispatch/readback with target kernel logs.");
        Library library(o.loader.c_str());
        Context context;
        createInstance(context, library.entry());
        selectDevice(context, o);
        createDevice(context);
        run(context, o, shader);
        return 0;
    } catch (const std::exception &e) {
        std::fprintf(stderr, "FAIL: %s\n", e.what());
        return 2;
    }
}
