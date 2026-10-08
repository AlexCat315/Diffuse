#include "CVulkanHeaders.h"
#ifdef _WIN32
#include <windows.h>
#endif

void* grhi_vulkan_get_instance_proc_addr(void) { return (void*)vkGetInstanceProcAddr; }

#include <string.h>
void grhi_vulkan_pack_instance(void* destination, const float* transform, uint32_t index, uint32_t mask, uint64_t address) {
    VkAccelerationStructureInstanceKHR instance = {0};
    memcpy(instance.transform.matrix, transform, sizeof(instance.transform.matrix));
    instance.instanceCustomIndex = index;
    instance.mask = mask;
    instance.flags = VK_GEOMETRY_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT_KHR;
    instance.accelerationStructureReference = address;
    memcpy(destination, &instance, sizeof(instance));
}

VkResult grhi_vulkan_create_native_surface(VkInstance instance, GRHIVulkanSurfaceKind kind, void* window, void* display, VkSurfaceKHR* surface) {
    if (!instance || !window || !surface) return VK_ERROR_INITIALIZATION_FAILED;
#ifdef _WIN32
    if (kind != GRHI_VULKAN_WIN32) return VK_ERROR_EXTENSION_NOT_PRESENT;
    // The extension's stable C layout is kept here to avoid exposing Win32
    // header macros and handles through the Swift module on other hosts.
    typedef struct { VkStructureType sType; const void* pNext; VkFlags flags; HINSTANCE hinstance; HWND hwnd; } SurfaceInfo;
    typedef VkResult (VKAPI_PTR *CreateSurface)(VkInstance, const SurfaceInfo*, const VkAllocationCallbacks*, VkSurfaceKHR*);
    CreateSurface create = (CreateSurface)vkGetInstanceProcAddr(instance, "vkCreateWin32SurfaceKHR");
    if (!create) return VK_ERROR_EXTENSION_NOT_PRESENT;
    SurfaceInfo info = {VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR, NULL, 0, GetModuleHandleW(NULL), (HWND)window};
    return create(instance, &info, NULL, surface);
#elif defined(__linux__)
    if (!display) return VK_ERROR_INITIALIZATION_FAILED;
    if (kind == GRHI_VULKAN_WAYLAND) {
        typedef struct { VkStructureType sType; const void* pNext; VkFlags flags; void* display; void* surface; } WaylandInfo;
        typedef VkResult (VKAPI_PTR *CreateWayland)(VkInstance, const WaylandInfo*, const VkAllocationCallbacks*, VkSurfaceKHR*);
        CreateWayland create = (CreateWayland)vkGetInstanceProcAddr(instance, "vkCreateWaylandSurfaceKHR");
        if (!create) return VK_ERROR_EXTENSION_NOT_PRESENT;
        WaylandInfo info = {VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR, NULL, 0, display, window};
        return create(instance, &info, NULL, surface);
    }
    if (kind != GRHI_VULKAN_XLIB) return VK_ERROR_EXTENSION_NOT_PRESENT;
    typedef struct { VkStructureType sType; const void* pNext; VkFlags flags; void* dpy; unsigned long window; } SurfaceInfo;
    typedef VkResult (VKAPI_PTR *CreateSurface)(VkInstance, const SurfaceInfo*, const VkAllocationCallbacks*, VkSurfaceKHR*);
    CreateSurface create = (CreateSurface)vkGetInstanceProcAddr(instance, "vkCreateXlibSurfaceKHR");
    if (!create || !display) return VK_ERROR_EXTENSION_NOT_PRESENT;
    SurfaceInfo info = {VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR, NULL, 0, display, (unsigned long)(uintptr_t)window};
    return create(instance, &info, NULL, surface);
#else
    return VK_ERROR_EXTENSION_NOT_PRESENT;
#endif
}
