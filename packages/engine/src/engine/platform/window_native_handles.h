#pragma once

#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    void* metal_view;
    void* layer;
} GuavaMetalLayerBinding;

bool guava_window_create_metal_layer_binding(void* window_handle, GuavaMetalLayerBinding* out_binding);
void guava_window_destroy_metal_layer_binding(GuavaMetalLayerBinding binding);
void* guava_window_get_native_win32_hwnd(void* window_handle);
void* guava_window_get_native_cocoa_window(void* window_handle);

#ifdef __cplusplus
}
#endif
