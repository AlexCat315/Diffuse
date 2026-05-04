#ifndef GUAVA_OPENEXR_BRIDGE_H
#define GUAVA_OPENEXR_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GuavaEXRContextImpl* GuavaEXRContext;

typedef enum GuavaEXRPixelType {
    GUAVA_EXR_UINT   = 0,
    GUAVA_EXR_HALF   = 1,
    GUAVA_EXR_FLOAT  = 2,
} GuavaEXRPixelType;

typedef struct GuavaEXRLayerDesc {
    const char* name;
    const char* channels;    // e.g. "R,G,B" or "R,G,B,A"
    int32_t     channel_count;
} GuavaEXRLayerDesc;

// Writer
GuavaEXRContext guava_exr_writer_create(const char* path,
                                        int32_t width,
                                        int32_t height);
void            guava_exr_writer_destroy(GuavaEXRContext ctx);
bool            guava_exr_writer_add_layer(GuavaEXRContext ctx,
                                           const GuavaEXRLayerDesc* layer,
                                           GuavaEXRPixelType pixel_type);
bool            guava_exr_writer_set_layer_pixels(GuavaEXRContext ctx,
                                                  const char* layer_name,
                                                  const float* pixels,
                                                  int32_t pixel_count);
bool            guava_exr_writer_write(GuavaEXRContext ctx);

// Reader
GuavaEXRContext guava_exr_reader_open(const char* path);
void            guava_exr_reader_close(GuavaEXRContext ctx);
int32_t         guava_exr_reader_get_width(GuavaEXRContext ctx);
int32_t         guava_exr_reader_get_height(GuavaEXRContext ctx);
int32_t         guava_exr_reader_get_layer_count(GuavaEXRContext ctx);
bool            guava_exr_reader_get_layer_desc(GuavaEXRContext ctx,
                                                int32_t index,
                                                GuavaEXRLayerDesc* out_desc);
bool            guava_exr_reader_read_layer_pixels(GuavaEXRContext ctx,
                                                   const char* layer_name,
                                                   float* out_pixels,
                                                   int32_t pixel_count);

#ifdef __cplusplus
}
#endif

#endif
