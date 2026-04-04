#include "window_vulkan_sdl.h"

#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>

const char* guava_window_vulkan_last_error(void) {
    return SDL_GetError();
}

const char* const* guava_window_vulkan_instance_extensions(uint32_t* out_count) {
    return SDL_Vulkan_GetInstanceExtensions(out_count);
}

bool guava_window_create_vulkan_surface(void* window_handle, VkInstance instance, VkSurfaceKHR* out_surface) {
    if (window_handle == NULL || out_surface == NULL) {
        return false;
    }

    return SDL_Vulkan_CreateSurface((SDL_Window*)window_handle, instance, NULL, out_surface);
}
