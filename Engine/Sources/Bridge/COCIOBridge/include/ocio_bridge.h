#ifndef GUAVA_OCIO_BRIDGE_H
#define GUAVA_OCIO_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GuavaOCIOContextImpl* GuavaOCIOContext;

typedef struct GuavaOCIOTransformDesc {
    const char* _Nonnull input_color_space;
    const char* _Nonnull output_color_space;
    const char* _Nullable view_transform;
    const char* _Nullable display;
    float exposure;
    float gamma;
    bool use_gpu;
} GuavaOCIOTransformDesc;

GuavaOCIOContext guava_ocio_context_create(const char* config_path);
void              guava_ocio_context_destroy(GuavaOCIOContext ctx);
bool              guava_ocio_context_is_valid(GuavaOCIOContext ctx);

int32_t           guava_ocio_get_color_space_count(GuavaOCIOContext ctx);
const char*       guava_ocio_get_color_space_name(GuavaOCIOContext ctx, int32_t index);

bool              guava_ocio_apply_transform_rgba(GuavaOCIOContext ctx,
                                                  const GuavaOCIOTransformDesc* desc,
                                                  float* pixels,
                                                  int32_t width,
                                                  int32_t height);

#ifdef __cplusplus
}
#endif

#endif
