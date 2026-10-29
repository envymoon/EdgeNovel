// ggml calls vkGetPhysicalDeviceFeatures2 by name, a Vulkan 1.1 entry the
// API 24 libvulkan.so the engines link against does not have. Found in the
// phone's loader at run time (Android 9 and later have it); on an older
// loader only the 1.0 features are filled in, the extended ones stay zero
// (unsupported), as ggml set them.
#include <dlfcn.h>
#include <vulkan/vulkan.h>

extern "C" VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceFeatures2(
        VkPhysicalDevice device, VkPhysicalDeviceFeatures2 * features) {
    static const auto real = [] {
        void * loader = dlopen("libvulkan.so", RTLD_NOW | RTLD_LOCAL);
        return loader ? reinterpret_cast<PFN_vkGetPhysicalDeviceFeatures2>(
                            dlsym(loader, "vkGetPhysicalDeviceFeatures2"))
                      : nullptr;
    }();
    if (real) {
        real(device, features);
    } else {
        vkGetPhysicalDeviceFeatures(device, &features->features);
    }
}
