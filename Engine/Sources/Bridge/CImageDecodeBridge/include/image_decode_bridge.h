#ifndef GUAVA_IMAGE_DECODE_BRIDGE_H
#define GUAVA_IMAGE_DECODE_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GuavaImageDecodeResult {
    uint8_t* pixels;
    int32_t width;
    int32_t height;
    char* error_message;
} GuavaImageDecodeResult;

bool guava_image_decode_memory(const uint8_t* data,
                               size_t data_size,
                               const char* extension,
                               int32_t target_width,
                               int32_t target_height,
                               GuavaImageDecodeResult* out_result);

void guava_image_decode_free(GuavaImageDecodeResult* result);

#ifdef __cplusplus
}
#endif

#endif
