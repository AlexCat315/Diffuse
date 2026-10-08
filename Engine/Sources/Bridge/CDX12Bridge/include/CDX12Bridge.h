#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct GRHI_DX12Device GRHI_DX12Device;
typedef struct GRHI_DX12Encoder GRHI_DX12Encoder;
typedef void (*GRHI_DX12Completion)(void*);

enum GRHI_Format {
    GRHI_FORMAT_INVALID, GRHI_FORMAT_R8, GRHI_FORMAT_RGBA8, GRHI_FORMAT_BGRA8,
    GRHI_FORMAT_BGRA8_SRGB, GRHI_FORMAT_RGBA8_SRGB, GRHI_FORMAT_RGBA16F,
    GRHI_FORMAT_RGBA32F, GRHI_FORMAT_R32U, GRHI_FORMAT_R32F,
    GRHI_FORMAT_DEPTH24, GRHI_FORMAT_DEPTH24_STENCIL8, GRHI_FORMAT_DEPTH32
};
enum GRHI_Stage { GRHI_STAGE_VERTEX, GRHI_STAGE_FRAGMENT, GRHI_STAGE_COMPUTE, GRHI_STAGE_TASK, GRHI_STAGE_MESH };
enum GRHI_BindingType { GRHI_BIND_SAMPLER, GRHI_BIND_TEXTURE, GRHI_BIND_STORAGE_TEXTURE, GRHI_BIND_UNIFORM, GRHI_BIND_STORAGE, GRHI_BIND_AS };
enum GRHI_CommandType {
    GRHI_CMD_GRAPHICS_PIPELINE, GRHI_CMD_COMPUTE_PIPELINE, GRHI_CMD_MESH_PIPELINE,
    GRHI_CMD_BIND_SET, GRHI_CMD_VERTEX_BUFFER, GRHI_CMD_INDEX_BUFFER,
    GRHI_CMD_CONSTANTS, GRHI_CMD_VIEWPORT, GRHI_CMD_SCISSOR,
    GRHI_CMD_DRAW, GRHI_CMD_DRAW_INDEXED, GRHI_CMD_DRAW_INDIRECT,
    GRHI_CMD_DISPATCH, GRHI_CMD_DISPATCH_INDIRECT, GRHI_CMD_MESH_DISPATCH,
    GRHI_CMD_COPY_BUFFER, GRHI_CMD_BUFFER_TO_TEXTURE, GRHI_CMD_TEXTURE_TO_BUFFER,
    GRHI_CMD_BARRIER, GRHI_CMD_AS_BUILD, GRHI_CMD_END_RENDER, GRHI_CMD_COPY_TEXTURE
};
enum GRHI_ResourceKind { GRHI_RESOURCE_BUFFER, GRHI_RESOURCE_TEXTURE, GRHI_RESOURCE_SAMPLER, GRHI_RESOURCE_SHADER,
    GRHI_RESOURCE_GRAPHICS_PIPELINE, GRHI_RESOURCE_COMPUTE_PIPELINE, GRHI_RESOURCE_MESH_PIPELINE, GRHI_RESOURCE_AS, GRHI_RESOURCE_SET };

typedef struct { uint32_t ray_tier, mesh, task; } GRHI_DX12Capabilities;
typedef struct { uint32_t width, height, depth, layers, mips, samples, format, usage, dimension; } GRHI_TextureDesc;
typedef struct { uint32_t min_filter, mag_filter, mip_filter, address_u, address_v, address_w, compare_enabled, compare_op; } GRHI_SamplerDesc;
typedef struct { uint32_t slot, type, stages, read_only, element_stride; } GRHI_BindingDecl;
typedef struct { uint32_t slot, resource, type; uint64_t offset; } GRHI_BindingValue;
typedef struct { uint32_t slot, stage, bytes; } GRHI_ConstantDecl;
typedef struct { uint32_t format, enabled, source_rgb, destination_rgb, operation_rgb, source_alpha, destination_alpha, operation_alpha; } GRHI_ColorDesc;
typedef struct { uint32_t fill, cull, winding, primitive; } GRHI_RasterDesc;
typedef struct { uint32_t format, stencil_format, enabled, write, compare; } GRHI_DepthDesc;
typedef struct { uint32_t location, format, buffer, offset, semantic_index; const char* semantic; } GRHI_VertexAttribute;
typedef struct { uint32_t stride, per_instance; } GRHI_VertexBufferLayout;
typedef struct {
    uint32_t layout, vertex, fragment, mesh, task;
    GRHI_RasterDesc raster; GRHI_DepthDesc depth;
    const GRHI_ColorDesc* colors; uint32_t color_count;
    const GRHI_VertexAttribute* attributes; uint32_t attribute_count;
    const GRHI_VertexBufferLayout* vertex_buffers; uint32_t vertex_buffer_count;
} GRHI_GraphicsDesc;
typedef struct { uint32_t texture, load, store; float clear[4]; } GRHI_RenderColor;
typedef struct { uint32_t texture, load, store; float clear; } GRHI_RenderDepth;
typedef struct { uint32_t buffer, triangles; uint64_t offset, stride; } GRHI_Triangle;
typedef struct { uint32_t blas, mask; float transform[12]; } GRHI_Instance;
typedef struct { uint32_t id; uint64_t value; } GRHI_Timeline;
/// Typed command operands are validated by the Swift frontend and native encoder.
/// a..d store counts/offsets; data is borrowed only for this function call.
typedef struct { uint32_t kind, resource, slot, stage; uint64_t a, b, c, d; const void* data; size_t bytes; } GRHI_DX12Command;

GRHI_DX12Device* grhi_dx12_create(uint32_t validation, uint32_t low_power);
void grhi_dx12_release(GRHI_DX12Device*);
const char* grhi_dx12_error(GRHI_DX12Device*);
const char* grhi_dx12_name(GRHI_DX12Device*);
GRHI_DX12Capabilities grhi_dx12_capabilities(GRHI_DX12Device*);
int32_t grhi_dx12_buffer(GRHI_DX12Device*, uint32_t id, uint64_t size, uint32_t usage, uint32_t upload);
int32_t grhi_dx12_texture(GRHI_DX12Device*, uint32_t id, const GRHI_TextureDesc*);
int32_t grhi_dx12_sampler(GRHI_DX12Device*, uint32_t id, const GRHI_SamplerDesc*);
int32_t grhi_dx12_shader(GRHI_DX12Device*, uint32_t id, uint32_t stage, const void* bytes, size_t count);
int32_t grhi_dx12_binding_layout(GRHI_DX12Device*, uint32_t id, const GRHI_BindingDecl*, size_t count);
int32_t grhi_dx12_pipeline_layout(GRHI_DX12Device*, uint32_t id, const uint32_t* sets, size_t count, const GRHI_ConstantDecl*, size_t constants);
int32_t grhi_dx12_binding_set(GRHI_DX12Device*, uint32_t id, uint32_t layout, const GRHI_BindingValue*, size_t count);
int32_t grhi_dx12_graphics_pipeline(GRHI_DX12Device*, uint32_t id, const GRHI_GraphicsDesc*);
int32_t grhi_dx12_compute_pipeline(GRHI_DX12Device*, uint32_t id, uint32_t layout, uint32_t shader);
int32_t grhi_dx12_acceleration_structure(GRHI_DX12Device*, uint32_t id, const GRHI_Triangle*, size_t triangles, const GRHI_Instance*, size_t instances);
void grhi_dx12_destroy(GRHI_DX12Device*, uint32_t kind, uint32_t id);
int32_t grhi_dx12_upload_buffer(GRHI_DX12Device*, uint32_t id, uint64_t offset, const void*, size_t bytes);
int32_t grhi_dx12_read_buffer(GRHI_DX12Device*, uint32_t id, uint64_t offset, void*, size_t bytes);
int32_t grhi_dx12_transfer_texture(GRHI_DX12Device*, uint32_t id, uint32_t width, uint32_t height, uint32_t row_bytes, uint32_t mip, uint32_t layer, void*, size_t bytes, uint32_t upload);
GRHI_DX12Encoder* grhi_dx12_begin(GRHI_DX12Device*, uint32_t queue);
int32_t grhi_dx12_render(GRHI_DX12Encoder*, const GRHI_RenderColor*, size_t colors, const GRHI_RenderDepth*);
int32_t grhi_dx12_encode(GRHI_DX12Encoder*, const GRHI_DX12Command*);
/// Consumes the encoder on success; abort it on failure. Completion fires once.
int32_t grhi_dx12_submit(GRHI_DX12Encoder*, const GRHI_Timeline* waits, size_t wait_count, const GRHI_Timeline* signals, size_t signal_count, GRHI_DX12Completion, void*);
void grhi_dx12_abort(GRHI_DX12Encoder*);
int32_t grhi_dx12_wait_idle(GRHI_DX12Device*);
int32_t grhi_dx12_surface(GRHI_DX12Device*, void* hwnd, uint32_t width, uint32_t height, uint32_t format, uint32_t vsync);
uint32_t grhi_dx12_acquire(GRHI_DX12Device*, uint32_t* width, uint32_t* height);
int32_t grhi_dx12_present(GRHI_DX12Device*, uint32_t texture);
#ifdef __cplusplus
}
#endif
