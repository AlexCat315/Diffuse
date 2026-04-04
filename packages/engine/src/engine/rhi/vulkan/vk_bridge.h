#pragma once
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// Vulkan RHI Bridge — links the Zig RHI v2 layer to real Vulkan API
// ---------------------------------------------------------------------------

// ── Binding entry passed across FFI for set registration ──────────────────
typedef struct {
    uint32_t slot;           // local slot within the binding set
    uint32_t resource_type;  // 0=sampler,1=texture,2=storage_texture,3=uniform_buffer,4=storage_buffer
    uint32_t stage;          // 0=vertex,1=fragment,2=compute
    uint32_t resource_id;    // RHI resource ID (maps to Vulkan object)
} GuavaVkBindingEntry;

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
} GuavaVkTextureDesc;

typedef struct {
    uint32_t min_filter;    // 0=nearest, 1=linear
    uint32_t mag_filter;
    uint32_t mipmap_mode;   // 0=nearest, 1=linear
    uint32_t address_u;     // 0=repeat, 1=mirrored_repeat, 2=clamp_to_edge
    uint32_t address_v;
    uint32_t address_w;
    uint32_t enable_compare; // 0=disabled, 1=enabled (for shadow samplers)
    uint32_t compare_op;     // CompareOp ordinal (0=never..7=always)
} GuavaVkSamplerDesc;

// ── Vertex layout descriptors for pipeline creation ───────────────────────
typedef struct {
    uint32_t location;       // shader attribute index
    uint32_t format;         // VertexElementFormat ordinal: 0=float2, 1=float3, 2=float4
    uint32_t offset;         // byte offset within the vertex buffer
    uint32_t buffer_index;   // vertex buffer slot
} GuavaVkVertexAttribute;

typedef struct {
    uint32_t stride;         // bytes per vertex
    uint32_t step_rate;      // 0=per_vertex, 1=per_instance
} GuavaVkVertexBufferLayout;

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
} GuavaVkGraphicsPipelineDesc;

typedef struct {
    uint32_t id;
    uint64_t value;
} GuavaVkTimelineSemaphore;

typedef struct {
    const GuavaVkTimelineSemaphore* wait_semaphores;
    uint32_t wait_count;
    const GuavaVkTimelineSemaphore* signal_semaphores;
    uint32_t signal_count;
} GuavaVkSubmitDesc;

// ── Lifecycle ─────────────────────────────────────────────────────────────
void* guava_vk_rhi_init(bool enable_validation);
void  guava_vk_rhi_destroy(void* ctx);

// ── Surface / swapchain ───────────────────────────────────────────────────
bool guava_vk_rhi_create_surface(void* ctx, void* native_window);
bool guava_vk_rhi_create_swapchain(void* ctx, uint32_t width, uint32_t height, bool vsync_enabled);

// ── Resource creation (returns ID > 0 on success, 0 on failure) ──────────
uint32_t guava_vk_rhi_create_buffer(void* ctx, uint64_t size,
                                     uint32_t usage_bits,
                                     const char* label);
uint32_t guava_vk_rhi_create_texture(void* ctx,
                                      const GuavaVkTextureDesc* desc,
                                      const char* label);
uint32_t guava_vk_rhi_create_sampler(void* ctx,
                                      const GuavaVkSamplerDesc* desc);
uint32_t guava_vk_rhi_create_shader_module(void* ctx,
                                            uint32_t stage,
                                            uint32_t format,
                                            const uint8_t* code,
                                            uint32_t code_len,
                                            const char* entry_point);
uint32_t guava_vk_rhi_create_graphics_pipeline(
    void* ctx,
    const GuavaVkGraphicsPipelineDesc* desc,
    const GuavaVkVertexAttribute* attrs,
    const GuavaVkVertexBufferLayout* buf_layouts
);
uint32_t guava_vk_rhi_create_compute_pipeline(void* ctx, uint32_t shader_id);

// ── Resource destruction ──────────────────────────────────────────────────
void guava_vk_rhi_destroy_buffer(void* ctx, uint32_t buffer_id);
void guava_vk_rhi_destroy_texture(void* ctx, uint32_t texture_id);
void guava_vk_rhi_destroy_sampler(void* ctx, uint32_t sampler_id);
void guava_vk_rhi_destroy_graphics_pipeline(void* ctx, uint32_t id);
void guava_vk_rhi_destroy_compute_pipeline(void* ctx, uint32_t id);

// ── Data transfer ─────────────────────────────────────────────────────────
bool guava_vk_rhi_upload_buffer_data(void* ctx, uint32_t buffer_id,
                                      uint64_t offset,
                                      const uint8_t* data, uint64_t size);
bool guava_vk_rhi_upload_texture_data(void* ctx, uint32_t texture_id,
                                       const uint8_t* data, uint64_t size,
                                       uint32_t width, uint32_t height,
                                       uint32_t bytes_per_row);
bool guava_vk_rhi_read_texture_data(void* ctx, uint32_t texture_id,
                                     uint32_t width, uint32_t height,
                                     uint32_t bytes_per_row,
                                     uint8_t* out_data, uint64_t out_size);

// ── Binding set registration ──────────────────────────────────────────────
void guava_vk_rhi_register_binding_set(void* ctx, uint32_t set_id,
                                        const GuavaVkBindingEntry* entries,
                                        uint32_t count);

// ── Command buffer submission ─────────────────────────────────────────────
// Decodes the RHI v2 serialized command buffer and translates to Vulkan calls.
// queue_class: 0=graphics, 1=compute, 2=transfer
bool guava_vk_rhi_submit(void* ctx, uint32_t queue_class,
                          const uint8_t* cmd_bytes, uint32_t cmd_len,
                          const GuavaVkSubmitDesc* desc);

// ── Swapchain ─────────────────────────────────────────────────────────────
bool guava_vk_rhi_acquire_swapchain(void* ctx,
                                     uint32_t* out_id,
                                     uint32_t* out_width,
                                     uint32_t* out_height);
bool guava_vk_rhi_present(void* ctx, uint32_t swapchain_id);

// ── Debug ─────────────────────────────────────────────────────────────────
const char* guava_vk_rhi_get_device_name(void* ctx);

// ── Shared texture (cross-process viewport) ───────────────────────────────
// Creates a normal VkImage for GPU rendering, plus a staging buffer and a
// POSIX shared-memory region for CPU readback.  Returns texture_id on success
// (0 on failure) and writes the shm name used to *out_shm_name.
// After each frame the caller must invoke the blit function to update shm.
typedef struct {
    uint32_t texture_id;
    char     shm_name[64];   // e.g. "/guava-vp-12345-7"
} GuavaVkSharedTextureResult;

GuavaVkSharedTextureResult guava_vk_rhi_create_shared_texture(
    void* ctx, uint32_t width, uint32_t height,
    uint32_t format, uint32_t usage_bits, const char* label);

// Blit the shared texture from GPU memory to the shared-memory region so the
// editor process can read the pixels.  This is a synchronous GPU operation.
bool guava_vk_rhi_blit_shared_texture(void* ctx, uint32_t texture_id);

// Destroy a shared texture and its associated staging buffer / shm.
void guava_vk_rhi_destroy_shared_texture(void* ctx, uint32_t texture_id);

// ── Vulkan handle getters (for ImGui Vulkan backend) ──────────────────────
void*    guava_vk_rhi_get_instance(void* ctx);
void*    guava_vk_rhi_get_physical_device(void* ctx);
void*    guava_vk_rhi_get_vk_device(void* ctx);
uint32_t guava_vk_rhi_get_graphics_queue_family(void* ctx);
void*    guava_vk_rhi_get_graphics_queue(void* ctx);
uint32_t guava_vk_rhi_get_swapchain_image_count(void* ctx);
void*    guava_vk_rhi_get_swapchain_render_pass(void* ctx);

// ── ImGui Vulkan integration ──────────────────────────────────────────────
bool guava_imgui_vulkan_backend_init(void* vk_bridge_ctx);
void guava_imgui_vulkan_backend_shutdown(void);
bool guava_imgui_vulkan_backend_render(void* vk_command_buffer);

#ifdef __cplusplus
}
#endif
