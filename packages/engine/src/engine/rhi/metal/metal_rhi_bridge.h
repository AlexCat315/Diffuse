#pragma once
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Metal RHI Bridge — links the Zig RHI v2 layer to real Metal API
// ---------------------------------------------------------------------------

// ── Binding entry passed across FFI for set registration ──────────────────
typedef struct {
    uint32_t slot;           // local slot within the binding set
    uint32_t resource_type;  // 0=sampler,1=texture,2=storage_texture,3=uniform_buffer,4=storage_buffer
    uint32_t stage;          // 0=vertex,1=fragment,2=compute
    uint32_t resource_id;    // RHI resource ID (maps to Metal object)
} GuavaMetalBindingEntry;

// ── FFI descriptor structs ────────────────────────────────────────────────
typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t depth;
    uint32_t layers;
    uint32_t mip_levels;
    uint32_t sample_count;
    uint32_t format;        // TextureFormat enum ordinal
    uint32_t usage_bits;    // TextureUsageFlags packed
    uint32_t dimension;     // 0=d2, 1=d3, 2=cube, 3=array
} GuavaMetalTextureDesc;

typedef struct {
    uint32_t min_filter;    // 0=nearest, 1=linear
    uint32_t mag_filter;
    uint32_t mipmap_mode;   // 0=nearest, 1=linear
    uint32_t address_u;     // 0=repeat, 1=mirrored_repeat, 2=clamp_to_edge
    uint32_t address_v;
    uint32_t address_w;
    uint32_t enable_compare; // 0=disabled, 1=enabled (for shadow samplers)
    uint32_t compare_op;     // CompareOp ordinal (0=never..7=always)
} GuavaMetalSamplerDesc;

// ── Vertex layout descriptors for pipeline creation ───────────────────────
typedef struct {
    uint32_t location;       // shader attribute index
    uint32_t format;         // VertexElementFormat ordinal: 0=float2, 1=float3, 2=float4
    uint32_t offset;         // byte offset within the vertex buffer
    uint32_t buffer_index;   // vertex buffer slot (maps to Metal index 30+)
} GuavaMetalVertexAttribute;

typedef struct {
    uint32_t stride;         // bytes per vertex
    uint32_t step_rate;      // 0=per_vertex, 1=per_instance
} GuavaMetalVertexBufferLayout;

typedef struct {
    uint32_t vertex_shader_id;
    uint32_t fragment_shader_id;
    uint32_t color_format;          // TextureFormat ordinal
    uint32_t depth_format;          // TextureFormat ordinal (0=unknown=none)
    uint32_t primitive;             // 0=triangle_list,...4=point_list
    uint32_t depth_compare_op;      // CompareOp ordinal (0=never..7=always)
    uint32_t depth_write_enabled;   // bool
    uint32_t vertex_attr_count;     // number of vertex attributes (0=no vertex layout)
    uint32_t vertex_buffer_layout_count; // number of vertex buffer layouts
    // ── Blend state ───────────────────────────────────────────────────
    uint32_t blend_enabled;         // 0=disabled, 1=enabled
    uint32_t src_color_blend;       // BlendFactor ordinal
    uint32_t dst_color_blend;       // BlendFactor ordinal
    uint32_t color_blend_op;        // BlendOp ordinal (0=add,...4=max)
    uint32_t src_alpha_blend;       // BlendFactor ordinal
    uint32_t dst_alpha_blend;       // BlendFactor ordinal
    uint32_t alpha_blend_op;        // BlendOp ordinal
} GuavaMetalGraphicsPipelineDesc;

typedef struct {
    uint32_t id;
    uint64_t value;
} GuavaMetalTimelineSemaphore;

typedef struct {
    const GuavaMetalTimelineSemaphore* wait_semaphores;
    uint32_t wait_count;
    const GuavaMetalTimelineSemaphore* signal_semaphores;
    uint32_t signal_count;
} GuavaMetalSubmitDesc;

// ── Lifecycle ─────────────────────────────────────────────────────────────
void* guava_metal_rhi_init(void);
void  guava_metal_rhi_destroy(void* ctx);

// ── Swapchain layer configuration ─────────────────────────────────────────
// Pass the CAMetalLayer* (as void*) obtained from the window system.
void guava_metal_rhi_set_layer(void* ctx, void* ca_metal_layer);
void guava_metal_rhi_set_vsync_enabled(void* ctx, bool enabled);

// ── Resource creation (returns ID > 0 on success, 0 on failure) ──────────
uint32_t guava_metal_rhi_create_buffer(void* ctx, uint64_t size,
                                       uint32_t usage_bits,
                                       const char* label);
uint32_t guava_metal_rhi_create_texture(void* ctx,
                                        const GuavaMetalTextureDesc* desc,
                                        const char* label);
uint32_t guava_metal_rhi_create_sampler(void* ctx,
                                        const GuavaMetalSamplerDesc* desc);
uint32_t guava_metal_rhi_create_shader_module(void* ctx,
                                              uint32_t stage,
                                              uint32_t format,
                                              const uint8_t* code,
                                              uint32_t code_len,
                                              const char* entry_point);
uint32_t guava_metal_rhi_create_graphics_pipeline(
    void* ctx,
    const GuavaMetalGraphicsPipelineDesc* desc,
    const GuavaMetalVertexAttribute* attrs,         // NULL if no vertex layout
    const GuavaMetalVertexBufferLayout* buf_layouts  // NULL if no vertex layout
);
uint32_t guava_metal_rhi_create_compute_pipeline(void* ctx,
                                                  uint32_t shader_id);

// ── Resource destruction ──────────────────────────────────────────────────
void guava_metal_rhi_destroy_buffer(void* ctx, uint32_t buffer_id);
void guava_metal_rhi_destroy_texture(void* ctx, uint32_t texture_id);
void guava_metal_rhi_destroy_sampler(void* ctx, uint32_t sampler_id);
void guava_metal_rhi_destroy_graphics_pipeline(void* ctx, uint32_t id);
void guava_metal_rhi_destroy_compute_pipeline(void* ctx, uint32_t id);

// ── Data upload ───────────────────────────────────────────────────────────
bool guava_metal_rhi_upload_buffer_data(void* ctx, uint32_t buffer_id,
                                        uint64_t offset,
                                        const uint8_t* data, uint64_t size);
bool guava_metal_rhi_upload_texture_data(void* ctx, uint32_t texture_id,
                                         const uint8_t* data, uint64_t size,
                                         uint32_t width, uint32_t height,
                                         uint32_t bytes_per_row);
bool guava_metal_rhi_read_texture_data(void* ctx, uint32_t texture_id,
                                       uint32_t width, uint32_t height,
                                       uint32_t bytes_per_row,
                                       uint8_t* out_data, uint64_t out_size);

// Returns id<MTLDevice> as opaque pointer.
void* guava_metal_rhi_get_mtl_device(void* ctx);
// Returns id<MTLTexture> as opaque pointer for a texture ID.
void* guava_metal_rhi_get_texture_handle(void* ctx, uint32_t texture_id);

// ── Binding set registration ──────────────────────────────────────────────
void guava_metal_rhi_register_binding_set(void* ctx, uint32_t set_id,
                                          const GuavaMetalBindingEntry* entries,
                                          uint32_t count);

// ── Command buffer submission ─────────────────────────────────────────────
// Decodes the RHI v2 serialized command buffer and translates to Metal calls.
// queue_class: 0=graphics, 1=compute, 2=transfer
bool guava_metal_rhi_submit(void* ctx, uint32_t queue_class,
                            const uint8_t* cmd_bytes, uint32_t cmd_len,
                            const GuavaMetalSubmitDesc* desc);

// ── Swapchain ─────────────────────────────────────────────────────────────
// Acquires the next drawable from the configured CAMetalLayer.
// Returns the swapchain texture ID and dimensions.
bool guava_metal_rhi_acquire_swapchain(void* ctx,
                                       uint32_t* out_id,
                                       uint32_t* out_width,
                                       uint32_t* out_height);
bool guava_metal_rhi_present(void* ctx, uint32_t swapchain_id);

// ── IOSurface-backed textures (macOS cross-process sharing) ───────────────
// Creates a Metal texture backed by an IOSurface.  The returned surface_id
// is globally unique and can be sent to another process (e.g. Electron)
// which can then call IOSurfaceLookup() to obtain a reference.
uint32_t guava_metal_rhi_create_iosurface_texture(void* ctx,
                                                   uint32_t width,
                                                   uint32_t height,
                                                   uint32_t format,
                                                   uint32_t usage_bits,
                                                   uint32_t* out_surface_id,
                                                   const char* label);

// ── Debug ─────────────────────────────────────────────────────────────────
const char* guava_metal_rhi_get_device_name(void* ctx);

// ── GPU synchronization ───────────────────────────────────────────────────
void guava_metal_rhi_wait_for_gpu(void* ctx);

#ifdef __cplusplus
}
#endif
