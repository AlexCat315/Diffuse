/* ════════════════════════════════════════════════════════════════════
   wgpu_bridge.c — v29 native bridge.
   Direct calls into wgpu-native v29 (no dlopen, no shadow structs).
   ABI is fully checked by the C compiler against vendor/wgpu/include.
   ════════════════════════════════════════════════════════════════════ */

#include "wgpu_bridge.h"

#include <webgpu/webgpu.h>
#include <webgpu/wgpu.h>

#ifndef _WIN32
#include <pthread.h>
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ════════════════════════════════════════════════════════════════════
   Error reporting
   ════════════════════════════════════════════════════════════════════ */

static char g_last_error[512] = {0};

static void set_error(const char* msg) {
    if (msg == NULL) {
        g_last_error[0] = '\0';
        return;
    }
    strncpy(g_last_error, msg, sizeof(g_last_error) - 1);
    g_last_error[sizeof(g_last_error) - 1] = '\0';
}

static void set_error_sv(WGPUStringView sv) {
    if (sv.data == NULL || sv.length == 0) { g_last_error[0] = '\0'; return; }
    size_t n = sv.length;
    if (n >= sizeof(g_last_error)) n = sizeof(g_last_error) - 1;
    memcpy(g_last_error, sv.data, n);
    g_last_error[n] = '\0';
}

const char* wgpu_bridge_last_error(void) { return g_last_error; }

/* ════════════════════════════════════════════════════════════════════
   StringView helpers
   ════════════════════════════════════════════════════════════════════ */

static WGPUStringView sv_from_cstr(const char* s) {
    WGPUStringView v;
    if (s == NULL) {
        v.data = NULL;
        v.length = WGPU_STRLEN; /* "no value" sentinel */
    } else {
        v.data = s;
        v.length = strlen(s);
    }
    return v;
}

/* ════════════════════════════════════════════════════════════════════
   Bridge enum → wgpu enum mapping
   ════════════════════════════════════════════════════════════════════ */

static WGPUTextureFormat to_wgpu_format(WGPUBridgeTextureFormat f) {
    switch (f) {
        case WGPUBridge_TextureFormat_BGRA8Unorm:   return WGPUTextureFormat_BGRA8Unorm;
        case WGPUBridge_TextureFormat_RGBA8Unorm:   return WGPUTextureFormat_RGBA8Unorm;
        case WGPUBridge_TextureFormat_R8Unorm:      return WGPUTextureFormat_R8Unorm;
        case WGPUBridge_TextureFormat_RGBA16Float:  return WGPUTextureFormat_RGBA16Float;
        case WGPUBridge_TextureFormat_Depth24Plus:  return WGPUTextureFormat_Depth24Plus;
        case WGPUBridge_TextureFormat_Depth32Float: return WGPUTextureFormat_Depth32Float;
        default:                                    return WGPUTextureFormat_BGRA8Unorm;
    }
}

static WGPUPresentMode to_wgpu_present_mode(WGPUBridgePresentMode m) {
    switch (m) {
        case WGPUBridge_PresentMode_Fifo:        return WGPUPresentMode_Fifo;
        case WGPUBridge_PresentMode_FifoRelaxed: return WGPUPresentMode_FifoRelaxed;
        case WGPUBridge_PresentMode_Immediate:   return WGPUPresentMode_Immediate;
        case WGPUBridge_PresentMode_Mailbox:     return WGPUPresentMode_Mailbox;
        default:                                 return WGPUPresentMode_Fifo;
    }
}

static WGPULoadOp to_wgpu_load_op(WGPUBridgeLoadOp op) {
    switch (op) {
        case WGPUBridge_LoadOp_Clear: return WGPULoadOp_Clear;
        case WGPUBridge_LoadOp_Load:  return WGPULoadOp_Load;
        default:                      return WGPULoadOp_Clear;
    }
}

static WGPUStoreOp to_wgpu_store_op(WGPUBridgeStoreOp op) {
    switch (op) {
        case WGPUBridge_StoreOp_Store:   return WGPUStoreOp_Store;
        case WGPUBridge_StoreOp_Discard: return WGPUStoreOp_Discard;
        default:                         return WGPUStoreOp_Store;
    }
}

static WGPUPrimitiveTopology to_wgpu_topology(WGPUBridgePrimitiveTopology t) {
    switch (t) {
        case WGPUBridge_PrimitiveTopology_PointList:     return WGPUPrimitiveTopology_PointList;
        case WGPUBridge_PrimitiveTopology_LineList:      return WGPUPrimitiveTopology_LineList;
        case WGPUBridge_PrimitiveTopology_LineStrip:     return WGPUPrimitiveTopology_LineStrip;
        case WGPUBridge_PrimitiveTopology_TriangleList:  return WGPUPrimitiveTopology_TriangleList;
        case WGPUBridge_PrimitiveTopology_TriangleStrip: return WGPUPrimitiveTopology_TriangleStrip;
        default:                                         return WGPUPrimitiveTopology_TriangleList;
    }
}

static WGPUVertexFormat to_wgpu_vertex_format(WGPUBridgeVertexFormat f) {
    switch (f) {
        case WGPUBridge_VertexFormat_Float32:   return WGPUVertexFormat_Float32;
        case WGPUBridge_VertexFormat_Float32x2: return WGPUVertexFormat_Float32x2;
        case WGPUBridge_VertexFormat_Float32x3: return WGPUVertexFormat_Float32x3;
        case WGPUBridge_VertexFormat_Float32x4: return WGPUVertexFormat_Float32x4;
        case WGPUBridge_VertexFormat_Uint32:    return WGPUVertexFormat_Uint32;
        case WGPUBridge_VertexFormat_Uint8x4:   return WGPUVertexFormat_Uint8x4;
        case WGPUBridge_VertexFormat_Unorm8x4:  return WGPUVertexFormat_Unorm8x4;
        case WGPUBridge_VertexFormat_Snorm8x4:  return WGPUVertexFormat_Snorm8x4;
        case WGPUBridge_VertexFormat_Uint16x2:  return WGPUVertexFormat_Uint16x2;
        case WGPUBridge_VertexFormat_Uint16x4:  return WGPUVertexFormat_Uint16x4;
        case WGPUBridge_VertexFormat_Sint16x2:  return WGPUVertexFormat_Sint16x2;
        case WGPUBridge_VertexFormat_Snorm16x2: return WGPUVertexFormat_Snorm16x2;
        case WGPUBridge_VertexFormat_Float16x2: return WGPUVertexFormat_Float16x2;
        case WGPUBridge_VertexFormat_Float16x4: return WGPUVertexFormat_Float16x4;
        default:                                return WGPUVertexFormat_Float32x3;
    }
}

static WGPUCullMode to_wgpu_cull_mode(WGPUBridgeCullMode m) {
    switch (m) {
        case WGPUBridge_CullMode_None:  return WGPUCullMode_None;
        case WGPUBridge_CullMode_Front: return WGPUCullMode_Front;
        case WGPUBridge_CullMode_Back:  return WGPUCullMode_Back;
        default:                        return WGPUCullMode_None;
    }
}

static WGPUFrontFace to_wgpu_front_face(WGPUBridgeFrontFace f) {
    switch (f) {
        case WGPUBridge_FrontFace_CCW: return WGPUFrontFace_CCW;
        case WGPUBridge_FrontFace_CW:  return WGPUFrontFace_CW;
        default:                       return WGPUFrontFace_CCW;
    }
}

static WGPUBlendOperation to_wgpu_blend_op(WGPUBridgeBlendOp op) {
    switch (op) {
        case WGPUBridge_BlendOp_Add:             return WGPUBlendOperation_Add;
        case WGPUBridge_BlendOp_Subtract:        return WGPUBlendOperation_Subtract;
        case WGPUBridge_BlendOp_ReverseSubtract: return WGPUBlendOperation_ReverseSubtract;
        case WGPUBridge_BlendOp_Min:             return WGPUBlendOperation_Min;
        case WGPUBridge_BlendOp_Max:             return WGPUBlendOperation_Max;
        default:                                 return WGPUBlendOperation_Add;
    }
}

static WGPUBlendFactor to_wgpu_blend_factor(WGPUBridgeBlendFactor f) {
    switch (f) {
        case WGPUBridge_BlendFactor_Zero:             return WGPUBlendFactor_Zero;
        case WGPUBridge_BlendFactor_One:              return WGPUBlendFactor_One;
        case WGPUBridge_BlendFactor_Src:              return WGPUBlendFactor_Src;
        case WGPUBridge_BlendFactor_OneMinusSrc:      return WGPUBlendFactor_OneMinusSrc;
        case WGPUBridge_BlendFactor_SrcAlpha:         return WGPUBlendFactor_SrcAlpha;
        case WGPUBridge_BlendFactor_OneMinusSrcAlpha: return WGPUBlendFactor_OneMinusSrcAlpha;
        case WGPUBridge_BlendFactor_Dst:              return WGPUBlendFactor_Dst;
        case WGPUBridge_BlendFactor_OneMinusDst:      return WGPUBlendFactor_OneMinusDst;
        case WGPUBridge_BlendFactor_DstAlpha:         return WGPUBlendFactor_DstAlpha;
        case WGPUBridge_BlendFactor_OneMinusDstAlpha: return WGPUBlendFactor_OneMinusDstAlpha;
        default:                                      return WGPUBlendFactor_One;
    }
}

static WGPUIndexFormat to_wgpu_index_format(WGPUBridgeIndexFormat f) {
    switch (f) {
        case WGPUBridge_IndexFormat_Uint16: return WGPUIndexFormat_Uint16;
        case WGPUBridge_IndexFormat_Uint32: return WGPUIndexFormat_Uint32;
        default:                            return WGPUIndexFormat_Uint32;
    }
}

static WGPUFilterMode to_wgpu_filter(WGPUBridgeFilterMode f) {
    switch (f) {
        case WGPUBridge_FilterMode_Nearest: return WGPUFilterMode_Nearest;
        case WGPUBridge_FilterMode_Linear:  return WGPUFilterMode_Linear;
        default:                            return WGPUFilterMode_Nearest;
    }
}

static WGPUMipmapFilterMode to_wgpu_mipmap_filter(WGPUBridgeFilterMode f) {
    switch (f) {
        case WGPUBridge_FilterMode_Nearest: return WGPUMipmapFilterMode_Nearest;
        case WGPUBridge_FilterMode_Linear:  return WGPUMipmapFilterMode_Linear;
        default:                            return WGPUMipmapFilterMode_Nearest;
    }
}

static WGPUAddressMode to_wgpu_address_mode(WGPUBridgeAddressMode a) {
    switch (a) {
        case WGPUBridge_AddressMode_ClampToEdge:  return WGPUAddressMode_ClampToEdge;
        case WGPUBridge_AddressMode_Repeat:       return WGPUAddressMode_Repeat;
        case WGPUBridge_AddressMode_MirrorRepeat: return WGPUAddressMode_MirrorRepeat;
        default:                                  return WGPUAddressMode_ClampToEdge;
    }
}

static WGPUCompareFunction to_wgpu_compare(WGPUBridgeCompareFunction f) {
    switch (f) {
        case WGPUBridge_CompareFunction_Never:        return WGPUCompareFunction_Never;
        case WGPUBridge_CompareFunction_Less:         return WGPUCompareFunction_Less;
        case WGPUBridge_CompareFunction_Equal:        return WGPUCompareFunction_Equal;
        case WGPUBridge_CompareFunction_LessEqual:    return WGPUCompareFunction_LessEqual;
        case WGPUBridge_CompareFunction_Greater:      return WGPUCompareFunction_Greater;
        case WGPUBridge_CompareFunction_NotEqual:     return WGPUCompareFunction_NotEqual;
        case WGPUBridge_CompareFunction_GreaterEqual: return WGPUCompareFunction_GreaterEqual;
        case WGPUBridge_CompareFunction_Always:       return WGPUCompareFunction_Always;
        default:                                      return WGPUCompareFunction_Less;
    }
}

static WGPUBackendType to_wgpu_backend_type(WGPUBridgeBackendType type) {
    switch (type) {
        case WGPUBridge_BackendType_D3D11:   return WGPUBackendType_D3D11;
        case WGPUBridge_BackendType_D3D12:   return WGPUBackendType_D3D12;
        case WGPUBridge_BackendType_Metal:   return WGPUBackendType_Metal;
        case WGPUBridge_BackendType_Vulkan:  return WGPUBackendType_Vulkan;
        case WGPUBridge_BackendType_OpenGL:  return WGPUBackendType_OpenGL;
        case WGPUBridge_BackendType_OpenGLES:return WGPUBackendType_OpenGLES;
        case WGPUBridge_BackendType_Undefined:
        default:                             return WGPUBackendType_Undefined;
    }
}

static WGPUStencilOperation to_wgpu_stencil_op(WGPUBridgeStencilOp op) {
    switch (op) {
        case WGPUBridge_StencilOp_Keep:      return WGPUStencilOperation_Keep;
        case WGPUBridge_StencilOp_Zero:      return WGPUStencilOperation_Zero;
        case WGPUBridge_StencilOp_Replace:   return WGPUStencilOperation_Replace;
        case WGPUBridge_StencilOp_Invert:    return WGPUStencilOperation_Invert;
        case WGPUBridge_StencilOp_IncrClamp: return WGPUStencilOperation_IncrementClamp;
        case WGPUBridge_StencilOp_DecrClamp: return WGPUStencilOperation_DecrementClamp;
        case WGPUBridge_StencilOp_IncrWrap:  return WGPUStencilOperation_IncrementWrap;
        case WGPUBridge_StencilOp_DecrWrap:  return WGPUStencilOperation_DecrementWrap;
        default:                             return WGPUStencilOperation_Keep;
    }
}

static WGPUTextureViewDimension to_wgpu_view_dim(WGPUBridgeTextureViewDimension d) {
    switch (d) {
        case WGPUBridge_TextureViewDimension_2D:        return WGPUTextureViewDimension_2D;
        case WGPUBridge_TextureViewDimension_2DArray:   return WGPUTextureViewDimension_2DArray;
        case WGPUBridge_TextureViewDimension_Cube:      return WGPUTextureViewDimension_Cube;
        case WGPUBridge_TextureViewDimension_CubeArray: return WGPUTextureViewDimension_CubeArray;
        case WGPUBridge_TextureViewDimension_3D:        return WGPUTextureViewDimension_3D;
        default:                                        return WGPUTextureViewDimension_2D;
    }
}

/* Bridge BufferUsage flag bits map directly to WGPUBufferUsage_* values.
   We translate by composing flags. */
static WGPUBufferUsage to_wgpu_buffer_usage(int bridge_flags) {
    WGPUBufferUsage u = WGPUBufferUsage_None;
    if (bridge_flags & WGPUBridge_BufferUsage_MapRead)  u |= WGPUBufferUsage_MapRead;
    if (bridge_flags & WGPUBridge_BufferUsage_CopySrc)  u |= WGPUBufferUsage_CopySrc;
    if (bridge_flags & WGPUBridge_BufferUsage_CopyDst)  u |= WGPUBufferUsage_CopyDst;
    if (bridge_flags & WGPUBridge_BufferUsage_Index)    u |= WGPUBufferUsage_Index;
    if (bridge_flags & WGPUBridge_BufferUsage_Vertex)   u |= WGPUBufferUsage_Vertex;
    if (bridge_flags & WGPUBridge_BufferUsage_Uniform)  u |= WGPUBufferUsage_Uniform;
    if (bridge_flags & WGPUBridge_BufferUsage_Storage)  u |= WGPUBufferUsage_Storage;
    if (bridge_flags & WGPUBridge_BufferUsage_Indirect) u |= WGPUBufferUsage_Indirect;
    return u;
}

static WGPUTextureUsage to_wgpu_texture_usage(int bridge_flags) {
    WGPUTextureUsage u = WGPUTextureUsage_None;
    if (bridge_flags & WGPUBridge_TextureUsage_CopySrc)          u |= WGPUTextureUsage_CopySrc;
    if (bridge_flags & WGPUBridge_TextureUsage_CopyDst)          u |= WGPUTextureUsage_CopyDst;
    if (bridge_flags & WGPUBridge_TextureUsage_TextureBinding)   u |= WGPUTextureUsage_TextureBinding;
    if (bridge_flags & WGPUBridge_TextureUsage_StorageBinding)   u |= WGPUTextureUsage_StorageBinding;
    if (bridge_flags & WGPUBridge_TextureUsage_RenderAttachment) u |= WGPUTextureUsage_RenderAttachment;
    return u;
}

static WGPUShaderStage to_wgpu_shader_stage(int bridge_flags) {
    WGPUShaderStage s = WGPUShaderStage_None;
    if (bridge_flags & WGPUBridge_ShaderStage_Vertex)   s |= WGPUShaderStage_Vertex;
    if (bridge_flags & WGPUBridge_ShaderStage_Fragment) s |= WGPUShaderStage_Fragment;
    if (bridge_flags & WGPUBridge_ShaderStage_Compute)  s |= WGPUShaderStage_Compute;
    return s;
}

/* ════════════════════════════════════════════════════════════════════
   Async wait helper (Future model)
   ════════════════════════════════════════════════════════════════════ */

typedef struct {
    int done;
    int success;
    void* object; /* WGPUAdapter or WGPUDevice */
    char message[256];
} AsyncResult;

static void on_request_adapter(WGPURequestAdapterStatus status,
                               WGPUAdapter adapter,
                               WGPUStringView message,
                               void* userdata1, void* userdata2) {
    (void)userdata2;
    AsyncResult* r = (AsyncResult*)userdata1;
    r->done = 1;
    if (status == WGPURequestAdapterStatus_Success && adapter != NULL) {
        r->success = 1;
        r->object = (void*)adapter;
    } else {
        r->success = 0;
        if (message.data && message.length > 0) {
            size_t n = message.length < sizeof(r->message) - 1 ? message.length : sizeof(r->message) - 1;
            memcpy(r->message, message.data, n);
            r->message[n] = '\0';
        }
    }
}

static void on_request_device(WGPURequestDeviceStatus status,
                              WGPUDevice device,
                              WGPUStringView message,
                              void* userdata1, void* userdata2) {
    (void)userdata2;
    AsyncResult* r = (AsyncResult*)userdata1;
    r->done = 1;
    if (status == WGPURequestDeviceStatus_Success && device != NULL) {
        r->success = 1;
        r->object = (void*)device;
    } else {
        r->success = 0;
        if (message.data && message.length > 0) {
            size_t n = message.length < sizeof(r->message) - 1 ? message.length : sizeof(r->message) - 1;
            memcpy(r->message, message.data, n);
            r->message[n] = '\0';
        }
    }
}

/* ════════════════════════════════════════════════════════════════════
   Lifecycle
   ════════════════════════════════════════════════════════════════════ */

int wgpu_bridge_initialize(const char* library_path) {
    /* Direct linking — no symbol load required. Argument retained for ABI compat. */
    (void)library_path;
    set_error(NULL);
    return 1;
}

int wgpu_bridge_create_instance(void** out_instance) {
    if (out_instance == NULL) { set_error("out_instance is null"); return 0; }
    *out_instance = NULL;
    WGPUInstanceDescriptor desc = WGPU_INSTANCE_DESCRIPTOR_INIT;
    WGPUInstance inst = wgpuCreateInstance(&desc);
    if (inst == NULL) { set_error("wgpuCreateInstance returned null"); return 0; }
    *out_instance = (void*)inst;
    return 1;
}

int wgpu_bridge_request_adapter_with_backend(void* instance,
                                             WGPUBridgeBackendType backend_type,
                                             void** out_adapter) {
    if (instance == NULL || out_adapter == NULL) {
        set_error("invalid request_adapter arguments");
        return 0;
    }
    *out_adapter = NULL;

    AsyncResult result = {0};
    WGPURequestAdapterOptions options = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
    options.backendType = to_wgpu_backend_type(backend_type);
    options.powerPreference = WGPUPowerPreference_HighPerformance;

    WGPURequestAdapterCallbackInfo cb = WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT;
    cb.mode = WGPUCallbackMode_AllowProcessEvents;
    cb.callback = on_request_adapter;
    cb.userdata1 = &result;

    wgpuInstanceRequestAdapter((WGPUInstance)instance, &options, cb);

    /* Spin processEvents until callback fires (synchronous bridge contract). */
    for (int i = 0; i < 10000 && !result.done; ++i) {
        wgpuInstanceProcessEvents((WGPUInstance)instance);
    }

    if (!result.done) { set_error("wgpuInstanceRequestAdapter timed out"); return 0; }
    if (!result.success) {
        set_error(result.message[0] ? result.message : "wgpuInstanceRequestAdapter failed");
        return 0;
    }

    *out_adapter = result.object;
    return 1;
}

int wgpu_bridge_request_adapter(void* instance, void** out_adapter) {
    return wgpu_bridge_request_adapter_with_backend(
        instance,
        WGPUBridge_BackendType_Undefined,
        out_adapter);
}

int wgpu_bridge_request_device(void* adapter, void** out_device) {
    if (adapter == NULL || out_device == NULL) {
        set_error("invalid request_device arguments");
        return 0;
    }
    *out_device = NULL;

    AsyncResult result = {0};
    WGPUDeviceDescriptor desc = WGPU_DEVICE_DESCRIPTOR_INIT;

    WGPURequestDeviceCallbackInfo cb = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
    cb.mode = WGPUCallbackMode_AllowProcessEvents;
    cb.callback = on_request_device;
    cb.userdata1 = &result;

    wgpuAdapterRequestDevice((WGPUAdapter)adapter, &desc, cb);

    /* The adapter's owning instance handle isn't directly exposed; v29
       processes device callbacks via the same instance event loop. We poll
       via wgpuDevicePoll once the device exists, but during request we
       have to use the adapter's instance handle. wgpuAdapterGetInstance
       isn't standard; instead the AllowProcessEvents mode means the
       callback fires only inside wgpuInstanceProcessEvents. Without an
       instance handle we drive completion via wgpuAdapterInfo style
       blocking — wgpu-native fires this synchronously during the call. */
    if (!result.done) { set_error("wgpuAdapterRequestDevice did not complete synchronously"); return 0; }
    if (!result.success) {
        set_error(result.message[0] ? result.message : "wgpuAdapterRequestDevice failed");
        return 0;
    }

    *out_device = result.object;
    return 1;
}

int wgpu_bridge_get_queue(void* device, void** out_queue) {
    if (device == NULL || out_queue == NULL) { set_error("invalid get_queue"); return 0; }
    WGPUQueue q = wgpuDeviceGetQueue((WGPUDevice)device);
    if (q == NULL) { set_error("wgpuDeviceGetQueue returned null"); return 0; }
    *out_queue = (void*)q;
    return 1;
}

int wgpu_bridge_release_queue(void* queue) {
    if (queue) wgpuQueueRelease((WGPUQueue)queue);
    return 1;
}
int wgpu_bridge_release_device(void* device) {
    if (device) wgpuDeviceRelease((WGPUDevice)device);
    return 1;
}
int wgpu_bridge_release_adapter(void* adapter) {
    if (adapter) wgpuAdapterRelease((WGPUAdapter)adapter);
    return 1;
}
int wgpu_bridge_release_instance(void* instance) {
    if (instance) wgpuInstanceRelease((WGPUInstance)instance);
    return 1;
}

void wgpu_bridge_shutdown(void) {
    /* Direct linking — no library handle to release. */
    set_error(NULL);
}

/* ════════════════════════════════════════════════════════════════════
   Surface
   ════════════════════════════════════════════════════════════════════ */

static int create_surface_from_chain(void* instance,
                                     WGPUChainedStruct* chain,
                                     void** out_surface,
                                     const char* invalid_args_error) {
    if (instance == NULL || chain == NULL || out_surface == NULL) {
        set_error(invalid_args_error);
        return 0;
    }

    WGPUSurfaceDescriptor desc = WGPU_SURFACE_DESCRIPTOR_INIT;
    desc.nextInChain = chain;

    WGPUSurface surface = wgpuInstanceCreateSurface((WGPUInstance)instance, &desc);
    if (surface == NULL) {
        set_error("wgpuInstanceCreateSurface returned null");
        return 0;
    }

    *out_surface = (void*)surface;
    return 1;
}

int wgpu_bridge_create_surface_metal(void* instance, void* ca_metal_layer, void** out_surface) {
    if (ca_metal_layer == NULL) {
        set_error("invalid create_surface_metal arguments");
        return 0;
    }

    WGPUSurfaceSourceMetalLayer metal = WGPU_SURFACE_SOURCE_METAL_LAYER_INIT;
    metal.layer = ca_metal_layer;

    return create_surface_from_chain(
        instance,
        (WGPUChainedStruct*)&metal,
        out_surface,
        "invalid create_surface_metal arguments");
}

int wgpu_bridge_create_surface_win32(void* instance, void* hwnd, void* hinstance, void** out_surface) {
    if (hwnd == NULL) {
        set_error("invalid create_surface_win32 arguments");
        return 0;
    }

    WGPUSurfaceSourceWindowsHWND win32 = WGPU_SURFACE_SOURCE_WINDOWS_HWND_INIT;
    win32.hwnd = hwnd;
    win32.hinstance = hinstance;

    return create_surface_from_chain(
        instance,
        (WGPUChainedStruct*)&win32,
        out_surface,
        "invalid create_surface_win32 arguments");
}

int wgpu_bridge_create_surface_wayland(void* instance, void* display, void* surface, void** out_surface) {
    if (display == NULL || surface == NULL) {
        set_error("invalid create_surface_wayland arguments");
        return 0;
    }

    WGPUSurfaceSourceWaylandSurface wayland = WGPU_SURFACE_SOURCE_WAYLAND_SURFACE_INIT;
    wayland.display = display;
    wayland.surface = surface;

    return create_surface_from_chain(
        instance,
        (WGPUChainedStruct*)&wayland,
        out_surface,
        "invalid create_surface_wayland arguments");
}

int wgpu_bridge_create_surface_xlib(void* instance, void* display, uint64_t window, void** out_surface) {
    if (display == NULL || window == 0) {
        set_error("invalid create_surface_xlib arguments");
        return 0;
    }

    WGPUSurfaceSourceXlibWindow xlib = WGPU_SURFACE_SOURCE_XLIB_WINDOW_INIT;
    xlib.display = display;
    xlib.window = window;

    return create_surface_from_chain(
        instance,
        (WGPUChainedStruct*)&xlib,
        out_surface,
        "invalid create_surface_xlib arguments");
}

int wgpu_bridge_configure_surface(void* surface, void* device,
                                  WGPUBridgeTextureFormat format,
                                  uint32_t width, uint32_t height,
                                  WGPUBridgePresentMode present_mode) {
    if (surface == NULL || device == NULL) {
        set_error("invalid configure_surface arguments");
        return 0;
    }
    WGPUSurfaceConfiguration cfg = WGPU_SURFACE_CONFIGURATION_INIT;
    cfg.device      = (WGPUDevice)device;
    cfg.format      = to_wgpu_format(format);
    cfg.usage       = WGPUTextureUsage_RenderAttachment;
    cfg.width       = width;
    cfg.height      = height;
    cfg.alphaMode   = WGPUCompositeAlphaMode_Auto;
    cfg.presentMode = to_wgpu_present_mode(present_mode);
    wgpuSurfaceConfigure((WGPUSurface)surface, &cfg);
    return 1;
}

int wgpu_bridge_surface_get_current_texture_view(void* surface,
                                                 void** out_texture,
                                                 void** out_view) {
    if (surface == NULL || out_view == NULL) {
        set_error("invalid surface_get_current_texture_view arguments");
        return 0;
    }

    WGPUSurfaceTexture st = WGPU_SURFACE_TEXTURE_INIT;
    wgpuSurfaceGetCurrentTexture((WGPUSurface)surface, &st);

    /* v29 wgpu-native introduced an Occluded status for windows that the
       compositor doesn't currently composite (e.g. fully covered, off-screen,
       or in transient state right after creation). v22 collapsed this case
       into Success. We treat it the same way the renderer treated v22:
       skip the frame silently without recording an error. The renderer
       checks the return value and simply waits for the next tick. */
    /* WGPUSurfaceGetCurrentTextureStatus_Occluded is declared inside the
       WGPUNativeSurfaceGetCurrentTextureStatus enum (wgpu.h), separate from
       webgpu.h's status enum. Cast to int to silence -Wenum-compare. */
    if ((int)st.status == (int)WGPUSurfaceGetCurrentTextureStatus_Occluded) {
        if (st.texture) wgpuTextureRelease(st.texture);
        return 0;
    }
    if (st.texture == NULL ||
        (st.status != WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal &&
         st.status != WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal)) {
        char buf[128];
        snprintf(buf, sizeof(buf),
                 "wgpuSurfaceGetCurrentTexture failed: status=0x%08x texture=%p",
                 (unsigned)st.status, (void*)st.texture);
        set_error(buf);
        return 0;
    }

    WGPUTextureView view = wgpuTextureCreateView(st.texture, NULL);
    if (view == NULL) { set_error("wgpuTextureCreateView returned null"); return 0; }

    if (out_texture) *out_texture = (void*)st.texture;
    *out_view = (void*)view;
    return 1;
}

void wgpu_bridge_surface_present(void* surface) {
    if (surface) wgpuSurfacePresent((WGPUSurface)surface);
}
void wgpu_bridge_release_surface(void* surface) {
    if (surface) wgpuSurfaceRelease((WGPUSurface)surface);
}

/* ════════════════════════════════════════════════════════════════════
   Texture & View
   ════════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_texture(void* device,
                               const WGPUBridgeTextureDesc* desc,
                               void** out_texture) {
    if (device == NULL || desc == NULL || out_texture == NULL) {
        set_error("invalid create_texture arguments");
        return 0;
    }
    WGPUTextureDescriptor td = WGPU_TEXTURE_DESCRIPTOR_INIT;
    td.usage = to_wgpu_texture_usage(desc->usage_flags);
    td.dimension = WGPUTextureDimension_2D;
    td.size.width = desc->width;
    td.size.height = desc->height;
    td.size.depthOrArrayLayers = desc->depth_or_layers > 0 ? desc->depth_or_layers : 1;
    td.format = to_wgpu_format(desc->format);
    td.mipLevelCount = desc->mip_level_count > 0 ? desc->mip_level_count : 1;
    td.sampleCount = desc->sample_count > 0 ? desc->sample_count : 1;

    WGPUTexture tex = wgpuDeviceCreateTexture((WGPUDevice)device, &td);
    if (tex == NULL) { set_error("wgpuDeviceCreateTexture returned null"); return 0; }
    *out_texture = (void*)tex;
    return 1;
}

int wgpu_bridge_create_texture_view_default(void* texture, void** out_view) {
    if (texture == NULL || out_view == NULL) {
        set_error("invalid create_texture_view_default arguments");
        return 0;
    }
    WGPUTextureView v = wgpuTextureCreateView((WGPUTexture)texture, NULL);
    if (v == NULL) { set_error("wgpuTextureCreateView returned null"); return 0; }
    *out_view = (void*)v;
    return 1;
}

int wgpu_bridge_create_texture_view(void* texture,
                                    const WGPUBridgeTextureViewDesc* desc,
                                    void** out_view) {
    if (texture == NULL || desc == NULL || out_view == NULL) {
        set_error("invalid create_texture_view arguments");
        return 0;
    }
    WGPUTextureViewDescriptor vd = WGPU_TEXTURE_VIEW_DESCRIPTOR_INIT;
    vd.format = to_wgpu_format(desc->format);
    vd.dimension = to_wgpu_view_dim(desc->dimension);
    vd.baseMipLevel = desc->base_mip_level;
    vd.mipLevelCount = desc->mip_level_count > 0 ? desc->mip_level_count : 1;
    vd.baseArrayLayer = desc->base_array_layer;
    vd.arrayLayerCount = desc->array_layer_count > 0 ? desc->array_layer_count : 1;
    vd.aspect = WGPUTextureAspect_All;

    WGPUTextureView v = wgpuTextureCreateView((WGPUTexture)texture, &vd);
    if (v == NULL) { set_error("wgpuTextureCreateView returned null"); return 0; }
    *out_view = (void*)v;
    return 1;
}

void wgpu_bridge_release_texture(void* texture) {
    if (texture) wgpuTextureRelease((WGPUTexture)texture);
}
void wgpu_bridge_release_texture_view(void* view) {
    if (view) wgpuTextureViewRelease((WGPUTextureView)view);
}

/* ════════════════════════════════════════════════════════════════════
   Shader Module
   ════════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_shader_module(void* device,
                                     const char* wgsl_code,
                                     const char* label,
                                     void** out_module) {
    if (device == NULL || wgsl_code == NULL || out_module == NULL) {
        set_error("invalid create_shader_module arguments");
        return 0;
    }
    WGPUShaderSourceWGSL wgsl = WGPU_SHADER_SOURCE_WGSL_INIT;
    wgsl.code = sv_from_cstr(wgsl_code);

    WGPUShaderModuleDescriptor desc = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
    desc.nextInChain = &wgsl.chain;
    desc.label = sv_from_cstr(label);

    WGPUShaderModule m = wgpuDeviceCreateShaderModule((WGPUDevice)device, &desc);
    if (m == NULL) { set_error("wgpuDeviceCreateShaderModule returned null"); return 0; }
    *out_module = (void*)m;
    return 1;
}

void wgpu_bridge_release_shader_module(void* module) {
    if (module) wgpuShaderModuleRelease((WGPUShaderModule)module);
}

/* ════════════════════════════════════════════════════════════════════
   Render Pipeline (single target)
   ════════════════════════════════════════════════════════════════════ */

static void fill_depth_stencil_state(WGPUDepthStencilState* out,
                                     const WGPUBridgeDepthStencilPipelineState* in) {
    *out = (WGPUDepthStencilState)WGPU_DEPTH_STENCIL_STATE_INIT;
    out->format = to_wgpu_format(in->format);
    out->depthWriteEnabled = in->depth_write_enabled
        ? WGPUOptionalBool_True : WGPUOptionalBool_False;
    out->depthCompare = to_wgpu_compare(in->depth_compare);
    out->stencilFront.compare = to_wgpu_compare(in->stencil_front.compare);
    out->stencilFront.failOp = to_wgpu_stencil_op(in->stencil_front.fail_op);
    out->stencilFront.depthFailOp = to_wgpu_stencil_op(in->stencil_front.depth_fail_op);
    out->stencilFront.passOp = to_wgpu_stencil_op(in->stencil_front.pass_op);
    out->stencilBack.compare = to_wgpu_compare(in->stencil_back.compare);
    out->stencilBack.failOp = to_wgpu_stencil_op(in->stencil_back.fail_op);
    out->stencilBack.depthFailOp = to_wgpu_stencil_op(in->stencil_back.depth_fail_op);
    out->stencilBack.passOp = to_wgpu_stencil_op(in->stencil_back.pass_op);
    out->stencilReadMask = in->stencil_read_mask;
    out->stencilWriteMask = in->stencil_write_mask;
}

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
    uint32_t sample_count,
    void* pipeline_layout,
    void** out_pipeline)
{
    if (device == NULL || shader_module == NULL || out_pipeline == NULL) {
        set_error("invalid create_render_pipeline arguments");
        return 0;
    }

    WGPUVertexBufferLayout* vb_layouts = NULL;
    WGPUVertexAttribute* all_attrs = NULL;

    if (vertex_buffer_count > 0 && vertex_buffers != NULL) {
        vb_layouts = (WGPUVertexBufferLayout*)calloc(vertex_buffer_count, sizeof(WGPUVertexBufferLayout));
        uint32_t total_attrs = 0;
        for (uint32_t i = 0; i < vertex_buffer_count; ++i) total_attrs += vertex_buffers[i].attribute_count;
        if (total_attrs > 0) all_attrs = (WGPUVertexAttribute*)calloc(total_attrs, sizeof(WGPUVertexAttribute));

        uint32_t off = 0;
        for (uint32_t i = 0; i < vertex_buffer_count; ++i) {
            vb_layouts[i] = (WGPUVertexBufferLayout)WGPU_VERTEX_BUFFER_LAYOUT_INIT;
            vb_layouts[i].arrayStride = vertex_buffers[i].array_stride;
            vb_layouts[i].stepMode = WGPUVertexStepMode_Vertex;
            vb_layouts[i].attributeCount = vertex_buffers[i].attribute_count;
            vb_layouts[i].attributes = vertex_buffers[i].attribute_count ? &all_attrs[off] : NULL;
            for (uint32_t j = 0; j < vertex_buffers[i].attribute_count; ++j) {
                all_attrs[off + j] = (WGPUVertexAttribute)WGPU_VERTEX_ATTRIBUTE_INIT;
                all_attrs[off + j].format = to_wgpu_vertex_format(vertex_buffers[i].attributes[j].format);
                all_attrs[off + j].offset = vertex_buffers[i].attributes[j].offset;
                all_attrs[off + j].shaderLocation = vertex_buffers[i].attributes[j].shader_location;
            }
            off += vertex_buffers[i].attribute_count;
        }
    }

    WGPUBlendState blend_state = WGPU_BLEND_STATE_INIT;
    if (blend != NULL) {
        blend_state.color.operation = to_wgpu_blend_op(blend->color.operation);
        blend_state.color.srcFactor = to_wgpu_blend_factor(blend->color.src_factor);
        blend_state.color.dstFactor = to_wgpu_blend_factor(blend->color.dst_factor);
        blend_state.alpha.operation = to_wgpu_blend_op(blend->alpha.operation);
        blend_state.alpha.srcFactor = to_wgpu_blend_factor(blend->alpha.src_factor);
        blend_state.alpha.dstFactor = to_wgpu_blend_factor(blend->alpha.dst_factor);
    }

    WGPUColorTargetState color_target = WGPU_COLOR_TARGET_STATE_INIT;
    color_target.format = to_wgpu_format(color_format);
    color_target.writeMask = WGPUColorWriteMask_All;
    if (blend != NULL) color_target.blend = &blend_state;

    WGPUFragmentState frag = WGPU_FRAGMENT_STATE_INIT;
    frag.module = (WGPUShaderModule)shader_module;
    frag.entryPoint = sv_from_cstr(fragment_entry);
    frag.targetCount = 1;
    frag.targets = &color_target;

    WGPURenderPipelineDescriptor desc = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
    desc.vertex.module = (WGPUShaderModule)shader_module;
    desc.vertex.entryPoint = sv_from_cstr(vertex_entry);
    desc.vertex.bufferCount = vertex_buffer_count;
    desc.vertex.buffers = vb_layouts;
    desc.primitive.topology = to_wgpu_topology(topology);
    desc.primitive.frontFace = to_wgpu_front_face(front_face);
    desc.primitive.cullMode = to_wgpu_cull_mode(cull_mode);
    desc.multisample.count = sample_count > 0 ? sample_count : 1;
    desc.multisample.mask = 0xFFFFFFFF;
    desc.fragment = &frag;
    desc.layout = (WGPUPipelineLayout)pipeline_layout;

    WGPUDepthStencilState ds;
    if (depth_stencil != NULL) {
        fill_depth_stencil_state(&ds, depth_stencil);
        desc.depthStencil = &ds;
    }

    WGPURenderPipeline pipeline = wgpuDeviceCreateRenderPipeline((WGPUDevice)device, &desc);

    free(all_attrs);
    free(vb_layouts);

    if (pipeline == NULL) { set_error("wgpuDeviceCreateRenderPipeline returned null"); return 0; }
    *out_pipeline = (void*)pipeline;
    return 1;
}

void wgpu_bridge_release_render_pipeline(void* pipeline) {
    if (pipeline) wgpuRenderPipelineRelease((WGPURenderPipeline)pipeline);
}

int wgpu_bridge_render_pipeline_get_bind_group_layout(void* pipeline,
                                                      uint32_t group_index,
                                                      void** out_layout) {
    if (pipeline == NULL || out_layout == NULL) {
        set_error("invalid get_bind_group_layout arguments");
        return 0;
    }
    WGPUBindGroupLayout bgl = wgpuRenderPipelineGetBindGroupLayout(
        (WGPURenderPipeline)pipeline, group_index);
    if (bgl == NULL) {
        set_error("wgpuRenderPipelineGetBindGroupLayout returned null");
        return 0;
    }
    *out_layout = (void*)bgl;
    return 1;
}

/* ════════════════════════════════════════════════════════════════════
   Buffer
   ════════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_buffer(void* device,
                              const WGPUBridgeBufferDesc* desc,
                              void** out_buffer) {
    if (device == NULL || desc == NULL || out_buffer == NULL) {
        set_error("invalid create_buffer arguments");
        return 0;
    }
    WGPUBufferDescriptor bd = WGPU_BUFFER_DESCRIPTOR_INIT;
    bd.usage = to_wgpu_buffer_usage(desc->usage_flags);
    bd.size = desc->size;
    bd.mappedAtCreation = desc->mapped_at_creation ? WGPU_TRUE : WGPU_FALSE;

    WGPUBuffer buf = wgpuDeviceCreateBuffer((WGPUDevice)device, &bd);
    if (buf == NULL) { set_error("wgpuDeviceCreateBuffer returned null"); return 0; }
    *out_buffer = (void*)buf;
    return 1;
}

void wgpu_bridge_write_buffer(void* queue, void* buffer,
                              uint64_t offset, const void* data, size_t size) {
    if (queue && buffer && data && size > 0) {
        wgpuQueueWriteBuffer((WGPUQueue)queue, (WGPUBuffer)buffer, offset, data, size);
    }
}

void wgpu_bridge_release_buffer(void* buffer) {
    if (buffer) wgpuBufferRelease((WGPUBuffer)buffer);
}

/* ════════════════════════════════════════════════════════════════════
   Command Encoding & Render Pass
   ════════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_command_encoder(void* device, void** out_encoder) {
    if (device == NULL || out_encoder == NULL) {
        set_error("invalid create_command_encoder arguments");
        return 0;
    }
    WGPUCommandEncoderDescriptor desc = WGPU_COMMAND_ENCODER_DESCRIPTOR_INIT;
    WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder((WGPUDevice)device, &desc);
    if (enc == NULL) { set_error("wgpuDeviceCreateCommandEncoder returned null"); return 0; }
    *out_encoder = (void*)enc;
    return 1;
}

int wgpu_bridge_begin_render_pass(void* encoder,
                                  void* color_view,
                                  void* resolve_target_view,
                                  WGPUBridgeLoadOp load_op,
                                  WGPUBridgeStoreOp store_op,
                                  WGPUBridgeColor clear_color,
                                  const WGPUBridgeDepthStencilAttachment* depth,
                                  void** out_pass) {
    if (encoder == NULL || out_pass == NULL) {
        set_error("invalid begin_render_pass arguments");
        return 0;
    }

    WGPURenderPassColorAttachment ca = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
    size_t color_count = 0;
    if (color_view != NULL) {
        ca.view = (WGPUTextureView)color_view;
        ca.resolveTarget = resolve_target_view != NULL
            ? (WGPUTextureView)resolve_target_view
            : NULL;
        ca.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
        ca.loadOp = to_wgpu_load_op(load_op);
        ca.storeOp = to_wgpu_store_op(store_op);
        ca.clearValue.r = clear_color.r;
        ca.clearValue.g = clear_color.g;
        ca.clearValue.b = clear_color.b;
        ca.clearValue.a = clear_color.a;
        color_count = 1;
    }

    WGPURenderPassDepthStencilAttachment dsa = WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
    WGPURenderPassDescriptor desc = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
    desc.colorAttachmentCount = color_count;
    desc.colorAttachments = color_count > 0 ? &ca : NULL;

    if (depth != NULL && depth->view != NULL) {
        dsa.view = (WGPUTextureView)depth->view;
        dsa.depthLoadOp = to_wgpu_load_op(depth->depth_load_op);
        dsa.depthStoreOp = to_wgpu_store_op(depth->depth_store_op);
        dsa.depthClearValue = depth->clear_depth;
        dsa.stencilLoadOp = to_wgpu_load_op(depth->stencil_load_op);
        dsa.stencilStoreOp = to_wgpu_store_op(depth->stencil_store_op);
        dsa.stencilClearValue = depth->stencil_clear_value;
        desc.depthStencilAttachment = &dsa;
    }

    WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass((WGPUCommandEncoder)encoder, &desc);
    if (pass == NULL) { set_error("wgpuCommandEncoderBeginRenderPass returned null"); return 0; }
    *out_pass = (void*)pass;
    return 1;
}

void wgpu_bridge_render_pass_set_pipeline(void* pass, void* pipeline) {
    if (pass && pipeline)
        wgpuRenderPassEncoderSetPipeline((WGPURenderPassEncoder)pass, (WGPURenderPipeline)pipeline);
}

void wgpu_bridge_render_pass_set_vertex_buffer(void* pass, uint32_t slot,
                                               void* buffer, uint64_t offset, uint64_t size) {
    if (pass && buffer)
        wgpuRenderPassEncoderSetVertexBuffer((WGPURenderPassEncoder)pass, slot,
                                             (WGPUBuffer)buffer, offset, size);
}

void wgpu_bridge_render_pass_set_index_buffer(void* pass, void* buffer,
                                              WGPUBridgeIndexFormat format,
                                              uint64_t offset, uint64_t size) {
    if (pass && buffer)
        wgpuRenderPassEncoderSetIndexBuffer((WGPURenderPassEncoder)pass, (WGPUBuffer)buffer,
                                            to_wgpu_index_format(format), offset, size);
}

void wgpu_bridge_render_pass_draw(void* pass,
                                  uint32_t vertex_count, uint32_t instance_count,
                                  uint32_t first_vertex, uint32_t first_instance) {
    if (pass)
        wgpuRenderPassEncoderDraw((WGPURenderPassEncoder)pass,
                                  vertex_count, instance_count, first_vertex, first_instance);
}

void wgpu_bridge_render_pass_draw_indexed(void* pass,
                                          uint32_t index_count, uint32_t instance_count,
                                          uint32_t first_index, int32_t base_vertex,
                                          uint32_t first_instance) {
    if (pass)
        wgpuRenderPassEncoderDrawIndexed((WGPURenderPassEncoder)pass,
                                         index_count, instance_count, first_index,
                                         base_vertex, first_instance);
}

void wgpu_bridge_render_pass_draw_indirect(void* pass, void* buffer, uint64_t offset) {
    if (pass && buffer)
        wgpuRenderPassEncoderDrawIndirect((WGPURenderPassEncoder)pass, (WGPUBuffer)buffer, offset);
}

void wgpu_bridge_render_pass_draw_indexed_indirect(void* pass, void* buffer, uint64_t offset) {
    if (pass && buffer)
        wgpuRenderPassEncoderDrawIndexedIndirect((WGPURenderPassEncoder)pass, (WGPUBuffer)buffer, offset);
}

void wgpu_bridge_render_pass_set_bind_group(void* pass, uint32_t group_index, void* bind_group) {
    if (pass && bind_group)
        wgpuRenderPassEncoderSetBindGroup((WGPURenderPassEncoder)pass, group_index,
                                          (WGPUBindGroup)bind_group, 0, NULL);
}

void wgpu_bridge_render_pass_set_bind_group_dynamic(void* pass,
                                                    uint32_t group_index,
                                                    void* bind_group,
                                                    uint32_t dynamic_offset_count,
                                                    const uint32_t* dynamic_offsets) {
    if (pass && bind_group)
        wgpuRenderPassEncoderSetBindGroup((WGPURenderPassEncoder)pass, group_index,
                                          (WGPUBindGroup)bind_group,
                                          dynamic_offset_count, dynamic_offsets);
}

void wgpu_bridge_render_pass_end(void* pass) {
    if (pass) wgpuRenderPassEncoderEnd((WGPURenderPassEncoder)pass);
}

int wgpu_bridge_encoder_finish(void* encoder, void** out_command_buffer) {
    if (encoder == NULL || out_command_buffer == NULL) {
        set_error("invalid encoder_finish arguments");
        return 0;
    }
    WGPUCommandBufferDescriptor desc = WGPU_COMMAND_BUFFER_DESCRIPTOR_INIT;
    WGPUCommandBuffer cb = wgpuCommandEncoderFinish((WGPUCommandEncoder)encoder, &desc);
    if (cb == NULL) { set_error("wgpuCommandEncoderFinish returned null"); return 0; }
    *out_command_buffer = (void*)cb;
    return 1;
}

void wgpu_bridge_queue_submit(void* queue, void** command_buffers, uint32_t count) {
    if (queue && command_buffers && count > 0)
        wgpuQueueSubmit((WGPUQueue)queue, (size_t)count, (const WGPUCommandBuffer*)command_buffers);
}

void wgpu_bridge_release_command_buffer(void* cb) {
    if (cb) wgpuCommandBufferRelease((WGPUCommandBuffer)cb);
}
void wgpu_bridge_release_command_encoder(void* enc) {
    if (enc) wgpuCommandEncoderRelease((WGPUCommandEncoder)enc);
}
void wgpu_bridge_release_render_pass_encoder(void* pass) {
    if (pass) wgpuRenderPassEncoderRelease((WGPURenderPassEncoder)pass);
}

/* ════════════════════════════════════════════════════════════════════
   Viewport / Scissor
   ════════════════════════════════════════════════════════════════════ */

void wgpu_bridge_render_pass_set_viewport(void* pass,
                                          float x, float y, float w, float h,
                                          float min_depth, float max_depth) {
    if (pass)
        wgpuRenderPassEncoderSetViewport((WGPURenderPassEncoder)pass, x, y, w, h, min_depth, max_depth);
}

void wgpu_bridge_render_pass_set_scissor_rect(void* pass,
                                              uint32_t x, uint32_t y,
                                              uint32_t w, uint32_t h) {
    if (pass)
        wgpuRenderPassEncoderSetScissorRect((WGPURenderPassEncoder)pass, x, y, w, h);
}

/* ════════════════════════════════════════════════════════════════════
   Write Texture
   ════════════════════════════════════════════════════════════════════ */

void wgpu_bridge_write_texture(void* queue,
                               void* texture, uint32_t mip_level,
                               uint32_t origin_x,
                               uint32_t origin_y,
                               uint32_t origin_z,
                               const void* data, size_t data_size,
                               uint32_t bytes_per_row, uint32_t rows_per_image,
                               uint32_t width, uint32_t height, uint32_t depth_or_layers) {
    if (queue == NULL || texture == NULL || data == NULL) return;

    WGPUTexelCopyTextureInfo dst = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
    dst.texture = (WGPUTexture)texture;
    dst.mipLevel = mip_level;
    dst.aspect = WGPUTextureAspect_All;
    dst.origin.x = origin_x;
    dst.origin.y = origin_y;
    dst.origin.z = origin_z;

    WGPUTexelCopyBufferLayout layout = WGPU_TEXEL_COPY_BUFFER_LAYOUT_INIT;
    layout.bytesPerRow = bytes_per_row;
    layout.rowsPerImage = rows_per_image;

    WGPUExtent3D size = WGPU_EXTENT_3D_INIT;
    size.width = width;
    size.height = height;
    size.depthOrArrayLayers = depth_or_layers;

    wgpuQueueWriteTexture((WGPUQueue)queue, &dst, data, data_size, &layout, &size);
}

/* ════════════════════════════════════════════════════════════════════
   Sampler
   ════════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_sampler(void* device,
                               const WGPUBridgeSamplerDesc* desc,
                               void** out_sampler) {
    if (device == NULL || desc == NULL || out_sampler == NULL) {
        set_error("invalid create_sampler arguments");
        return 0;
    }
    WGPUSamplerDescriptor sd = WGPU_SAMPLER_DESCRIPTOR_INIT;
    sd.addressModeU = to_wgpu_address_mode(desc->address_mode_u);
    sd.addressModeV = to_wgpu_address_mode(desc->address_mode_v);
    sd.addressModeW = to_wgpu_address_mode(desc->address_mode_u);
    sd.magFilter = to_wgpu_filter(desc->mag_filter);
    sd.minFilter = to_wgpu_filter(desc->min_filter);
    sd.mipmapFilter = to_wgpu_mipmap_filter(desc->mipmap_filter);
    sd.lodMinClamp = 0.0f;
    sd.lodMaxClamp = 32.0f;
    sd.maxAnisotropy = 1;

    WGPUSampler s = wgpuDeviceCreateSampler((WGPUDevice)device, &sd);
    if (s == NULL) { set_error("wgpuDeviceCreateSampler returned null"); return 0; }
    *out_sampler = (void*)s;
    return 1;
}

void wgpu_bridge_release_sampler(void* sampler) {
    if (sampler) wgpuSamplerRelease((WGPUSampler)sampler);
}

/* ════════════════════════════════════════════════════════════════════
   Bind Group
   ════════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_bind_group_layout(void* device,
                                         const WGPUBridgeBindGroupLayoutEntry* entries,
                                         uint32_t entry_count,
                                         void** out_layout) {
    if (device == NULL || out_layout == NULL) {
        set_error("invalid create_bind_group_layout arguments");
        return 0;
    }
    WGPUBindGroupLayoutEntry* es = NULL;
    if (entry_count > 0 && entries != NULL) {
        es = (WGPUBindGroupLayoutEntry*)calloc(entry_count, sizeof(WGPUBindGroupLayoutEntry));
        for (uint32_t i = 0; i < entry_count; ++i) {
            es[i] = (WGPUBindGroupLayoutEntry)WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT;
            es[i].binding = entries[i].binding;
            es[i].visibility = to_wgpu_shader_stage(entries[i].visibility);
            switch (entries[i].type) {
                case WGPUBridge_BindingType_UniformBuffer:
                    es[i].buffer.type = WGPUBufferBindingType_Uniform;
                    es[i].buffer.hasDynamicOffset = entries[i].has_dynamic_offset
                        ? WGPU_TRUE : WGPU_FALSE;
                    break;
                case WGPUBridge_BindingType_StorageBuffer:
                    es[i].buffer.type = WGPUBufferBindingType_Storage;
                    es[i].buffer.hasDynamicOffset = entries[i].has_dynamic_offset
                        ? WGPU_TRUE : WGPU_FALSE;
                    break;
                case WGPUBridge_BindingType_ReadOnlyStorageBuffer:
                    es[i].buffer.type = WGPUBufferBindingType_ReadOnlyStorage;
                    es[i].buffer.hasDynamicOffset = entries[i].has_dynamic_offset
                        ? WGPU_TRUE : WGPU_FALSE;
                    break;
                case WGPUBridge_BindingType_Sampler:
                    es[i].sampler.type = WGPUSamplerBindingType_Filtering;
                    break;
                case WGPUBridge_BindingType_SampledTexture:
                    es[i].texture.sampleType = WGPUTextureSampleType_Float;
                    es[i].texture.viewDimension = WGPUTextureViewDimension_2D;
                    break;
            }
        }
    }
    WGPUBindGroupLayoutDescriptor desc = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
    desc.entryCount = entry_count;
    desc.entries = es;

    WGPUBindGroupLayout layout = wgpuDeviceCreateBindGroupLayout((WGPUDevice)device, &desc);
    free(es);
    if (layout == NULL) { set_error("wgpuDeviceCreateBindGroupLayout returned null"); return 0; }
    *out_layout = (void*)layout;
    return 1;
}

int wgpu_bridge_create_bind_group(void* device, void* layout,
                                  const WGPUBridgeBindGroupEntry* entries,
                                  uint32_t entry_count,
                                  void** out_bind_group) {
    if (device == NULL || layout == NULL || out_bind_group == NULL) {
        set_error("invalid create_bind_group arguments");
        return 0;
    }
    WGPUBindGroupEntry* es = NULL;
    if (entry_count > 0 && entries != NULL) {
        es = (WGPUBindGroupEntry*)calloc(entry_count, sizeof(WGPUBindGroupEntry));
        for (uint32_t i = 0; i < entry_count; ++i) {
            es[i] = (WGPUBindGroupEntry)WGPU_BIND_GROUP_ENTRY_INIT;
            es[i].binding = entries[i].binding;
            es[i].buffer = (WGPUBuffer)entries[i].buffer;
            es[i].offset = entries[i].offset;
            es[i].size = entries[i].size;
            es[i].sampler = (WGPUSampler)entries[i].sampler;
            es[i].textureView = (WGPUTextureView)entries[i].texture_view;
        }
    }
    WGPUBindGroupDescriptor desc = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
    desc.layout = (WGPUBindGroupLayout)layout;
    desc.entryCount = entry_count;
    desc.entries = es;

    WGPUBindGroup bg = wgpuDeviceCreateBindGroup((WGPUDevice)device, &desc);
    free(es);
    if (bg == NULL) { set_error("wgpuDeviceCreateBindGroup returned null"); return 0; }
    *out_bind_group = (void*)bg;
    return 1;
}

int wgpu_bridge_create_pipeline_layout(void* device,
                                       void* const* bind_group_layouts,
                                       uint32_t layout_count,
                                       void** out_layout) {
    if (device == NULL || out_layout == NULL) {
        set_error("invalid create_pipeline_layout arguments");
        return 0;
    }
    WGPUPipelineLayoutDescriptor desc = WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT;
    desc.bindGroupLayoutCount = layout_count;
    desc.bindGroupLayouts = (const WGPUBindGroupLayout*)bind_group_layouts;

    WGPUPipelineLayout pl = wgpuDeviceCreatePipelineLayout((WGPUDevice)device, &desc);
    if (pl == NULL) { set_error("wgpuDeviceCreatePipelineLayout returned null"); return 0; }
    *out_layout = (void*)pl;
    return 1;
}

void wgpu_bridge_release_bind_group_layout(void* layout) {
    if (layout) wgpuBindGroupLayoutRelease((WGPUBindGroupLayout)layout);
}
void wgpu_bridge_release_bind_group(void* bg) {
    if (bg) wgpuBindGroupRelease((WGPUBindGroup)bg);
}
void wgpu_bridge_release_pipeline_layout(void* layout) {
    if (layout) wgpuPipelineLayoutRelease((WGPUPipelineLayout)layout);
}

/* ════════════════════════════════════════════════════════════════════
   Compute Pipeline & Pass
   ════════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_compute_pipeline(void* device,
                                        void* shader_module,
                                        const char* entry_point,
                                        void* pipeline_layout,
                                        void** out_pipeline) {
    if (device == NULL || shader_module == NULL || out_pipeline == NULL) {
        set_error("invalid create_compute_pipeline arguments");
        return 0;
    }
    WGPUComputePipelineDescriptor desc = WGPU_COMPUTE_PIPELINE_DESCRIPTOR_INIT;
    desc.layout = (WGPUPipelineLayout)pipeline_layout;
    desc.compute.module = (WGPUShaderModule)shader_module;
    desc.compute.entryPoint = sv_from_cstr(entry_point);

    WGPUComputePipeline cp = wgpuDeviceCreateComputePipeline((WGPUDevice)device, &desc);
    if (cp == NULL) { set_error("wgpuDeviceCreateComputePipeline returned null"); return 0; }
    *out_pipeline = (void*)cp;
    return 1;
}

void wgpu_bridge_release_compute_pipeline(void* p) {
    if (p) wgpuComputePipelineRelease((WGPUComputePipeline)p);
}

int wgpu_bridge_begin_compute_pass(void* encoder, void** out_pass) {
    if (encoder == NULL || out_pass == NULL) {
        set_error("invalid begin_compute_pass arguments");
        return 0;
    }
    WGPUComputePassDescriptor desc = WGPU_COMPUTE_PASS_DESCRIPTOR_INIT;
    WGPUComputePassEncoder pass = wgpuCommandEncoderBeginComputePass((WGPUCommandEncoder)encoder, &desc);
    if (pass == NULL) { set_error("wgpuCommandEncoderBeginComputePass returned null"); return 0; }
    *out_pass = (void*)pass;
    return 1;
}

void wgpu_bridge_compute_pass_set_pipeline(void* pass, void* pipeline) {
    if (pass && pipeline)
        wgpuComputePassEncoderSetPipeline((WGPUComputePassEncoder)pass, (WGPUComputePipeline)pipeline);
}
void wgpu_bridge_compute_pass_set_bind_group(void* pass, uint32_t i, void* bg) {
    if (pass && bg)
        wgpuComputePassEncoderSetBindGroup((WGPUComputePassEncoder)pass, i, (WGPUBindGroup)bg, 0, NULL);
}
void wgpu_bridge_compute_pass_dispatch(void* pass, uint32_t x, uint32_t y, uint32_t z) {
    if (pass) wgpuComputePassEncoderDispatchWorkgroups((WGPUComputePassEncoder)pass, x, y, z);
}
void wgpu_bridge_compute_pass_dispatch_indirect(void* pass, void* buf, uint64_t off) {
    if (pass && buf)
        wgpuComputePassEncoderDispatchWorkgroupsIndirect((WGPUComputePassEncoder)pass, (WGPUBuffer)buf, off);
}
void wgpu_bridge_compute_pass_end(void* pass) {
    if (pass) wgpuComputePassEncoderEnd((WGPUComputePassEncoder)pass);
}
void wgpu_bridge_release_compute_pass_encoder(void* pass) {
    if (pass) wgpuComputePassEncoderRelease((WGPUComputePassEncoder)pass);
}

/* ════════════════════════════════════════════════════════════════════
   MRT Render Pass / Pipeline
   ════════════════════════════════════════════════════════════════════ */

int wgpu_bridge_begin_render_pass_mrt(void* encoder,
                                      const WGPUBridgeColorAttachment* color_attachments,
                                      uint32_t color_count,
                                      const WGPUBridgeDepthStencilAttachment* depth,
                                      void** out_pass) {
    if (encoder == NULL || out_pass == NULL) {
        set_error("invalid begin_render_pass_mrt arguments");
        return 0;
    }

    WGPURenderPassColorAttachment* cas = NULL;
    if (color_count > 0 && color_attachments != NULL) {
        cas = (WGPURenderPassColorAttachment*)calloc(color_count, sizeof(WGPURenderPassColorAttachment));
        for (uint32_t i = 0; i < color_count; ++i) {
            cas[i] = (WGPURenderPassColorAttachment)WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
            cas[i].view = (WGPUTextureView)color_attachments[i].view;
            cas[i].depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;
            cas[i].loadOp = to_wgpu_load_op(color_attachments[i].load_op);
            cas[i].storeOp = to_wgpu_store_op(color_attachments[i].store_op);
            cas[i].clearValue.r = color_attachments[i].clear_color.r;
            cas[i].clearValue.g = color_attachments[i].clear_color.g;
            cas[i].clearValue.b = color_attachments[i].clear_color.b;
            cas[i].clearValue.a = color_attachments[i].clear_color.a;
        }
    }

    WGPURenderPassDepthStencilAttachment dsa = WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
    WGPURenderPassDescriptor desc = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
    desc.colorAttachmentCount = color_count;
    desc.colorAttachments = cas;

    if (depth != NULL && depth->view != NULL) {
        dsa.view = (WGPUTextureView)depth->view;
        dsa.depthLoadOp = to_wgpu_load_op(depth->depth_load_op);
        dsa.depthStoreOp = to_wgpu_store_op(depth->depth_store_op);
        dsa.depthClearValue = depth->clear_depth;
        dsa.stencilLoadOp = to_wgpu_load_op(depth->stencil_load_op);
        dsa.stencilStoreOp = to_wgpu_store_op(depth->stencil_store_op);
        dsa.stencilClearValue = depth->stencil_clear_value;
        desc.depthStencilAttachment = &dsa;
    }

    WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass((WGPUCommandEncoder)encoder, &desc);
    free(cas);

    if (pass == NULL) { set_error("wgpuCommandEncoderBeginRenderPass (MRT) returned null"); return 0; }
    *out_pass = (void*)pass;
    return 1;
}

int wgpu_bridge_create_render_pipeline_mrt(
    void* device, void* shader_module,
    const char* vertex_entry, const char* fragment_entry,
    const WGPUBridgeTextureFormat* color_formats,
    const WGPUBridgeBlendState* blends,
    uint32_t color_format_count,
    WGPUBridgePrimitiveTopology topology,
    WGPUBridgeFrontFace front_face,
    WGPUBridgeCullMode cull_mode,
    const WGPUBridgeVertexBufferLayout* vertex_buffers,
    uint32_t vertex_buffer_count,
    const WGPUBridgeDepthStencilPipelineState* depth_stencil,
    uint32_t sample_count,
    void** out_pipeline)
{
    if (device == NULL || shader_module == NULL || out_pipeline == NULL || color_format_count == 0) {
        set_error("invalid create_render_pipeline_mrt arguments");
        return 0;
    }

    WGPUVertexBufferLayout* vb_layouts = NULL;
    WGPUVertexAttribute* all_attrs = NULL;
    if (vertex_buffer_count > 0 && vertex_buffers != NULL) {
        vb_layouts = (WGPUVertexBufferLayout*)calloc(vertex_buffer_count, sizeof(WGPUVertexBufferLayout));
        uint32_t total_attrs = 0;
        for (uint32_t i = 0; i < vertex_buffer_count; ++i) total_attrs += vertex_buffers[i].attribute_count;
        if (total_attrs > 0) all_attrs = (WGPUVertexAttribute*)calloc(total_attrs, sizeof(WGPUVertexAttribute));
        uint32_t off = 0;
        for (uint32_t i = 0; i < vertex_buffer_count; ++i) {
            vb_layouts[i] = (WGPUVertexBufferLayout)WGPU_VERTEX_BUFFER_LAYOUT_INIT;
            vb_layouts[i].arrayStride = vertex_buffers[i].array_stride;
            vb_layouts[i].stepMode = WGPUVertexStepMode_Vertex;
            vb_layouts[i].attributeCount = vertex_buffers[i].attribute_count;
            vb_layouts[i].attributes = vertex_buffers[i].attribute_count ? &all_attrs[off] : NULL;
            for (uint32_t j = 0; j < vertex_buffers[i].attribute_count; ++j) {
                all_attrs[off + j] = (WGPUVertexAttribute)WGPU_VERTEX_ATTRIBUTE_INIT;
                all_attrs[off + j].format = to_wgpu_vertex_format(vertex_buffers[i].attributes[j].format);
                all_attrs[off + j].offset = vertex_buffers[i].attributes[j].offset;
                all_attrs[off + j].shaderLocation = vertex_buffers[i].attributes[j].shader_location;
            }
            off += vertex_buffers[i].attribute_count;
        }
    }

    WGPUColorTargetState* targets = (WGPUColorTargetState*)calloc(color_format_count, sizeof(WGPUColorTargetState));
    WGPUBlendState* blend_states = blends ? (WGPUBlendState*)calloc(color_format_count, sizeof(WGPUBlendState)) : NULL;
    for (uint32_t i = 0; i < color_format_count; ++i) {
        targets[i] = (WGPUColorTargetState)WGPU_COLOR_TARGET_STATE_INIT;
        targets[i].format = to_wgpu_format(color_formats[i]);
        targets[i].writeMask = WGPUColorWriteMask_All;
        if (blends != NULL) {
            blend_states[i] = (WGPUBlendState)WGPU_BLEND_STATE_INIT;
            blend_states[i].color.operation = to_wgpu_blend_op(blends[i].color.operation);
            blend_states[i].color.srcFactor = to_wgpu_blend_factor(blends[i].color.src_factor);
            blend_states[i].color.dstFactor = to_wgpu_blend_factor(blends[i].color.dst_factor);
            blend_states[i].alpha.operation = to_wgpu_blend_op(blends[i].alpha.operation);
            blend_states[i].alpha.srcFactor = to_wgpu_blend_factor(blends[i].alpha.src_factor);
            blend_states[i].alpha.dstFactor = to_wgpu_blend_factor(blends[i].alpha.dst_factor);
            targets[i].blend = &blend_states[i];
        }
    }

    WGPUFragmentState frag = WGPU_FRAGMENT_STATE_INIT;
    frag.module = (WGPUShaderModule)shader_module;
    frag.entryPoint = sv_from_cstr(fragment_entry);
    frag.targetCount = color_format_count;
    frag.targets = targets;

    WGPURenderPipelineDescriptor desc = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
    desc.vertex.module = (WGPUShaderModule)shader_module;
    desc.vertex.entryPoint = sv_from_cstr(vertex_entry);
    desc.vertex.bufferCount = vertex_buffer_count;
    desc.vertex.buffers = vb_layouts;
    desc.primitive.topology = to_wgpu_topology(topology);
    desc.primitive.frontFace = to_wgpu_front_face(front_face);
    desc.primitive.cullMode = to_wgpu_cull_mode(cull_mode);
    desc.multisample.count = sample_count > 0 ? sample_count : 1;
    desc.multisample.mask = 0xFFFFFFFF;
    desc.fragment = &frag;
    desc.layout = NULL;

    WGPUDepthStencilState ds;
    if (depth_stencil != NULL) {
        fill_depth_stencil_state(&ds, depth_stencil);
        desc.depthStencil = &ds;
    }

    WGPURenderPipeline pipeline = wgpuDeviceCreateRenderPipeline((WGPUDevice)device, &desc);

    free(blend_states);
    free(targets);
    free(all_attrs);
    free(vb_layouts);

    if (pipeline == NULL) { set_error("wgpuDeviceCreateRenderPipeline (MRT) returned null"); return 0; }
    *out_pipeline = (void*)pipeline;
    return 1;
}

/* ════════════════════════════════════════════════════════════════════
   Texture Copy
   ════════════════════════════════════════════════════════════════════ */

void wgpu_bridge_copy_texture_to_texture(void* encoder,
                                         void* src_texture, uint32_t src_mip,
                                         void* dst_texture, uint32_t dst_mip,
                                         uint32_t width, uint32_t height,
                                         uint32_t depth_or_layers) {
    if (encoder == NULL || src_texture == NULL || dst_texture == NULL) return;

    WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
    src.texture = (WGPUTexture)src_texture;
    src.mipLevel = src_mip;
    src.aspect = WGPUTextureAspect_All;

    WGPUTexelCopyTextureInfo dst = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
    dst.texture = (WGPUTexture)dst_texture;
    dst.mipLevel = dst_mip;
    dst.aspect = WGPUTextureAspect_All;

    WGPUExtent3D size = WGPU_EXTENT_3D_INIT;
    size.width = width;
    size.height = height;
    size.depthOrArrayLayers = depth_or_layers;

    wgpuCommandEncoderCopyTextureToTexture((WGPUCommandEncoder)encoder, &src, &dst, &size);
}

void wgpu_bridge_copy_texture_to_buffer(void* encoder,
                                        void* texture, uint32_t mip_level,
                                        void* buffer, uint64_t buffer_offset,
                                        uint32_t bytes_per_row, uint32_t rows_per_image,
                                        uint32_t width, uint32_t height, uint32_t depth_or_layers) {
    if (encoder == NULL || texture == NULL || buffer == NULL) return;

    WGPUTexelCopyTextureInfo src = WGPU_TEXEL_COPY_TEXTURE_INFO_INIT;
    src.texture = (WGPUTexture)texture;
    src.mipLevel = mip_level;
    src.aspect = WGPUTextureAspect_All;

    WGPUTexelCopyBufferInfo dst = WGPU_TEXEL_COPY_BUFFER_INFO_INIT;
    dst.buffer = (WGPUBuffer)buffer;
    dst.layout.offset = buffer_offset;
    dst.layout.bytesPerRow = bytes_per_row;
    dst.layout.rowsPerImage = rows_per_image;

    WGPUExtent3D size = WGPU_EXTENT_3D_INIT;
    size.width = width;
    size.height = height;
    size.depthOrArrayLayers = depth_or_layers;

    wgpuCommandEncoderCopyTextureToBuffer((WGPUCommandEncoder)encoder, &src, &dst, &size);
}

/* ════════════════════════════════════════════════════════════════════
   Buffer Map (sync via device polling)
   ════════════════════════════════════════════════════════════════════ */

typedef struct {
    int done;
    WGPUMapAsyncStatus status;
} MapAwait;

static void on_buffer_map(WGPUMapAsyncStatus status, WGPUStringView msg,
                          void* userdata1, void* userdata2) {
    (void)msg; (void)userdata2;
    MapAwait* a = (MapAwait*)userdata1;
    a->status = status;
    a->done = 1;
}

int wgpu_bridge_buffer_map_sync(void* device, void* buffer,
                                uint64_t offset, uint64_t size) {
    if (device == NULL || buffer == NULL) {
        set_error("invalid buffer_map_sync arguments");
        return 0;
    }
    MapAwait a = {0};
    WGPUBufferMapCallbackInfo cb = WGPU_BUFFER_MAP_CALLBACK_INFO_INIT;
    cb.mode = WGPUCallbackMode_AllowProcessEvents;
    cb.callback = on_buffer_map;
    cb.userdata1 = &a;

    wgpuBufferMapAsync((WGPUBuffer)buffer, WGPUMapMode_Read, offset, size, cb);

    /* Drive completion via device poll. */
    for (int i = 0; i < 10000 && !a.done; ++i) {
        wgpuDevicePoll((WGPUDevice)device, WGPU_TRUE, NULL);
    }

    if (!a.done || a.status != WGPUMapAsyncStatus_Success) {
        set_error("wgpuBufferMapAsync failed");
        return 0;
    }
    return 1;
}

const void* wgpu_bridge_buffer_get_mapped_range(void* buffer,
                                                uint64_t offset, uint64_t size) {
    if (buffer == NULL) return NULL;
    return wgpuBufferGetConstMappedRange((WGPUBuffer)buffer, offset, size);
}

void wgpu_bridge_buffer_unmap(void* buffer) {
    if (buffer) wgpuBufferUnmap((WGPUBuffer)buffer);
}

/* ════════════════════════════════════════════════════════════════════
   Render Bundles
   ════════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_render_bundle_encoder(void* device,
                                             const WGPUBridgeRenderBundleEncoderDesc* desc,
                                             void** out_encoder) {
    if (device == NULL || desc == NULL || out_encoder == NULL) {
        set_error("invalid create_render_bundle_encoder arguments");
        return 0;
    }
    if (desc->color_format_count > 8) { set_error("too many color formats"); return 0; }

    WGPUTextureFormat formats[8] = {0};
    for (uint32_t i = 0; i < desc->color_format_count; ++i) {
        formats[i] = to_wgpu_format(desc->color_formats[i]);
    }

    WGPURenderBundleEncoderDescriptor d = WGPU_RENDER_BUNDLE_ENCODER_DESCRIPTOR_INIT;
    d.colorFormatCount = desc->color_format_count;
    d.colorFormats = desc->color_format_count ? formats : NULL;
    d.depthStencilFormat = desc->has_depth_stencil
        ? to_wgpu_format(desc->depth_stencil_format)
        : WGPUTextureFormat_Undefined;
    d.sampleCount = desc->sample_count == 0 ? 1 : desc->sample_count;
    d.depthReadOnly = desc->depth_read_only ? WGPU_TRUE : WGPU_FALSE;
    d.stencilReadOnly = desc->stencil_read_only ? WGPU_TRUE : WGPU_FALSE;

    WGPURenderBundleEncoder e = wgpuDeviceCreateRenderBundleEncoder((WGPUDevice)device, &d);
    if (e == NULL) { set_error("wgpuDeviceCreateRenderBundleEncoder returned null"); return 0; }
    *out_encoder = (void*)e;
    return 1;
}

int wgpu_bridge_render_bundle_encoder_finish(void* encoder, void** out_bundle) {
    if (encoder == NULL || out_bundle == NULL) {
        set_error("invalid render_bundle_encoder_finish arguments");
        return 0;
    }
    WGPURenderBundleDescriptor d = WGPU_RENDER_BUNDLE_DESCRIPTOR_INIT;
    WGPURenderBundle b = wgpuRenderBundleEncoderFinish((WGPURenderBundleEncoder)encoder, &d);
    if (b == NULL) { set_error("wgpuRenderBundleEncoderFinish returned null"); return 0; }
    *out_bundle = (void*)b;
    return 1;
}

void wgpu_bridge_release_render_bundle_encoder(void* enc) {
    if (enc) wgpuRenderBundleEncoderRelease((WGPURenderBundleEncoder)enc);
}
void wgpu_bridge_release_render_bundle(void* b) {
    if (b) wgpuRenderBundleRelease((WGPURenderBundle)b);
}

void wgpu_bridge_render_bundle_set_pipeline(void* enc, void* pipeline) {
    if (enc && pipeline)
        wgpuRenderBundleEncoderSetPipeline((WGPURenderBundleEncoder)enc, (WGPURenderPipeline)pipeline);
}
void wgpu_bridge_render_bundle_set_vertex_buffer(void* enc, uint32_t slot,
                                                 void* buffer, uint64_t offset, uint64_t size) {
    if (enc)
        wgpuRenderBundleEncoderSetVertexBuffer((WGPURenderBundleEncoder)enc, slot,
                                               (WGPUBuffer)buffer, offset, size);
}
void wgpu_bridge_render_bundle_set_index_buffer(void* enc, void* buffer,
                                                WGPUBridgeIndexFormat fmt,
                                                uint64_t offset, uint64_t size) {
    if (enc && buffer)
        wgpuRenderBundleEncoderSetIndexBuffer((WGPURenderBundleEncoder)enc, (WGPUBuffer)buffer,
                                              to_wgpu_index_format(fmt), offset, size);
}
void wgpu_bridge_render_bundle_set_bind_group(void* enc, uint32_t i, void* bg) {
    if (enc && bg)
        wgpuRenderBundleEncoderSetBindGroup((WGPURenderBundleEncoder)enc, i, (WGPUBindGroup)bg, 0, NULL);
}
void wgpu_bridge_render_bundle_set_bind_group_dynamic(void* enc,
                                                      uint32_t i,
                                                      void* bg,
                                                      uint32_t dynamic_offset_count,
                                                      const uint32_t* dynamic_offsets) {
    if (!(enc && bg)) return;
    wgpuRenderBundleEncoderSetBindGroup((WGPURenderBundleEncoder)enc,
                                        i,
                                        (WGPUBindGroup)bg,
                                        dynamic_offset_count,
                                        dynamic_offsets);
}
void wgpu_bridge_render_bundle_draw(void* enc, uint32_t vc, uint32_t ic, uint32_t fv, uint32_t fi) {
    if (enc) wgpuRenderBundleEncoderDraw((WGPURenderBundleEncoder)enc, vc, ic, fv, fi);
}
void wgpu_bridge_render_bundle_draw_indexed(void* enc, uint32_t ic, uint32_t inst,
                                            uint32_t fi, int32_t bv, uint32_t finst) {
    if (enc) wgpuRenderBundleEncoderDrawIndexed((WGPURenderBundleEncoder)enc, ic, inst, fi, bv, finst);
}
void wgpu_bridge_render_bundle_draw_indirect(void* enc, void* buffer, uint64_t offset) {
    if (enc && buffer)
        wgpuRenderBundleEncoderDrawIndirect((WGPURenderBundleEncoder)enc, (WGPUBuffer)buffer, offset);
}
void wgpu_bridge_render_bundle_draw_indexed_indirect(void* enc, void* buffer, uint64_t offset) {
    if (enc && buffer)
        wgpuRenderBundleEncoderDrawIndexedIndirect((WGPURenderBundleEncoder)enc, (WGPUBuffer)buffer, offset);
}
void wgpu_bridge_render_pass_execute_bundles(void* pass,
                                             void* const* bundles, uint32_t count) {
    if (pass && bundles && count > 0)
        wgpuRenderPassEncoderExecuteBundles((WGPURenderPassEncoder)pass, count,
                                            (const WGPURenderBundle*)bundles);
}
