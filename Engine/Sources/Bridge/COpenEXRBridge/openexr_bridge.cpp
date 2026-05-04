#include "include/openexr_bridge.h"
#include <cstdlib>
#include <cstring>

// Stub implementation — replace with real OpenEXR C ABI when the library
// is linked. All functions return null / false / 0 so Swift callers degrade
// gracefully.

GuavaEXRContext guava_exr_writer_create(const char* path,
                                        int32_t width,
                                        int32_t height) {
    (void)path;
    (void)width;
    (void)height;
    return nullptr;
}

void guava_exr_writer_destroy(GuavaEXRContext ctx) {
    (void)ctx;
}

bool guava_exr_writer_add_layer(GuavaEXRContext ctx,
                                const GuavaEXRLayerDesc* layer,
                                GuavaEXRPixelType pixel_type) {
    (void)ctx;
    (void)layer;
    (void)pixel_type;
    return false;
}

bool guava_exr_writer_set_layer_pixels(GuavaEXRContext ctx,
                                       const char* layer_name,
                                       const float* pixels,
                                       int32_t pixel_count) {
    (void)ctx;
    (void)layer_name;
    (void)pixels;
    (void)pixel_count;
    return false;
}

bool guava_exr_writer_write(GuavaEXRContext ctx) {
    (void)ctx;
    return false;
}

GuavaEXRContext guava_exr_reader_open(const char* path) {
    (void)path;
    return nullptr;
}

void guava_exr_reader_close(GuavaEXRContext ctx) {
    (void)ctx;
}

int32_t guava_exr_reader_get_width(GuavaEXRContext ctx) {
    (void)ctx;
    return 0;
}

int32_t guava_exr_reader_get_height(GuavaEXRContext ctx) {
    (void)ctx;
    return 0;
}

int32_t guava_exr_reader_get_layer_count(GuavaEXRContext ctx) {
    (void)ctx;
    return 0;
}

bool guava_exr_reader_get_layer_desc(GuavaEXRContext ctx,
                                     int32_t index,
                                     GuavaEXRLayerDesc* out_desc) {
    (void)ctx;
    (void)index;
    (void)out_desc;
    return false;
}

bool guava_exr_reader_read_layer_pixels(GuavaEXRContext ctx,
                                        const char* layer_name,
                                        float* out_pixels,
                                        int32_t pixel_count) {
    (void)ctx;
    (void)layer_name;
    (void)out_pixels;
    (void)pixel_count;
    return false;
}
