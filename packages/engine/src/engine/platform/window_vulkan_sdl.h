#pragma once

#include <stdbool.h>
#include <stdint.h>
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

const char* guava_window_vulkan_last_error(void);
const char* const* guava_window_vulkan_instance_extensions(uint32_t* out_count);
bool guava_window_create_vulkan_surface(void* window_handle, VkInstance instance, VkSurfaceKHR* out_surface);

#ifdef __cplusplus
}
#endif
