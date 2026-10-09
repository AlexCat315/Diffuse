// Non-Windows entry points fail closed; the Swift adapter is still type checked on macOS.
#include "include/CDX12Bridge.h"
#ifndef _WIN32
GRHI_DX12Device* grhi_dx12_create(uint32_t validation, uint32_t low_power) { return 0; }
void grhi_dx12_release(GRHI_DX12Device*) {  }
const char* grhi_dx12_error(GRHI_DX12Device*) { return "DirectX 12 requires Windows"; }
const char* grhi_dx12_name(GRHI_DX12Device*) { return "DirectX 12 requires Windows"; }
GRHI_DX12Capabilities grhi_dx12_capabilities(GRHI_DX12Device*) { return {}; }
int32_t grhi_dx12_buffer(GRHI_DX12Device*, uint32_t id, uint64_t size, uint32_t usage, uint32_t upload) { return 0; }
int32_t grhi_dx12_texture(GRHI_DX12Device*, uint32_t id, const GRHI_TextureDesc*) { return 0; }
int32_t grhi_dx12_sampler(GRHI_DX12Device*, uint32_t id, const GRHI_SamplerDesc*) { return 0; }
int32_t grhi_dx12_shader(GRHI_DX12Device*, uint32_t id, uint32_t stage, const void* bytes, size_t count) { return 0; }
int32_t grhi_dx12_binding_layout(GRHI_DX12Device*, uint32_t id, const GRHI_BindingDecl*, size_t count) { return 0; }
int32_t grhi_dx12_pipeline_layout(GRHI_DX12Device*, uint32_t id, const uint32_t* sets, size_t count, const GRHI_ConstantDecl*, size_t constants) { return 0; }
int32_t grhi_dx12_binding_set(GRHI_DX12Device*, uint32_t id, uint32_t layout, const GRHI_BindingValue*, size_t count) { return 0; }
int32_t grhi_dx12_graphics_pipeline(GRHI_DX12Device*, uint32_t id, const GRHI_GraphicsDesc*) { return 0; }
int32_t grhi_dx12_compute_pipeline(GRHI_DX12Device*, uint32_t id, uint32_t layout, uint32_t shader) { return 0; }
int32_t grhi_dx12_acceleration_structure(GRHI_DX12Device*, uint32_t id, const GRHI_Triangle*, size_t triangles, const GRHI_Instance*, size_t instances) { return 0; }
void grhi_dx12_destroy(GRHI_DX12Device*, uint32_t kind, uint32_t id) {  }
int32_t grhi_dx12_upload_buffer(GRHI_DX12Device*, uint32_t id, uint64_t offset, const void*, size_t bytes) { return 0; }
int32_t grhi_dx12_read_buffer(GRHI_DX12Device*, uint32_t id, uint64_t offset, void*, size_t bytes) { return 0; }
int32_t grhi_dx12_transfer_texture(GRHI_DX12Device*, uint32_t id, uint32_t originX, uint32_t originY, uint32_t width, uint32_t height, uint32_t row_bytes, uint32_t mip, uint32_t layer, void*, size_t bytes, uint32_t upload) { return 0; }
GRHI_DX12Encoder* grhi_dx12_begin(GRHI_DX12Device*, uint32_t queue) { return 0; }
int32_t grhi_dx12_render(GRHI_DX12Encoder*, const GRHI_RenderColor*, size_t colors, const GRHI_RenderDepth*) { return 0; }
int32_t grhi_dx12_encode(GRHI_DX12Encoder*, const GRHI_DX12Command*) { return 0; }
int32_t grhi_dx12_submit(GRHI_DX12Encoder*, const GRHI_Timeline* waits, size_t wait_count, const GRHI_Timeline* signals, size_t signal_count, GRHI_DX12Completion, void*) { return 0; }
void grhi_dx12_abort(GRHI_DX12Encoder*) {  }
int32_t grhi_dx12_wait_idle(GRHI_DX12Device*) { return 0; }
int32_t grhi_dx12_surface(GRHI_DX12Device*, uint32_t swapchain, void* hwnd, uint32_t width, uint32_t height, uint32_t format, uint32_t vsync) { return 0; }
void grhi_dx12_destroy_surface(GRHI_DX12Device*, uint32_t swapchain) { }
uint32_t grhi_dx12_acquire(GRHI_DX12Device*, uint32_t swapchain, uint32_t* width, uint32_t* height, uint64_t* generation) { return 0; }
int32_t grhi_dx12_present(GRHI_DX12Device*, uint32_t swapchain, uint32_t texture, GRHI_DX12Completion, void*) { return 0; }
#endif
