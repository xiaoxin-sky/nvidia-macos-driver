/* Exercise the real instance/probe diagnostics against fake Vulkan entrypoints.
 * No loader, ICD, kernel driver or GPU is opened. The failure path must expose
 * the driver's message, retain its failure, and destroy diagnostics first. */
#define main uhd770_unused_probe_main
#include "../probe/main.cpp"
#undef main
#include <cassert>

static bool offerDebug = true, failAttach = false;
static unsigned callbacks = 0, instancesDestroyed = 0, diagnosticsDestroyed = 0;
static PFN_vkDebugUtilsMessengerCallbackEXT observed = nullptr;
static VkResult VKAPI_CALL mockVersion(uint32_t *version)
{ *version = VK_API_VERSION_1_1; return VK_SUCCESS; }
static VkResult VKAPI_CALL mockExtensions(const char *, uint32_t *count, VkExtensionProperties *properties)
{
    if (properties && offerDebug)
        std::memcpy(properties[0].extensionName, VK_EXT_DEBUG_UTILS_EXTENSION_NAME,
                    sizeof(VK_EXT_DEBUG_UTILS_EXTENSION_NAME));
    *count = offerDebug ? 1 : 0;
    return VK_SUCCESS;
}
static VkResult VKAPI_CALL mockCreate(const VkInstanceCreateInfo *info, const VkAllocationCallbacks *, VkInstance *instance)
{
    assert(info->enabledLayerCount == 0);
    assert(info->enabledExtensionCount == (offerDebug ? 1u : 0u));
    assert(bool(info->pNext) == offerDebug);
    *instance = reinterpret_cast<VkInstance>(uintptr_t(1));
    return VK_SUCCESS;
}
static VkResult VKAPI_CALL mockAttach(VkInstance, const VkDebugUtilsMessengerCreateInfoEXT *info,
                                     const VkAllocationCallbacks *, VkDebugUtilsMessengerEXT *messenger)
{
    *messenger = reinterpret_cast<VkDebugUtilsMessengerEXT>(uintptr_t(2));
    if (failAttach) return VK_ERROR_OUT_OF_HOST_MEMORY;
    observed = info->pfnUserCallback;
    return VK_SUCCESS;
}
static void VKAPI_CALL mockDestroyDiagnostic(VkInstance, VkDebugUtilsMessengerEXT, const VkAllocationCallbacks *)
{ ++diagnosticsDestroyed; observed = nullptr; }
static void VKAPI_CALL mockDestroyInstance(VkInstance, const VkAllocationCallbacks *)
{ assert(observed == nullptr); ++instancesDestroyed; }
static VkResult VKAPI_CALL mockPhysical(VkInstance, uint32_t *, VkPhysicalDevice *)
{
    if (observed) {
        VkDebugUtilsMessengerCallbackDataEXT data{};
        data.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CALLBACK_DATA_EXT;
        data.pMessageIdName = "fixture-enumeration";
        data.pMessage = "mock initialization reason retained; no GPU executed";
        assert(observed(VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
                        VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT, &data, nullptr) == VK_FALSE);
        ++callbacks;
    }
    return VK_ERROR_INITIALIZATION_FAILED;
}
static void VKAPI_CALL unusedEntry() { assert(false); }
static PFN_vkVoidFunction VKAPI_CALL mockGet(VkInstance, const char *name)
{
#define ENTRY(n, f) if (std::strcmp(name, n) == 0) return reinterpret_cast<PFN_vkVoidFunction>(f)
    ENTRY("vkEnumerateInstanceVersion", mockVersion);
    ENTRY("vkEnumerateInstanceExtensionProperties", mockExtensions);
    ENTRY("vkCreateInstance", mockCreate);
    ENTRY("vkDestroyInstance", mockDestroyInstance);
    ENTRY("vkEnumeratePhysicalDevices", mockPhysical);
    ENTRY("vkCreateDebugUtilsMessengerEXT", mockAttach);
    ENTRY("vkDestroyDebugUtilsMessengerEXT", mockDestroyDiagnostic);
#undef ENTRY
    return reinterpret_cast<PFN_vkVoidFunction>(unusedEntry);
}
int main()
{
    {
        Context context;
        createInstance(context, mockGet);
        bool failed = false;
        try { selectDevice(context, Options{}); }
        catch (const std::runtime_error &error) {
            failed = std::strstr(error.what(), "VkResult=-3") != nullptr;
        }
        assert(failed && callbacks == 1 && context.diagnostic != VK_NULL_HANDLE);
    }
    assert(instancesDestroyed == 1 && diagnosticsDestroyed == 1);
    offerDebug = false;
    { Context context; createInstance(context, mockGet); assert(context.diagnostic == VK_NULL_HANDLE); }
    offerDebug = true; failAttach = true;
    { Context context; createInstance(context, mockGet); assert(context.diagnostic == VK_NULL_HANDLE); }
    assert(instancesDestroyed == 3 && diagnosticsDestroyed == 1);
    std::puts("Vulkan diagnostic callback/optional extension/lifetime checks passed; no GPU executed.");
}
