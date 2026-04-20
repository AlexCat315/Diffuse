#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GuavaSvgRasterOptions {
    uint32_t width;
    uint32_t height;
    bool apply_tint;
    uint8_t tint_rgba[4];
} GuavaSvgRasterOptions;

typedef struct GuavaSvgRasterImage {
    uint32_t width;
    uint32_t height;
    uint8_t* pixels;
    size_t length;
} GuavaSvgRasterImage;

bool guava_svg_rasterize_file(
    const char* path,
    size_t path_len,
    GuavaSvgRasterOptions options,
    GuavaSvgRasterImage* out_image
);

void guava_svg_free_image(GuavaSvgRasterImage* image);

#ifdef __cplusplus
}
#endif
