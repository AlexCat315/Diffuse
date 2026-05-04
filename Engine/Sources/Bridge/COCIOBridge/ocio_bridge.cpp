#include "include/ocio_bridge.h"
#include <cstdlib>
#include <cstring>

// Stub implementation — replace with real OCIO 2.x C ABI when the library
// is linked. All functions return null / false / 0 so Swift callers degrade
// gracefully.

GuavaOCIOContext guava_ocio_context_create(const char* config_path) {
    (void)config_path;
    return nullptr;
}

void guava_ocio_context_destroy(GuavaOCIOContext ctx) {
    (void)ctx;
}

bool guava_ocio_context_is_valid(GuavaOCIOContext ctx) {
    (void)ctx;
    return false;
}

int32_t guava_ocio_get_color_space_count(GuavaOCIOContext ctx) {
    (void)ctx;
    return 0;
}

const char* guava_ocio_get_color_space_name(GuavaOCIOContext ctx, int32_t index) {
    (void)ctx;
    (void)index;
    return nullptr;
}

bool guava_ocio_apply_transform_rgba(GuavaOCIOContext ctx,
                                     const GuavaOCIOTransformDesc* desc,
                                     float* pixels,
                                     int32_t width,
                                     int32_t height) {
    (void)ctx;
    (void)desc;
    (void)pixels;
    (void)width;
    (void)height;
    return false;
}
