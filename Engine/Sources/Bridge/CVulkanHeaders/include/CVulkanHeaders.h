// CVulkanHeaders — umbrella header that re-exports the vendored Vulkan headers.
//
// This target contains no logic: it gives Swift a single module
// (`CVulkanHeaders`) through which the Vulkan C API is visible. The Vulkan
// headers and the dynamic loader (libvulkan) are vendored in the
// `VulkanLoader.xcframework` that this target links at build time. The
// driver (an ICD such as MoltenVK) is discovered by the loader at runtime, so
// the backend throws cleanly when no physical device is present.
#pragma once

#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif
void* grhi_vulkan_get_instance_proc_addr(void);
void* grhi_vulkan_loader_symbol(const char* name);
#ifdef __cplusplus
}
#endif
#ifdef __cplusplus
extern "C" {
#endif
// The packed 64-byte GPU instance layout contains C bitfields that Swift cannot write.
void grhi_vulkan_pack_instance(void* destination, const float* transform, uint32_t index, uint32_t mask, uint64_t address);
#ifdef __cplusplus
}
#endif
#ifdef __cplusplus
extern "C" {
#endif
VkResult grhi_vulkan_create_native_surface(VkInstance instance, void* window, void* display, VkSurfaceKHR* surface);
#ifdef __cplusplus
}
#endif
