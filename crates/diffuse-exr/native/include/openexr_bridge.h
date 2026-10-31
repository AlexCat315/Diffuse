#ifndef COVE_OPENEXR_BRIDGE_H
#define COVE_OPENEXR_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CoveEXRContextImpl* CoveEXRContext;

typedef enum CoveEXRPixelType {
    COVE_EXR_UINT   = 0,
    COVE_EXR_HALF   = 1,
    COVE_EXR_FLOAT  = 2,
} CoveEXRPixelType;

typedef struct CoveEXRLayerDesc {
    const char* name;
    const char* channels;    // e.g. "R,G,B" or "R,G,B,A"
    int32_t     channel_count;
} CoveEXRLayerDesc;

// Writer
CoveEXRContext cove_exr_writer_create(const char* path,
                                        int32_t width,
                                        int32_t height);
void            cove_exr_writer_destroy(CoveEXRContext ctx);
bool            cove_exr_writer_add_layer(CoveEXRContext ctx,
                                           const CoveEXRLayerDesc* layer,
                                           CoveEXRPixelType pixel_type);
bool            cove_exr_writer_set_layer_pixels(CoveEXRContext ctx,
                                                  const char* layer_name,
                                                  const float* pixels,
                                                  int32_t pixel_count);
bool            cove_exr_writer_write(CoveEXRContext ctx);

// Reader
CoveEXRContext cove_exr_reader_open(const char* path);
void            cove_exr_reader_close(CoveEXRContext ctx);
int32_t         cove_exr_reader_get_width(CoveEXRContext ctx);
int32_t         cove_exr_reader_get_height(CoveEXRContext ctx);
int32_t         cove_exr_reader_get_layer_count(CoveEXRContext ctx);
bool            cove_exr_reader_get_layer_desc(CoveEXRContext ctx,
                                                int32_t index,
                                                CoveEXRLayerDesc* out_desc);
bool            cove_exr_reader_read_layer_pixels(CoveEXRContext ctx,
                                                   const char* layer_name,
                                                   float* out_pixels,
                                                   int32_t pixel_count);

#ifdef __cplusplus
}
#endif

#endif
