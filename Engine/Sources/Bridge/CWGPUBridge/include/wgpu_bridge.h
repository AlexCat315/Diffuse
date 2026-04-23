#ifndef WGPU_BRIDGE_H
#define WGPU_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ─── Opaque handle typedefs ─────────────────────────────────────── */

typedef struct WGPUInstanceImpl* WGPUInstance;
typedef struct WGPUAdapterImpl* WGPUAdapter;
typedef struct WGPUDeviceImpl* WGPUDevice;
typedef struct WGPUQueueImpl* WGPUQueue;

/* ─── Bridge Enum Types ──────────────────────────────────────────── */

typedef enum {
    WGPUBridge_TextureFormat_BGRA8Unorm = 0,
    WGPUBridge_TextureFormat_RGBA8Unorm,
    WGPUBridge_TextureFormat_R8Unorm,
    WGPUBridge_TextureFormat_RGBA16Float,
    WGPUBridge_TextureFormat_Depth24Plus,
    WGPUBridge_TextureFormat_Depth32Float,
} WGPUBridgeTextureFormat;

typedef enum {
    WGPUBridge_PresentMode_Fifo = 0,
    WGPUBridge_PresentMode_FifoRelaxed,
    WGPUBridge_PresentMode_Immediate,
    WGPUBridge_PresentMode_Mailbox,
} WGPUBridgePresentMode;

typedef enum {
    WGPUBridge_LoadOp_Clear = 0,
    WGPUBridge_LoadOp_Load,
} WGPUBridgeLoadOp;

typedef enum {
    WGPUBridge_StoreOp_Store = 0,
    WGPUBridge_StoreOp_Discard,
} WGPUBridgeStoreOp;

typedef enum {
    WGPUBridge_PrimitiveTopology_TriangleList = 0,
    WGPUBridge_PrimitiveTopology_TriangleStrip,
    WGPUBridge_PrimitiveTopology_LineList,
    WGPUBridge_PrimitiveTopology_LineStrip,
    WGPUBridge_PrimitiveTopology_PointList,
} WGPUBridgePrimitiveTopology;

typedef enum {
    WGPUBridge_VertexFormat_Float32 = 0,
    WGPUBridge_VertexFormat_Float32x2,
    WGPUBridge_VertexFormat_Float32x3,
    WGPUBridge_VertexFormat_Float32x4,
    WGPUBridge_VertexFormat_Uint32,
    WGPUBridge_VertexFormat_Uint8x4,
    WGPUBridge_VertexFormat_Unorm8x4,
    WGPUBridge_VertexFormat_Snorm8x4,
    WGPUBridge_VertexFormat_Uint16x2,
    WGPUBridge_VertexFormat_Uint16x4,
    WGPUBridge_VertexFormat_Sint16x2,
    WGPUBridge_VertexFormat_Snorm16x2,
    WGPUBridge_VertexFormat_Float16x2,
    WGPUBridge_VertexFormat_Float16x4,
} WGPUBridgeVertexFormat;

typedef enum {
    WGPUBridge_CullMode_None = 0,
    WGPUBridge_CullMode_Front,
    WGPUBridge_CullMode_Back,
} WGPUBridgeCullMode;

typedef enum {
    WGPUBridge_FrontFace_CCW = 0,
    WGPUBridge_FrontFace_CW,
} WGPUBridgeFrontFace;

typedef enum {
    WGPUBridge_TextureViewDimension_2D = 0,
    WGPUBridge_TextureViewDimension_2DArray,
    WGPUBridge_TextureViewDimension_Cube,
    WGPUBridge_TextureViewDimension_CubeArray,
    WGPUBridge_TextureViewDimension_3D,
} WGPUBridgeTextureViewDimension;

typedef enum {
    WGPUBridge_StencilOp_Keep = 0,
    WGPUBridge_StencilOp_Zero,
    WGPUBridge_StencilOp_Replace,
    WGPUBridge_StencilOp_Invert,
    WGPUBridge_StencilOp_IncrClamp,
    WGPUBridge_StencilOp_DecrClamp,
    WGPUBridge_StencilOp_IncrWrap,
    WGPUBridge_StencilOp_DecrWrap,
} WGPUBridgeStencilOp;

typedef enum {
    WGPUBridge_BufferUsage_MapRead  = 0x0001,
    WGPUBridge_BufferUsage_CopySrc  = 0x0004,
    WGPUBridge_BufferUsage_CopyDst  = 0x0008,
    WGPUBridge_BufferUsage_Index    = 0x0010,
    WGPUBridge_BufferUsage_Vertex   = 0x0020,
    WGPUBridge_BufferUsage_Uniform  = 0x0040,
    WGPUBridge_BufferUsage_Storage  = 0x0080,
    WGPUBridge_BufferUsage_Indirect = 0x0100,
} WGPUBridgeBufferUsage;

typedef enum {
    WGPUBridge_TextureUsage_CopySrc          = 0x01,
    WGPUBridge_TextureUsage_CopyDst          = 0x02,
    WGPUBridge_TextureUsage_TextureBinding   = 0x04,
    WGPUBridge_TextureUsage_StorageBinding   = 0x08,
    WGPUBridge_TextureUsage_RenderAttachment = 0x10,
} WGPUBridgeTextureUsage;

typedef enum {
    WGPUBridge_BlendOp_Add = 0,
    WGPUBridge_BlendOp_Subtract,
    WGPUBridge_BlendOp_ReverseSubtract,
    WGPUBridge_BlendOp_Min,
    WGPUBridge_BlendOp_Max,
} WGPUBridgeBlendOp;

typedef enum {
    WGPUBridge_BlendFactor_Zero = 0,
    WGPUBridge_BlendFactor_One,
    WGPUBridge_BlendFactor_Src,
    WGPUBridge_BlendFactor_OneMinusSrc,
    WGPUBridge_BlendFactor_SrcAlpha,
    WGPUBridge_BlendFactor_OneMinusSrcAlpha,
    WGPUBridge_BlendFactor_Dst,
    WGPUBridge_BlendFactor_OneMinusDst,
    WGPUBridge_BlendFactor_DstAlpha,
    WGPUBridge_BlendFactor_OneMinusDstAlpha,
} WGPUBridgeBlendFactor;

typedef enum {
    WGPUBridge_IndexFormat_Uint16 = 0,
    WGPUBridge_IndexFormat_Uint32,
} WGPUBridgeIndexFormat;

typedef enum {
    WGPUBridge_FilterMode_Nearest = 0,
    WGPUBridge_FilterMode_Linear,
} WGPUBridgeFilterMode;

typedef enum {
    WGPUBridge_AddressMode_ClampToEdge = 0,
    WGPUBridge_AddressMode_Repeat,
    WGPUBridge_AddressMode_MirrorRepeat,
} WGPUBridgeAddressMode;

typedef enum {
    WGPUBridge_ShaderStage_Vertex   = 0x01,
    WGPUBridge_ShaderStage_Fragment = 0x02,
    WGPUBridge_ShaderStage_Compute  = 0x04,
} WGPUBridgeShaderStage;

typedef enum {
    WGPUBridge_BindingType_UniformBuffer = 0,
    WGPUBridge_BindingType_StorageBuffer,
    WGPUBridge_BindingType_ReadOnlyStorageBuffer,
    WGPUBridge_BindingType_Sampler,
    WGPUBridge_BindingType_SampledTexture,
} WGPUBridgeBindingType;

typedef enum {
    WGPUBridge_CompareFunction_Never = 0,
    WGPUBridge_CompareFunction_Less,
    WGPUBridge_CompareFunction_Equal,
    WGPUBridge_CompareFunction_LessEqual,
    WGPUBridge_CompareFunction_Greater,
    WGPUBridge_CompareFunction_NotEqual,
    WGPUBridge_CompareFunction_GreaterEqual,
    WGPUBridge_CompareFunction_Always,
} WGPUBridgeCompareFunction;

typedef enum {
    WGPUBridge_BackendType_Undefined = 0,
    WGPUBridge_BackendType_D3D11 = 3,
    WGPUBridge_BackendType_D3D12 = 4,
    WGPUBridge_BackendType_Metal = 5,
    WGPUBridge_BackendType_Vulkan = 6,
    WGPUBridge_BackendType_OpenGL = 7,
    WGPUBridge_BackendType_OpenGLES = 8,
} WGPUBridgeBackendType;

/* ─── Bridge Descriptor Structs ──────────────────────────────────── */

typedef struct WGPUBridgeColor {
    double r, g, b, a;
} WGPUBridgeColor;

typedef struct WGPUBridgeBlendComponent {
    WGPUBridgeBlendOp operation;
    WGPUBridgeBlendFactor src_factor;
    WGPUBridgeBlendFactor dst_factor;
} WGPUBridgeBlendComponent;

typedef struct WGPUBridgeBlendState {
    WGPUBridgeBlendComponent color;
    WGPUBridgeBlendComponent alpha;
} WGPUBridgeBlendState;

typedef struct WGPUBridgeVertexAttribute {
    WGPUBridgeVertexFormat format;
    uint64_t offset;
    uint32_t shader_location;
} WGPUBridgeVertexAttribute;

typedef struct WGPUBridgeVertexBufferLayout {
    uint64_t array_stride;
    const WGPUBridgeVertexAttribute* attributes;
    uint32_t attribute_count;
} WGPUBridgeVertexBufferLayout;

typedef struct WGPUBridgeTextureDesc {
    uint32_t width;
    uint32_t height;
    uint32_t depth_or_layers;
    uint32_t mip_level_count;
    WGPUBridgeTextureFormat format;
    int usage_flags;
} WGPUBridgeTextureDesc;

typedef struct WGPUBridgeBufferDesc {
    uint64_t size;
    int usage_flags;
    int mapped_at_creation;
} WGPUBridgeBufferDesc;

typedef struct WGPUBridgeSamplerDesc {
    WGPUBridgeAddressMode address_mode_u;
    WGPUBridgeAddressMode address_mode_v;
    WGPUBridgeFilterMode mag_filter;
    WGPUBridgeFilterMode min_filter;
    WGPUBridgeFilterMode mipmap_filter;
} WGPUBridgeSamplerDesc;

typedef struct WGPUBridgeBindGroupLayoutEntry {
    uint32_t binding;
    int visibility;
    WGPUBridgeBindingType type;
    int has_dynamic_offset;
} WGPUBridgeBindGroupLayoutEntry;

typedef struct WGPUBridgeBindGroupEntry {
    uint32_t binding;
    void* buffer;
    uint64_t offset;
    uint64_t size;
    void* sampler;
    void* texture_view;
} WGPUBridgeBindGroupEntry;

typedef struct WGPUBridgeStencilFaceState {
    WGPUBridgeCompareFunction compare;
    WGPUBridgeStencilOp fail_op;
    WGPUBridgeStencilOp depth_fail_op;
    WGPUBridgeStencilOp pass_op;
} WGPUBridgeStencilFaceState;

typedef struct WGPUBridgeDepthStencilAttachment {
    void* view;
    WGPUBridgeLoadOp depth_load_op;
    WGPUBridgeStoreOp depth_store_op;
    float clear_depth;
    WGPUBridgeLoadOp stencil_load_op;
    WGPUBridgeStoreOp stencil_store_op;
    uint32_t stencil_clear_value;
} WGPUBridgeDepthStencilAttachment;

typedef struct WGPUBridgeDepthStencilPipelineState {
    WGPUBridgeTextureFormat format;
    int depth_write_enabled;
    WGPUBridgeCompareFunction depth_compare;
    WGPUBridgeStencilFaceState stencil_front;
    WGPUBridgeStencilFaceState stencil_back;
    uint32_t stencil_read_mask;
    uint32_t stencil_write_mask;
} WGPUBridgeDepthStencilPipelineState;

typedef struct WGPUBridgeColorAttachment {
    void* view;
    WGPUBridgeLoadOp load_op;
    WGPUBridgeStoreOp store_op;
    WGPUBridgeColor clear_color;
} WGPUBridgeColorAttachment;

/* ─── Device Lifecycle ───────────────────────────────────────────── */

int wgpu_bridge_initialize(const char* library_path);
int wgpu_bridge_create_instance(void** out_instance);
int wgpu_bridge_request_adapter(void* instance, void** out_adapter);
int wgpu_bridge_request_adapter_with_backend(void* instance,
                                             WGPUBridgeBackendType backend_type,
                                             void** out_adapter);
int wgpu_bridge_request_device(void* adapter, void** out_device);
int wgpu_bridge_get_queue(void* device, void** out_queue);
int wgpu_bridge_release_queue(void* queue);
int wgpu_bridge_release_device(void* device);
int wgpu_bridge_release_adapter(void* adapter);
int wgpu_bridge_release_instance(void* instance);
void wgpu_bridge_shutdown(void);
const char* wgpu_bridge_last_error(void);

/* ─── Surface ────────────────────────────────────────────────────── */

int wgpu_bridge_create_surface_metal(void* instance,
                                     void* ca_metal_layer,
                                     void** out_surface);

int wgpu_bridge_create_surface_win32(void* instance,
                                     void* hwnd,
                                     void* hinstance,
                                     void** out_surface);

int wgpu_bridge_create_surface_wayland(void* instance,
                                       void* display,
                                       void* surface,
                                       void** out_surface);

int wgpu_bridge_create_surface_xlib(void* instance,
                                    void* display,
                                    uint64_t window,
                                    void** out_surface);

int wgpu_bridge_configure_surface(void* surface,
                                  void* device,
                                  WGPUBridgeTextureFormat format,
                                  uint32_t width,
                                  uint32_t height,
                                  WGPUBridgePresentMode present_mode);

int wgpu_bridge_surface_get_current_texture_view(void* surface,
                                                 void** out_texture,
                                                 void** out_view);

void wgpu_bridge_surface_present(void* surface);
void wgpu_bridge_release_surface(void* surface);

/* ─── Texture & View ─────────────────────────────────────────────── */

int wgpu_bridge_create_texture(void* device,
                               const WGPUBridgeTextureDesc* desc,
                               void** out_texture);

int wgpu_bridge_create_texture_view_default(void* texture,
                                            void** out_view);

typedef struct WGPUBridgeTextureViewDesc {
    WGPUBridgeTextureFormat format;
    WGPUBridgeTextureViewDimension dimension;
    uint32_t base_mip_level;
    uint32_t mip_level_count;
    uint32_t base_array_layer;
    uint32_t array_layer_count;
} WGPUBridgeTextureViewDesc;

int wgpu_bridge_create_texture_view(void* texture,
                                    const WGPUBridgeTextureViewDesc* desc,
                                    void** out_view);

void wgpu_bridge_release_texture(void* texture);
void wgpu_bridge_release_texture_view(void* view);

/* ─── Shader Module ──────────────────────────────────────────────── */

int wgpu_bridge_create_shader_module(void* device,
                                     const char* wgsl_code,
                                     const char* label,
                                     void** out_module);

void wgpu_bridge_release_shader_module(void* module);

/* ─── Render Pipeline ────────────────────────────────────────────── */

int wgpu_bridge_create_render_pipeline(
    void* device,
    void* shader_module,
    const char* vertex_entry,
    const char* fragment_entry,
    WGPUBridgeTextureFormat color_format,
    WGPUBridgePrimitiveTopology topology,
    WGPUBridgeFrontFace front_face,
    WGPUBridgeCullMode cull_mode,
    const WGPUBridgeVertexBufferLayout* vertex_buffers,
    uint32_t vertex_buffer_count,
    const WGPUBridgeBlendState* blend,
    const WGPUBridgeDepthStencilPipelineState* depth_stencil,
    void* pipeline_layout,
    void** out_pipeline);

void wgpu_bridge_release_render_pipeline(void* pipeline);

/* ─── Buffer ─────────────────────────────────────────────────────── */

int wgpu_bridge_create_buffer(void* device,
                              const WGPUBridgeBufferDesc* desc,
                              void** out_buffer);

void wgpu_bridge_write_buffer(void* queue,
                              void* buffer,
                              uint64_t offset,
                              const void* data,
                              size_t size);

void wgpu_bridge_release_buffer(void* buffer);

/* ─── Command Encoding ───────────────────────────────────────────── */

int wgpu_bridge_create_command_encoder(void* device,
                                       void** out_encoder);

int wgpu_bridge_begin_render_pass(void* encoder,
                                  void* color_view,
                                  WGPUBridgeLoadOp load_op,
                                  WGPUBridgeStoreOp store_op,
                                  WGPUBridgeColor clear_color,
                                  const WGPUBridgeDepthStencilAttachment* depth,
                                  void** out_pass);

void wgpu_bridge_render_pass_set_pipeline(void* pass, void* pipeline);

void wgpu_bridge_render_pass_set_vertex_buffer(void* pass,
                                               uint32_t slot,
                                               void* buffer,
                                               uint64_t offset,
                                               uint64_t size);

void wgpu_bridge_render_pass_set_index_buffer(void* pass,
                                              void* buffer,
                                              WGPUBridgeIndexFormat format,
                                              uint64_t offset,
                                              uint64_t size);

void wgpu_bridge_render_pass_draw(void* pass,
                                  uint32_t vertex_count,
                                  uint32_t instance_count,
                                  uint32_t first_vertex,
                                  uint32_t first_instance);

void wgpu_bridge_render_pass_draw_indexed(void* pass,
                                          uint32_t index_count,
                                          uint32_t instance_count,
                                          uint32_t first_index,
                                          int32_t base_vertex,
                                          uint32_t first_instance);

void wgpu_bridge_render_pass_draw_indirect(void* pass,
                                           void* buffer,
                                           uint64_t offset);

void wgpu_bridge_render_pass_draw_indexed_indirect(void* pass,
                                                   void* buffer,
                                                   uint64_t offset);

void wgpu_bridge_render_pass_set_bind_group(void* pass,
                                            uint32_t group_index,
                                            void* bind_group);

void wgpu_bridge_render_pass_set_bind_group_dynamic(void* pass,
                                                    uint32_t group_index,
                                                    void* bind_group,
                                                    uint32_t dynamic_offset_count,
                                                    const uint32_t* dynamic_offsets);

void wgpu_bridge_render_pass_end(void* pass);

int wgpu_bridge_encoder_finish(void* encoder,
                               void** out_command_buffer);

void wgpu_bridge_queue_submit(void* queue,
                              void** command_buffers,
                              uint32_t count);

void wgpu_bridge_release_command_buffer(void* command_buffer);
void wgpu_bridge_release_command_encoder(void* encoder);
void wgpu_bridge_release_render_pass_encoder(void* pass);

/* ─── Viewport / Scissor ─────────────────────────────────────────── */

void wgpu_bridge_render_pass_set_viewport(void* pass,
                                          float x, float y,
                                          float width, float height,
                                          float min_depth, float max_depth);

void wgpu_bridge_render_pass_set_scissor_rect(void* pass,
                                              uint32_t x, uint32_t y,
                                              uint32_t width, uint32_t height);

/* ─── Write Texture ──────────────────────────────────────────────── */

void wgpu_bridge_write_texture(void* queue,
                               void* texture,
                               uint32_t mip_level,
                               uint32_t origin_x,
                               uint32_t origin_y,
                               uint32_t origin_z,
                               const void* data,
                               size_t data_size,
                               uint32_t bytes_per_row,
                               uint32_t rows_per_image,
                               uint32_t width,
                               uint32_t height,
                               uint32_t depth_or_layers);

/* ─── Sampler ────────────────────────────────────────────────────── */

int wgpu_bridge_create_sampler(void* device,
                               const WGPUBridgeSamplerDesc* desc,
                               void** out_sampler);

void wgpu_bridge_release_sampler(void* sampler);

/* ─── Bind Group ─────────────────────────────────────────────────── */

int wgpu_bridge_create_bind_group_layout(void* device,
                                         const WGPUBridgeBindGroupLayoutEntry* entries,
                                         uint32_t entry_count,
                                         void** out_layout);

int wgpu_bridge_create_bind_group(void* device,
                                  void* layout,
                                  const WGPUBridgeBindGroupEntry* entries,
                                  uint32_t entry_count,
                                  void** out_bind_group);

int wgpu_bridge_create_pipeline_layout(void* device,
                                       void* const* bind_group_layouts,
                                       uint32_t layout_count,
                                       void** out_layout);

void wgpu_bridge_release_bind_group_layout(void* layout);
void wgpu_bridge_release_bind_group(void* bind_group);
void wgpu_bridge_release_pipeline_layout(void* layout);

/* Retrieves the auto-generated bind group layout from a render pipeline
 * created with NULL pipeline layout (auto-layout mode). The returned layout
 * must be released by the caller via wgpu_bridge_release_bind_group_layout. */
int wgpu_bridge_render_pipeline_get_bind_group_layout(void* pipeline,
                                                      uint32_t group_index,
                                                      void** out_layout);

/* ─── Compute Pipeline ───────────────────────────────────────────── */

int wgpu_bridge_create_compute_pipeline(void* device,
                                        void* shader_module,
                                        const char* entry_point,
                                        void* pipeline_layout,
                                        void** out_pipeline);

void wgpu_bridge_release_compute_pipeline(void* pipeline);

/* ─── Compute Pass ───────────────────────────────────────────────── */

int wgpu_bridge_begin_compute_pass(void* encoder, void** out_pass);

void wgpu_bridge_compute_pass_set_pipeline(void* pass, void* pipeline);

void wgpu_bridge_compute_pass_set_bind_group(void* pass,
                                             uint32_t group_index,
                                             void* bind_group);

void wgpu_bridge_compute_pass_dispatch(void* pass,
                                       uint32_t x, uint32_t y, uint32_t z);

void wgpu_bridge_compute_pass_dispatch_indirect(void* pass,
                                                void* buffer,
                                                uint64_t offset);

void wgpu_bridge_compute_pass_end(void* pass);
void wgpu_bridge_release_compute_pass_encoder(void* pass);

/* ─── MRT Render Pass ────────────────────────────────────────────── */

int wgpu_bridge_begin_render_pass_mrt(
    void* encoder,
    const WGPUBridgeColorAttachment* color_attachments,
    uint32_t color_count,
    const WGPUBridgeDepthStencilAttachment* depth,
    void** out_pass);

int wgpu_bridge_create_render_pipeline_mrt(
    void* device,
    void* shader_module,
    const char* vertex_entry,
    const char* fragment_entry,
    const WGPUBridgeTextureFormat* color_formats,
    const WGPUBridgeBlendState* blends,
    uint32_t color_format_count,
    WGPUBridgePrimitiveTopology topology,
    WGPUBridgeFrontFace front_face,
    WGPUBridgeCullMode cull_mode,
    const WGPUBridgeVertexBufferLayout* vertex_buffers,
    uint32_t vertex_buffer_count,
    const WGPUBridgeDepthStencilPipelineState* depth_stencil,
    void** out_pipeline);

/* ─── Texture Copy ───────────────────────────────────────────────── */

void wgpu_bridge_copy_texture_to_texture(
    void* encoder,
    void* src_texture, uint32_t src_mip,
    void* dst_texture, uint32_t dst_mip,
    uint32_t width, uint32_t height, uint32_t depth_or_layers);

/* ─── Render Bundles ─────────────────────────────────────────────── */

typedef struct WGPUBridgeRenderBundleEncoderDesc {
    const WGPUBridgeTextureFormat* color_formats;
    uint32_t color_format_count;
    int has_depth_stencil;
    WGPUBridgeTextureFormat depth_stencil_format;
    uint32_t sample_count;
    int depth_read_only;
    int stencil_read_only;
} WGPUBridgeRenderBundleEncoderDesc;

int wgpu_bridge_create_render_bundle_encoder(void* device,
                                             const WGPUBridgeRenderBundleEncoderDesc* desc,
                                             void** out_encoder);

int wgpu_bridge_render_bundle_encoder_finish(void* encoder, void** out_bundle);

void wgpu_bridge_release_render_bundle_encoder(void* encoder);
void wgpu_bridge_release_render_bundle(void* bundle);

void wgpu_bridge_render_bundle_set_pipeline(void* enc, void* pipeline);
void wgpu_bridge_render_bundle_set_vertex_buffer(void* enc, uint32_t slot,
                                                 void* buffer, uint64_t offset, uint64_t size);
void wgpu_bridge_render_bundle_set_index_buffer(void* enc, void* buffer,
                                                WGPUBridgeIndexFormat format,
                                                uint64_t offset, uint64_t size);
void wgpu_bridge_render_bundle_set_bind_group(void* enc, uint32_t group_index, void* bind_group);
void wgpu_bridge_render_bundle_set_bind_group_dynamic(void* enc,
                                                      uint32_t group_index,
                                                      void* bind_group,
                                                      uint32_t dynamic_offset_count,
                                                      const uint32_t* dynamic_offsets);
void wgpu_bridge_render_bundle_draw(void* enc, uint32_t vertex_count, uint32_t instance_count,
                                    uint32_t first_vertex, uint32_t first_instance);
void wgpu_bridge_render_bundle_draw_indexed(void* enc, uint32_t index_count, uint32_t instance_count,
                                            uint32_t first_index, int32_t base_vertex, uint32_t first_instance);
void wgpu_bridge_render_bundle_draw_indirect(void* enc, void* buffer, uint64_t offset);
void wgpu_bridge_render_bundle_draw_indexed_indirect(void* enc, void* buffer, uint64_t offset);

void wgpu_bridge_render_pass_execute_bundles(void* pass,
                                             void* const* bundles,
                                             uint32_t count);

/* ─── Texture Readback ───────────────────────────────────────────── */

void wgpu_bridge_copy_texture_to_buffer(
    void* encoder,
    void* texture, uint32_t mip_level,
    void* buffer, uint64_t buffer_offset,
    uint32_t bytes_per_row, uint32_t rows_per_image,
    uint32_t width, uint32_t height, uint32_t depth_or_layers);

int wgpu_bridge_buffer_map_sync(void* device, void* buffer,
                                uint64_t offset, uint64_t size);

const void* wgpu_bridge_buffer_get_mapped_range(void* buffer,
                                                uint64_t offset,
                                                uint64_t size);

void wgpu_bridge_buffer_unmap(void* buffer);

#ifdef __cplusplus
}
#endif

#endif
