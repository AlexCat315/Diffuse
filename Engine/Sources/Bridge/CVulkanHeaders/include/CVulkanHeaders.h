// Native Windows/Linux Vulkan SDK headers and loader interop.
#pragma once

#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif
void* grhi_vulkan_get_instance_proc_addr(void);
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
typedef enum GRHIVulkanSurfaceKind {
    GRHI_VULKAN_WIN32 = 1,
    GRHI_VULKAN_XLIB = 2,
    GRHI_VULKAN_WAYLAND = 3
} GRHIVulkanSurfaceKind;
VkResult grhi_vulkan_create_native_surface(VkInstance instance, GRHIVulkanSurfaceKind kind, void* window, void* display, VkSurfaceKHR* surface);
#ifdef __cplusplus
}
#endif
