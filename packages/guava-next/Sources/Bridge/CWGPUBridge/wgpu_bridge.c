#include "wgpu_bridge.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ═══════════════════════════════════════════════════════════════════
   Internal wgpu types — must match the ABI of wgpu-native v22.x.
   ═══════════════════════════════════════════════════════════════════ */

typedef enum WGPURequestAdapterStatus {
    WGPURequestAdapterStatus_Success = 0,
    WGPURequestAdapterStatus_Unavailable = 1,
    WGPURequestAdapterStatus_Error = 2,
    WGPURequestAdapterStatus_Unknown = 3,
} WGPURequestAdapterStatus;

typedef enum WGPURequestDeviceStatus {
    WGPURequestDeviceStatus_Success = 0,
    WGPURequestDeviceStatus_Error = 1,
    WGPURequestDeviceStatus_Unknown = 2,
} WGPURequestDeviceStatus;

typedef struct WGPUChainedStruct {
    struct WGPUChainedStruct const* next;
    uint32_t sType;
} WGPUChainedStruct;

/* sType constants (webgpu.h v22) */
#define WGPU_STYPE_SURFACE_FROM_METAL_LAYER  0x00000004
#define WGPU_STYPE_SURFACE_FROM_WINDOWS_HWND 0x00000005
#define WGPU_STYPE_SURFACE_FROM_XLIB_WINDOW  0x00000006
#define WGPU_STYPE_SHADER_SOURCE_WGSL        0x00000005

/* ─── Adapter / Device request ──────────────────────────────────── */

typedef struct WGPURequestAdapterOptions {
    const void* nextInChain;
    void* compatibleSurface;
    int powerPreference;
    int forceFallbackAdapter;
} WGPURequestAdapterOptions;

typedef struct WGPUDeviceDescriptor {
    const void* nextInChain;
    const char* label;
} WGPUDeviceDescriptor;

typedef void (*WGPURequestAdapterCallback)(WGPURequestAdapterStatus status, WGPUAdapter adapter, const char* message, void* userdata);
typedef void (*WGPURequestDeviceCallback)(WGPURequestDeviceStatus status, WGPUDevice device, const char* message, void* userdata);

/* ─── Surface types ─────────────────────────────────────────────── */

typedef struct WGPUSurfaceImpl* WGPUSurface_T;
typedef struct WGPUTextureImpl* WGPUTexture_T;
typedef struct WGPUTextureViewImpl* WGPUTextureView_T;
typedef struct WGPUShaderModuleImpl* WGPUShaderModule_T;
typedef struct WGPURenderPipelineImpl* WGPURenderPipeline_T;
typedef struct WGPUPipelineLayoutImpl* WGPUPipelineLayout_T;
typedef struct WGPUBufferImpl* WGPUBuffer_T;
typedef struct WGPUCommandEncoderImpl* WGPUCommandEncoder_T;
typedef struct WGPUCommandBufferImpl* WGPUCommandBuffer_T;
typedef struct WGPURenderPassEncoderImpl* WGPURenderPassEncoder_T;

typedef struct {
    WGPUChainedStruct chain;
    void* layer;
} WGPUSurfaceSourceMetalLayer;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    const char* label;
} WGPUSurfaceDescriptor;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    WGPUDevice device;
    uint32_t format;
    uint32_t usage;
    size_t viewFormatCount;
    const uint32_t* viewFormats;
    uint32_t alphaMode;
    uint32_t width;
    uint32_t height;
    uint32_t presentMode;
} WGPUSurfaceConfiguration;

typedef struct {
    WGPUTexture_T texture;
    uint32_t suboptimal;
    uint32_t status;
} WGPUSurfaceTexture;

/* ─── Shader types ──────────────────────────────────────────────── */

typedef struct {
    WGPUChainedStruct chain;
    const char* code;
} WGPUShaderSourceWGSL;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    const char* label;
} WGPUShaderModuleDescriptor;

/* ─── Texture types ─────────────────────────────────────────────── */

typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t depthOrArrayLayers;
} WGPUExtent3D;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    const char* label;
    uint32_t usage;
    uint32_t dimension;
    WGPUExtent3D size;
    uint32_t format;
    uint32_t mipLevelCount;
    uint32_t sampleCount;
    size_t viewFormatCount;
    const uint32_t* viewFormats;
} WGPUTextureDescriptor_I;

/* ─── Buffer types ──────────────────────────────────────────────── */

typedef struct {
    const WGPUChainedStruct* nextInChain;
    const char* label;
    uint32_t usage;
    uint64_t size;
    uint32_t mappedAtCreation;
} WGPUBufferDescriptor_I;

/* ─── Pipeline types ────────────────────────────────────────────── */

typedef struct {
    uint32_t format;
    uint64_t offset;
    uint32_t shaderLocation;
} WGPUVertexAttribute_I;

typedef struct {
    uint64_t arrayStride;
    uint32_t stepMode;
    size_t attributeCount;
    const WGPUVertexAttribute_I* attributes;
} WGPUVertexBufferLayout_I;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    WGPUShaderModule_T module;
    const char* entryPoint;
    size_t constantCount;
    const void* constants;
    size_t bufferCount;
    const WGPUVertexBufferLayout_I* buffers;
} WGPUVertexState_I;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    uint32_t format;
    uint32_t writeMask;
    const void* blend;
} WGPUColorTargetState_I;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    WGPUShaderModule_T module;
    const char* entryPoint;
    size_t constantCount;
    const void* constants;
    size_t targetCount;
    const WGPUColorTargetState_I* targets;
} WGPUFragmentState_I;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    uint32_t topology;
    uint32_t stripIndexFormat;
} WGPUPrimitiveState_I;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    uint32_t count;
    uint32_t mask;
    uint32_t alphaToCoverageEnabled;
} WGPUMultisampleState_I;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    const char* label;
    size_t bindGroupLayoutCount;
    const void* const* bindGroupLayouts;
} WGPUPipelineLayoutDescriptor_I;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    const char* label;
    WGPUPipelineLayout_T layout;
    WGPUVertexState_I vertex;
    WGPUPrimitiveState_I primitive;
    const void* depthStencil;
    WGPUMultisampleState_I multisample;
    const WGPUFragmentState_I* fragment;
} WGPURenderPipelineDescriptor_I;

/* ─── Command / RenderPass types ────────────────────────────────── */

typedef struct {
    const WGPUChainedStruct* nextInChain;
    const char* label;
} WGPUCommandEncoderDescriptor_I;

typedef struct {
    double r, g, b, a;
} WGPUColor_I;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    WGPUTextureView_T view;
    uint32_t depthSlice;
    WGPUTextureView_T resolveTarget;
    uint32_t loadOp;
    uint32_t storeOp;
    WGPUColor_I clearValue;
} WGPURenderPassColorAttachment_I;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    const char* label;
    size_t colorAttachmentCount;
    const WGPURenderPassColorAttachment_I* colorAttachments;
    const void* depthStencilAttachment;
    const void* occlusionQuerySet;
    const void* timestampWrites;
} WGPURenderPassDescriptor_I;

typedef struct {
    const WGPUChainedStruct* nextInChain;
    const char* label;
} WGPUCommandBufferDescriptor_I;

/* ═══════════════════════════════════════════════════════════════════
   Function pointer typedefs
   ═══════════════════════════════════════════════════════════════════ */

/* Existing */
typedef WGPUInstance (*PFN_wgpuCreateInstance)(const WGPUInstanceDescriptor*);
typedef void (*PFN_wgpuInstanceRelease)(WGPUInstance);
typedef void (*PFN_wgpuInstanceRequestAdapter)(WGPUInstance, const WGPURequestAdapterOptions*, WGPURequestAdapterCallback, void*);
typedef void (*PFN_wgpuAdapterRequestDevice)(WGPUAdapter, const WGPUDeviceDescriptor*, WGPURequestDeviceCallback, void*);
typedef void (*PFN_wgpuAdapterRelease)(WGPUAdapter);
typedef void (*PFN_wgpuDeviceRelease)(WGPUDevice);
typedef WGPUQueue (*PFN_wgpuDeviceGetQueue)(WGPUDevice);
typedef void (*PFN_wgpuQueueRelease)(WGPUQueue);

/* Surface */
typedef WGPUSurface_T (*PFN_wgpuInstanceCreateSurface)(WGPUInstance, const WGPUSurfaceDescriptor*);
typedef void (*PFN_wgpuSurfaceConfigure)(WGPUSurface_T, const WGPUSurfaceConfiguration*);
typedef void (*PFN_wgpuSurfaceGetCurrentTexture)(WGPUSurface_T, WGPUSurfaceTexture*);
typedef void (*PFN_wgpuSurfacePresent)(WGPUSurface_T);
typedef void (*PFN_wgpuSurfaceUnconfigure)(WGPUSurface_T);
typedef void (*PFN_wgpuSurfaceRelease)(WGPUSurface_T);

/* Texture */
typedef WGPUTexture_T (*PFN_wgpuDeviceCreateTexture)(WGPUDevice, const WGPUTextureDescriptor_I*);
typedef WGPUTextureView_T (*PFN_wgpuTextureCreateView)(WGPUTexture_T, const void*);
typedef void (*PFN_wgpuTextureRelease)(WGPUTexture_T);
typedef void (*PFN_wgpuTextureViewRelease)(WGPUTextureView_T);

/* Shader */
typedef WGPUShaderModule_T (*PFN_wgpuDeviceCreateShaderModule)(WGPUDevice, const WGPUShaderModuleDescriptor*);
typedef void (*PFN_wgpuShaderModuleRelease)(WGPUShaderModule_T);

/* Pipeline */
typedef WGPURenderPipeline_T (*PFN_wgpuDeviceCreateRenderPipeline)(WGPUDevice, const WGPURenderPipelineDescriptor_I*);
typedef void (*PFN_wgpuRenderPipelineRelease)(WGPURenderPipeline_T);
typedef WGPUPipelineLayout_T (*PFN_wgpuDeviceCreatePipelineLayout)(WGPUDevice, const WGPUPipelineLayoutDescriptor_I*);
typedef void (*PFN_wgpuPipelineLayoutRelease)(WGPUPipelineLayout_T);

/* Buffer */
typedef WGPUBuffer_T (*PFN_wgpuDeviceCreateBuffer)(WGPUDevice, const WGPUBufferDescriptor_I*);
typedef void (*PFN_wgpuQueueWriteBuffer)(WGPUQueue, WGPUBuffer_T, uint64_t, const void*, size_t);
typedef void (*PFN_wgpuBufferRelease)(WGPUBuffer_T);

/* Command encoder */
typedef WGPUCommandEncoder_T (*PFN_wgpuDeviceCreateCommandEncoder)(WGPUDevice, const WGPUCommandEncoderDescriptor_I*);
typedef WGPURenderPassEncoder_T (*PFN_wgpuCommandEncoderBeginRenderPass)(WGPUCommandEncoder_T, const WGPURenderPassDescriptor_I*);
typedef WGPUCommandBuffer_T (*PFN_wgpuCommandEncoderFinish)(WGPUCommandEncoder_T, const WGPUCommandBufferDescriptor_I*);
typedef void (*PFN_wgpuCommandEncoderRelease)(WGPUCommandEncoder_T);

/* Render pass encoder */
typedef void (*PFN_wgpuRenderPassEncoderSetPipeline)(WGPURenderPassEncoder_T, WGPURenderPipeline_T);
typedef void (*PFN_wgpuRenderPassEncoderSetVertexBuffer)(WGPURenderPassEncoder_T, uint32_t, WGPUBuffer_T, uint64_t, uint64_t);
typedef void (*PFN_wgpuRenderPassEncoderDraw)(WGPURenderPassEncoder_T, uint32_t, uint32_t, uint32_t, uint32_t);
typedef void (*PFN_wgpuRenderPassEncoderEnd)(WGPURenderPassEncoder_T);
typedef void (*PFN_wgpuRenderPassEncoderRelease)(WGPURenderPassEncoder_T);

/* Queue submit */
typedef void (*PFN_wgpuQueueSubmit)(WGPUQueue, size_t, const WGPUCommandBuffer_T*);
typedef void (*PFN_wgpuCommandBufferRelease)(WGPUCommandBuffer_T);

/* ═══════════════════════════════════════════════════════════════════
   Globals
   ═══════════════════════════════════════════════════════════════════ */

static void* g_wgpu_lib = NULL;
static char g_last_error[256] = {0};

/* Existing function pointers */
static PFN_wgpuCreateInstance           g_create_instance = NULL;
static PFN_wgpuInstanceRelease          g_release_instance = NULL;
static PFN_wgpuInstanceRequestAdapter   g_request_adapter = NULL;
static PFN_wgpuAdapterRequestDevice     g_request_device = NULL;
static PFN_wgpuAdapterRelease           g_release_adapter = NULL;
static PFN_wgpuDeviceRelease            g_release_device = NULL;
static PFN_wgpuDeviceGetQueue           g_get_queue = NULL;
static PFN_wgpuQueueRelease             g_release_queue = NULL;

/* Surface */
static PFN_wgpuInstanceCreateSurface       g_create_surface = NULL;
static PFN_wgpuSurfaceConfigure            g_configure_surface = NULL;
static PFN_wgpuSurfaceGetCurrentTexture    g_surface_get_texture = NULL;
static PFN_wgpuSurfacePresent              g_surface_present = NULL;
static PFN_wgpuSurfaceUnconfigure          g_surface_unconfigure = NULL;
static PFN_wgpuSurfaceRelease              g_surface_release = NULL;

/* Texture */
static PFN_wgpuDeviceCreateTexture    g_create_texture = NULL;
static PFN_wgpuTextureCreateView      g_texture_create_view = NULL;
static PFN_wgpuTextureRelease         g_texture_release = NULL;
static PFN_wgpuTextureViewRelease     g_texture_view_release = NULL;

/* Shader */
static PFN_wgpuDeviceCreateShaderModule g_create_shader_module = NULL;
static PFN_wgpuShaderModuleRelease      g_shader_module_release = NULL;

/* Pipeline */
static PFN_wgpuDeviceCreateRenderPipeline  g_create_render_pipeline = NULL;
static PFN_wgpuRenderPipelineRelease       g_render_pipeline_release = NULL;
static PFN_wgpuDeviceCreatePipelineLayout  g_create_pipeline_layout = NULL;
static PFN_wgpuPipelineLayoutRelease       g_pipeline_layout_release = NULL;

/* Buffer */
static PFN_wgpuDeviceCreateBuffer  g_create_buffer = NULL;
static PFN_wgpuQueueWriteBuffer    g_queue_write_buffer = NULL;
static PFN_wgpuBufferRelease       g_buffer_release = NULL;

/* Command encoder */
static PFN_wgpuDeviceCreateCommandEncoder       g_create_command_encoder = NULL;
static PFN_wgpuCommandEncoderBeginRenderPass    g_begin_render_pass = NULL;
static PFN_wgpuCommandEncoderFinish             g_encoder_finish = NULL;
static PFN_wgpuCommandEncoderRelease            g_command_encoder_release = NULL;

/* Render pass encoder */
static PFN_wgpuRenderPassEncoderSetPipeline      g_rp_set_pipeline = NULL;
static PFN_wgpuRenderPassEncoderSetVertexBuffer  g_rp_set_vertex_buffer = NULL;
static PFN_wgpuRenderPassEncoderDraw             g_rp_draw = NULL;
static PFN_wgpuRenderPassEncoderEnd              g_rp_end = NULL;
static PFN_wgpuRenderPassEncoderRelease          g_rp_release = NULL;

/* Queue submit */
static PFN_wgpuQueueSubmit        g_queue_submit = NULL;
static PFN_wgpuCommandBufferRelease g_command_buffer_release = NULL;

/* ═══════════════════════════════════════════════════════════════════
   Helpers
   ═══════════════════════════════════════════════════════════════════ */

typedef struct AwaitResult {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    int done;
    int success;
    void* object;
    char message[128];
} AwaitResult;

static void set_error(const char* msg) {
    if (msg == NULL) {
        g_last_error[0] = '\0';
        return;
    }
    strncpy(g_last_error, msg, sizeof(g_last_error) - 1);
    g_last_error[sizeof(g_last_error) - 1] = '\0';
}

static void await_init(AwaitResult* ar) {
    pthread_mutex_init(&ar->mutex, NULL);
    pthread_cond_init(&ar->cond, NULL);
    ar->done = 0;
    ar->success = 0;
    ar->object = NULL;
    ar->message[0] = '\0';
}

static void await_deinit(AwaitResult* ar) {
    pthread_cond_destroy(&ar->cond);
    pthread_mutex_destroy(&ar->mutex);
}

static void await_finish(AwaitResult* ar, int success, void* object, const char* message) {
    pthread_mutex_lock(&ar->mutex);
    ar->done = 1;
    ar->success = success;
    ar->object = object;
    if (message != NULL) {
        strncpy(ar->message, message, sizeof(ar->message) - 1);
        ar->message[sizeof(ar->message) - 1] = '\0';
    }
    pthread_cond_signal(&ar->cond);
    pthread_mutex_unlock(&ar->mutex);
}

static void await_wait(AwaitResult* ar) {
    pthread_mutex_lock(&ar->mutex);
    while (!ar->done) {
        pthread_cond_wait(&ar->cond, &ar->mutex);
    }
    pthread_mutex_unlock(&ar->mutex);
}

static void adapter_callback(WGPURequestAdapterStatus status, WGPUAdapter adapter, const char* message, void* userdata) {
    AwaitResult* ar = (AwaitResult*)userdata;
    const int ok = (status == WGPURequestAdapterStatus_Success && adapter != NULL) ? 1 : 0;
    await_finish(ar, ok, (void*)adapter, message);
}

static void device_callback(WGPURequestDeviceStatus status, WGPUDevice device, const char* message, void* userdata) {
    AwaitResult* ar = (AwaitResult*)userdata;
    const int ok = (status == WGPURequestDeviceStatus_Success && device != NULL) ? 1 : 0;
    await_finish(ar, ok, (void*)device, message);
}

/* ─── Bridge enum → wgpu enum mapping ───────────────────────────── */

static uint32_t bridge_format_to_wgpu(WGPUBridgeTextureFormat f) {
    switch (f) {
        case WGPUBridge_TextureFormat_BGRA8Unorm:    return 0x17; /* 23 */
        case WGPUBridge_TextureFormat_RGBA8Unorm:    return 0x12; /* 18 */
        case WGPUBridge_TextureFormat_RGBA16Float:   return 0x1E; /* 30 */
        case WGPUBridge_TextureFormat_Depth24Plus:   return 0x28; /* 40 */
        case WGPUBridge_TextureFormat_Depth32Float:  return 0x29; /* 41 */
        default:                                     return 0x17;
    }
}

static uint32_t bridge_present_mode_to_wgpu(WGPUBridgePresentMode m) {
    switch (m) {
        case WGPUBridge_PresentMode_Fifo:        return 2;
        case WGPUBridge_PresentMode_FifoRelaxed: return 3;
        case WGPUBridge_PresentMode_Immediate:   return 0;
        case WGPUBridge_PresentMode_Mailbox:     return 1;
        default:                                 return 2;
    }
}

static uint32_t bridge_load_op_to_wgpu(WGPUBridgeLoadOp op) {
    switch (op) {
        case WGPUBridge_LoadOp_Clear: return 1;
        case WGPUBridge_LoadOp_Load:  return 2;
        default:                      return 1;
    }
}

static uint32_t bridge_store_op_to_wgpu(WGPUBridgeStoreOp op) {
    switch (op) {
        case WGPUBridge_StoreOp_Store:   return 1;
        case WGPUBridge_StoreOp_Discard: return 2;
        default:                         return 1;
    }
}

static uint32_t bridge_topology_to_wgpu(WGPUBridgePrimitiveTopology t) {
    switch (t) {
        case WGPUBridge_PrimitiveTopology_PointList:     return 0;
        case WGPUBridge_PrimitiveTopology_LineList:      return 1;
        case WGPUBridge_PrimitiveTopology_LineStrip:     return 2;
        case WGPUBridge_PrimitiveTopology_TriangleList:  return 3;
        case WGPUBridge_PrimitiveTopology_TriangleStrip: return 4;
        default:                                         return 3;
    }
}

static uint32_t bridge_vertex_format_to_wgpu(WGPUBridgeVertexFormat f) {
    switch (f) {
        case WGPUBridge_VertexFormat_Float32:   return 0x11; /* 17 */
        case WGPUBridge_VertexFormat_Float32x2: return 0x12; /* 18 */
        case WGPUBridge_VertexFormat_Float32x3: return 0x13; /* 19 */
        case WGPUBridge_VertexFormat_Float32x4: return 0x14; /* 20 */
        case WGPUBridge_VertexFormat_Uint32:    return 0x09; /* 9  */
        default:                                return 0x13;
    }
}

static uint32_t bridge_cull_mode_to_wgpu(WGPUBridgeCullMode m) {
    switch (m) {
        case WGPUBridge_CullMode_None:  return 0;
        case WGPUBridge_CullMode_Front: return 1;
        case WGPUBridge_CullMode_Back:  return 2;
        default:                        return 0;
    }
}

/* ═══════════════════════════════════════════════════════════════════
   Public API — Initialization
   ═══════════════════════════════════════════════════════════════════ */

const char* wgpu_bridge_last_error(void) {
    return g_last_error;
}

#define LOAD_SYM(name, type, var) do { \
    var = (type)dlsym(g_wgpu_lib, #name); \
} while(0)

int wgpu_bridge_initialize(const char* library_path) {
    if (g_wgpu_lib != NULL) {
        return 1;
    }

    const char* path = library_path;
    if (path == NULL || path[0] == '\0') {
#if defined(__APPLE__)
        path = "libwgpu_native.dylib";
#elif defined(_WIN32)
        path = "wgpu_native.dll";
#else
        path = "libwgpu_native.so";
#endif
    }

    g_wgpu_lib = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (g_wgpu_lib == NULL) {
        set_error(dlerror());
        return 0;
    }

    /* Core */
    LOAD_SYM(wgpuCreateInstance,          PFN_wgpuCreateInstance,          g_create_instance);
    LOAD_SYM(wgpuInstanceRelease,         PFN_wgpuInstanceRelease,         g_release_instance);
    LOAD_SYM(wgpuInstanceRequestAdapter,  PFN_wgpuInstanceRequestAdapter,  g_request_adapter);
    LOAD_SYM(wgpuAdapterRequestDevice,    PFN_wgpuAdapterRequestDevice,    g_request_device);
    LOAD_SYM(wgpuAdapterRelease,          PFN_wgpuAdapterRelease,          g_release_adapter);
    LOAD_SYM(wgpuDeviceRelease,           PFN_wgpuDeviceRelease,           g_release_device);
    LOAD_SYM(wgpuDeviceGetQueue,          PFN_wgpuDeviceGetQueue,          g_get_queue);
    LOAD_SYM(wgpuQueueRelease,            PFN_wgpuQueueRelease,            g_release_queue);

    /* Surface */
    LOAD_SYM(wgpuInstanceCreateSurface,       PFN_wgpuInstanceCreateSurface,      g_create_surface);
    LOAD_SYM(wgpuSurfaceConfigure,            PFN_wgpuSurfaceConfigure,           g_configure_surface);
    LOAD_SYM(wgpuSurfaceGetCurrentTexture,    PFN_wgpuSurfaceGetCurrentTexture,   g_surface_get_texture);
    LOAD_SYM(wgpuSurfacePresent,              PFN_wgpuSurfacePresent,             g_surface_present);
    LOAD_SYM(wgpuSurfaceUnconfigure,          PFN_wgpuSurfaceUnconfigure,         g_surface_unconfigure);
    LOAD_SYM(wgpuSurfaceRelease,              PFN_wgpuSurfaceRelease,             g_surface_release);

    /* Texture */
    LOAD_SYM(wgpuDeviceCreateTexture,   PFN_wgpuDeviceCreateTexture,   g_create_texture);
    LOAD_SYM(wgpuTextureCreateView,     PFN_wgpuTextureCreateView,     g_texture_create_view);
    LOAD_SYM(wgpuTextureRelease,        PFN_wgpuTextureRelease,        g_texture_release);
    LOAD_SYM(wgpuTextureViewRelease,    PFN_wgpuTextureViewRelease,    g_texture_view_release);

    /* Shader */
    LOAD_SYM(wgpuDeviceCreateShaderModule, PFN_wgpuDeviceCreateShaderModule, g_create_shader_module);
    LOAD_SYM(wgpuShaderModuleRelease,      PFN_wgpuShaderModuleRelease,      g_shader_module_release);

    /* Pipeline */
    LOAD_SYM(wgpuDeviceCreateRenderPipeline,  PFN_wgpuDeviceCreateRenderPipeline, g_create_render_pipeline);
    LOAD_SYM(wgpuRenderPipelineRelease,       PFN_wgpuRenderPipelineRelease,      g_render_pipeline_release);
    LOAD_SYM(wgpuDeviceCreatePipelineLayout,  PFN_wgpuDeviceCreatePipelineLayout, g_create_pipeline_layout);
    LOAD_SYM(wgpuPipelineLayoutRelease,       PFN_wgpuPipelineLayoutRelease,      g_pipeline_layout_release);

    /* Buffer */
    LOAD_SYM(wgpuDeviceCreateBuffer,  PFN_wgpuDeviceCreateBuffer,  g_create_buffer);
    LOAD_SYM(wgpuQueueWriteBuffer,    PFN_wgpuQueueWriteBuffer,    g_queue_write_buffer);
    LOAD_SYM(wgpuBufferRelease,       PFN_wgpuBufferRelease,       g_buffer_release);

    /* Command encoder */
    LOAD_SYM(wgpuDeviceCreateCommandEncoder,      PFN_wgpuDeviceCreateCommandEncoder,      g_create_command_encoder);
    LOAD_SYM(wgpuCommandEncoderBeginRenderPass,   PFN_wgpuCommandEncoderBeginRenderPass,   g_begin_render_pass);
    LOAD_SYM(wgpuCommandEncoderFinish,            PFN_wgpuCommandEncoderFinish,            g_encoder_finish);
    LOAD_SYM(wgpuCommandEncoderRelease,           PFN_wgpuCommandEncoderRelease,           g_command_encoder_release);

    /* Render pass encoder */
    LOAD_SYM(wgpuRenderPassEncoderSetPipeline,     PFN_wgpuRenderPassEncoderSetPipeline,     g_rp_set_pipeline);
    LOAD_SYM(wgpuRenderPassEncoderSetVertexBuffer, PFN_wgpuRenderPassEncoderSetVertexBuffer, g_rp_set_vertex_buffer);
    LOAD_SYM(wgpuRenderPassEncoderDraw,            PFN_wgpuRenderPassEncoderDraw,            g_rp_draw);
    LOAD_SYM(wgpuRenderPassEncoderEnd,             PFN_wgpuRenderPassEncoderEnd,             g_rp_end);
    LOAD_SYM(wgpuRenderPassEncoderRelease,         PFN_wgpuRenderPassEncoderRelease,         g_rp_release);

    /* Queue submit */
    LOAD_SYM(wgpuQueueSubmit,          PFN_wgpuQueueSubmit,          g_queue_submit);
    LOAD_SYM(wgpuCommandBufferRelease, PFN_wgpuCommandBufferRelease, g_command_buffer_release);

    /* Validate core symbols (non-core symbols are optional for graceful degradation) */
    if (g_create_instance == NULL || g_release_instance == NULL ||
        g_request_adapter == NULL || g_request_device == NULL ||
        g_release_adapter == NULL || g_release_device == NULL ||
        g_get_queue == NULL || g_release_queue == NULL) {
        set_error("Failed to load required wgpu core symbols");
        dlclose(g_wgpu_lib);
        g_wgpu_lib = NULL;
        return 0;
    }

    set_error(NULL);
    return 1;
}

/* ═══════════════════════════════════════════════════════════════════
   Public API — Instance / Adapter / Device (unchanged logic)
   ═══════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_instance(void** out_instance) {
    if (out_instance == NULL) {
        set_error("out_instance is null");
        return 0;
    }
    *out_instance = NULL;

    if (g_create_instance == NULL) {
        set_error("Bridge not initialized");
        return 0;
    }

    WGPUInstanceDescriptor desc;
    desc.nextInChain = NULL;

    WGPUInstance instance = g_create_instance(&desc);
    if (instance == NULL) {
        set_error("wgpuCreateInstance returned null");
        return 0;
    }

    *out_instance = (void*)instance;
    return 1;
}

int wgpu_bridge_request_adapter(void* instance, void** out_adapter) {
    if (instance == NULL || out_adapter == NULL) {
        set_error("invalid adapter request arguments");
        return 0;
    }
    *out_adapter = NULL;

    if (g_request_adapter == NULL) {
        set_error("Bridge not initialized");
        return 0;
    }

    WGPURequestAdapterOptions options;
    memset(&options, 0, sizeof(options));

    AwaitResult ar;
    await_init(&ar);
    g_request_adapter((WGPUInstance)instance, &options, adapter_callback, &ar);
    await_wait(&ar);

    if (!ar.success) {
        set_error(ar.message[0] != '\0' ? ar.message : "wgpuInstanceRequestAdapter failed");
        await_deinit(&ar);
        return 0;
    }

    *out_adapter = ar.object;
    await_deinit(&ar);
    return 1;
}

int wgpu_bridge_request_device(void* adapter, void** out_device) {
    if (adapter == NULL || out_device == NULL) {
        set_error("invalid device request arguments");
        return 0;
    }
    *out_device = NULL;

    if (g_request_device == NULL) {
        set_error("Bridge not initialized");
        return 0;
    }

    WGPUDeviceDescriptor descriptor;
    memset(&descriptor, 0, sizeof(descriptor));

    AwaitResult ar;
    await_init(&ar);
    g_request_device((WGPUAdapter)adapter, &descriptor, device_callback, &ar);
    await_wait(&ar);

    if (!ar.success) {
        set_error(ar.message[0] != '\0' ? ar.message : "wgpuAdapterRequestDevice failed");
        await_deinit(&ar);
        return 0;
    }

    *out_device = ar.object;
    await_deinit(&ar);
    return 1;
}

int wgpu_bridge_get_queue(void* device, void** out_queue) {
    if (device == NULL || out_queue == NULL) {
        set_error("invalid get_queue arguments");
        return 0;
    }
    if (g_get_queue == NULL) {
        set_error("Bridge not initialized");
        return 0;
    }
    *out_queue = (void*)g_get_queue((WGPUDevice)device);
    return (*out_queue != NULL) ? 1 : 0;
}

int wgpu_bridge_release_queue(void* queue) {
    if (queue == NULL) return 1;
    if (g_release_queue == NULL) { set_error("Bridge not initialized"); return 0; }
    g_release_queue((WGPUQueue)queue);
    return 1;
}

int wgpu_bridge_release_device(void* device) {
    if (device == NULL) return 1;
    if (g_release_device == NULL) { set_error("Bridge not initialized"); return 0; }
    g_release_device((WGPUDevice)device);
    return 1;
}

int wgpu_bridge_release_adapter(void* adapter) {
    if (adapter == NULL) return 1;
    if (g_release_adapter == NULL) { set_error("Bridge not initialized"); return 0; }
    g_release_adapter((WGPUAdapter)adapter);
    return 1;
}

int wgpu_bridge_release_instance(void* instance) {
    if (instance == NULL) return 1;
    if (g_release_instance == NULL) { set_error("Bridge not initialized"); return 0; }
    g_release_instance((WGPUInstance)instance);
    return 1;
}

void wgpu_bridge_shutdown(void) {
    g_create_instance = NULL;
    g_release_instance = NULL;
    g_request_adapter = NULL;
    g_request_device = NULL;
    g_release_adapter = NULL;
    g_release_device = NULL;
    g_get_queue = NULL;
    g_release_queue = NULL;

    g_create_surface = NULL;
    g_configure_surface = NULL;
    g_surface_get_texture = NULL;
    g_surface_present = NULL;
    g_surface_unconfigure = NULL;
    g_surface_release = NULL;

    g_create_texture = NULL;
    g_texture_create_view = NULL;
    g_texture_release = NULL;
    g_texture_view_release = NULL;

    g_create_shader_module = NULL;
    g_shader_module_release = NULL;

    g_create_render_pipeline = NULL;
    g_render_pipeline_release = NULL;
    g_create_pipeline_layout = NULL;
    g_pipeline_layout_release = NULL;

    g_create_buffer = NULL;
    g_queue_write_buffer = NULL;
    g_buffer_release = NULL;

    g_create_command_encoder = NULL;
    g_begin_render_pass = NULL;
    g_encoder_finish = NULL;
    g_command_encoder_release = NULL;

    g_rp_set_pipeline = NULL;
    g_rp_set_vertex_buffer = NULL;
    g_rp_draw = NULL;
    g_rp_end = NULL;
    g_rp_release = NULL;

    g_queue_submit = NULL;
    g_command_buffer_release = NULL;

    if (g_wgpu_lib != NULL) {
        dlclose(g_wgpu_lib);
        g_wgpu_lib = NULL;
    }

    set_error(NULL);
}

/* ═══════════════════════════════════════════════════════════════════
   Public API — Surface
   ═══════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_surface_metal(void* instance, void* ca_metal_layer, void** out_surface) {
    if (instance == NULL || ca_metal_layer == NULL || out_surface == NULL) {
        set_error("invalid create_surface_metal arguments");
        return 0;
    }
    if (g_create_surface == NULL) {
        set_error("wgpuInstanceCreateSurface not loaded");
        return 0;
    }

    WGPUSurfaceSourceMetalLayer metal_desc;
    memset(&metal_desc, 0, sizeof(metal_desc));
    metal_desc.chain.sType = WGPU_STYPE_SURFACE_FROM_METAL_LAYER;
    metal_desc.chain.next = NULL;
    metal_desc.layer = ca_metal_layer;

    WGPUSurfaceDescriptor desc;
    memset(&desc, 0, sizeof(desc));
    desc.nextInChain = (const WGPUChainedStruct*)&metal_desc;
    desc.label = NULL;

    WGPUSurface_T surface = g_create_surface((WGPUInstance)instance, &desc);
    if (surface == NULL) {
        set_error("wgpuInstanceCreateSurface returned null");
        return 0;
    }

    *out_surface = (void*)surface;
    return 1;
}

int wgpu_bridge_configure_surface(void* surface, void* device,
                                  WGPUBridgeTextureFormat format,
                                  uint32_t width, uint32_t height,
                                  WGPUBridgePresentMode present_mode) {
    if (surface == NULL || device == NULL) {
        set_error("invalid configure_surface arguments");
        return 0;
    }
    if (g_configure_surface == NULL) {
        set_error("wgpuSurfaceConfigure not loaded");
        return 0;
    }

    WGPUSurfaceConfiguration config;
    memset(&config, 0, sizeof(config));
    config.device = (WGPUDevice)device;
    config.format = bridge_format_to_wgpu(format);
    config.usage = 0x10; /* RenderAttachment */
    config.alphaMode = 0; /* Auto */
    config.width = width;
    config.height = height;
    config.presentMode = bridge_present_mode_to_wgpu(present_mode);

    g_configure_surface((WGPUSurface_T)surface, &config);
    return 1;
}

int wgpu_bridge_surface_get_current_texture_view(void* surface,
                                                 void** out_texture,
                                                 void** out_view) {
    if (surface == NULL || out_view == NULL) {
        set_error("invalid surface_get_current_texture_view arguments");
        return 0;
    }
    if (g_surface_get_texture == NULL || g_texture_create_view == NULL) {
        set_error("surface/texture functions not loaded");
        return 0;
    }

    WGPUSurfaceTexture st;
    memset(&st, 0, sizeof(st));
    g_surface_get_texture((WGPUSurface_T)surface, &st);

    if (st.texture == NULL || st.status != 0) {
        set_error("wgpuSurfaceGetCurrentTexture failed");
        return 0;
    }

    WGPUTextureView_T view = g_texture_create_view(st.texture, NULL);
    if (view == NULL) {
        set_error("wgpuTextureCreateView returned null");
        return 0;
    }

    if (out_texture != NULL) {
        *out_texture = (void*)st.texture;
    }
    *out_view = (void*)view;
    return 1;
}

void wgpu_bridge_surface_present(void* surface) {
    if (surface != NULL && g_surface_present != NULL) {
        g_surface_present((WGPUSurface_T)surface);
    }
}

void wgpu_bridge_release_surface(void* surface) {
    if (surface != NULL && g_surface_release != NULL) {
        g_surface_release((WGPUSurface_T)surface);
    }
}

/* ═══════════════════════════════════════════════════════════════════
   Public API — Texture & View
   ═══════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_texture(void* device,
                               const WGPUBridgeTextureDesc* desc,
                               void** out_texture) {
    if (device == NULL || desc == NULL || out_texture == NULL) {
        set_error("invalid create_texture arguments");
        return 0;
    }
    if (g_create_texture == NULL) {
        set_error("wgpuDeviceCreateTexture not loaded");
        return 0;
    }

    WGPUTextureDescriptor_I td;
    memset(&td, 0, sizeof(td));
    td.usage = (uint32_t)desc->usage_flags;
    td.dimension = 1; /* 2D */
    td.size.width = desc->width;
    td.size.height = desc->height;
    td.size.depthOrArrayLayers = desc->depth_or_layers > 0 ? desc->depth_or_layers : 1;
    td.format = bridge_format_to_wgpu(desc->format);
    td.mipLevelCount = desc->mip_level_count > 0 ? desc->mip_level_count : 1;
    td.sampleCount = 1;

    WGPUTexture_T texture = g_create_texture((WGPUDevice)device, &td);
    if (texture == NULL) {
        set_error("wgpuDeviceCreateTexture returned null");
        return 0;
    }

    *out_texture = (void*)texture;
    return 1;
}

int wgpu_bridge_create_texture_view_default(void* texture, void** out_view) {
    if (texture == NULL || out_view == NULL) {
        set_error("invalid create_texture_view arguments");
        return 0;
    }
    if (g_texture_create_view == NULL) {
        set_error("wgpuTextureCreateView not loaded");
        return 0;
    }

    WGPUTextureView_T view = g_texture_create_view((WGPUTexture_T)texture, NULL);
    if (view == NULL) {
        set_error("wgpuTextureCreateView returned null");
        return 0;
    }

    *out_view = (void*)view;
    return 1;
}

void wgpu_bridge_release_texture(void* texture) {
    if (texture != NULL && g_texture_release != NULL) {
        g_texture_release((WGPUTexture_T)texture);
    }
}

void wgpu_bridge_release_texture_view(void* view) {
    if (view != NULL && g_texture_view_release != NULL) {
        g_texture_view_release((WGPUTextureView_T)view);
    }
}

/* ═══════════════════════════════════════════════════════════════════
   Public API — Shader Module
   ═══════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_shader_module(void* device,
                                     const char* wgsl_code,
                                     const char* label,
                                     void** out_module) {
    if (device == NULL || wgsl_code == NULL || out_module == NULL) {
        set_error("invalid create_shader_module arguments");
        return 0;
    }
    if (g_create_shader_module == NULL) {
        set_error("wgpuDeviceCreateShaderModule not loaded");
        return 0;
    }

    WGPUShaderSourceWGSL wgsl;
    memset(&wgsl, 0, sizeof(wgsl));
    wgsl.chain.sType = WGPU_STYPE_SHADER_SOURCE_WGSL;
    wgsl.chain.next = NULL;
    wgsl.code = wgsl_code;

    WGPUShaderModuleDescriptor desc;
    memset(&desc, 0, sizeof(desc));
    desc.nextInChain = (const WGPUChainedStruct*)&wgsl;
    desc.label = label;

    WGPUShaderModule_T module = g_create_shader_module((WGPUDevice)device, &desc);
    if (module == NULL) {
        set_error("wgpuDeviceCreateShaderModule returned null");
        return 0;
    }

    *out_module = (void*)module;
    return 1;
}

void wgpu_bridge_release_shader_module(void* module) {
    if (module != NULL && g_shader_module_release != NULL) {
        g_shader_module_release((WGPUShaderModule_T)module);
    }
}

/* ═══════════════════════════════════════════════════════════════════
   Public API — Render Pipeline
   ═══════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_render_pipeline(
    void* device,
    void* shader_module,
    const char* vertex_entry,
    const char* fragment_entry,
    WGPUBridgeTextureFormat color_format,
    WGPUBridgePrimitiveTopology topology,
    WGPUBridgeCullMode cull_mode,
    const WGPUBridgeVertexBufferLayout* vertex_buffers,
    uint32_t vertex_buffer_count,
    void** out_pipeline)
{
    if (device == NULL || shader_module == NULL || out_pipeline == NULL) {
        set_error("invalid create_render_pipeline arguments");
        return 0;
    }
    if (g_create_render_pipeline == NULL) {
        set_error("wgpuDeviceCreateRenderPipeline not loaded");
        return 0;
    }

    /* Convert vertex buffer layouts */
    WGPUVertexBufferLayout_I* vb_layouts = NULL;
    WGPUVertexAttribute_I* all_attrs = NULL;

    if (vertex_buffer_count > 0 && vertex_buffers != NULL) {
        vb_layouts = (WGPUVertexBufferLayout_I*)calloc(vertex_buffer_count, sizeof(WGPUVertexBufferLayout_I));

        /* Count total attributes for single allocation */
        uint32_t total_attrs = 0;
        for (uint32_t i = 0; i < vertex_buffer_count; i++) {
            total_attrs += vertex_buffers[i].attribute_count;
        }
        all_attrs = (WGPUVertexAttribute_I*)calloc(total_attrs, sizeof(WGPUVertexAttribute_I));

        uint32_t attr_offset = 0;
        for (uint32_t i = 0; i < vertex_buffer_count; i++) {
            vb_layouts[i].arrayStride = vertex_buffers[i].array_stride;
            vb_layouts[i].stepMode = 0; /* Vertex */
            vb_layouts[i].attributeCount = vertex_buffers[i].attribute_count;
            vb_layouts[i].attributes = &all_attrs[attr_offset];
            for (uint32_t j = 0; j < vertex_buffers[i].attribute_count; j++) {
                all_attrs[attr_offset + j].format = bridge_vertex_format_to_wgpu(vertex_buffers[i].attributes[j].format);
                all_attrs[attr_offset + j].offset = vertex_buffers[i].attributes[j].offset;
                all_attrs[attr_offset + j].shaderLocation = vertex_buffers[i].attributes[j].shader_location;
            }
            attr_offset += vertex_buffers[i].attribute_count;
        }
    }

    /* Color target */
    WGPUColorTargetState_I color_target;
    memset(&color_target, 0, sizeof(color_target));
    color_target.format = bridge_format_to_wgpu(color_format);
    color_target.writeMask = 0x0F; /* All */

    /* Fragment state */
    WGPUFragmentState_I frag;
    memset(&frag, 0, sizeof(frag));
    frag.module = (WGPUShaderModule_T)shader_module;
    frag.entryPoint = fragment_entry;
    frag.targetCount = 1;
    frag.targets = &color_target;

    /* Pipeline descriptor */
    WGPURenderPipelineDescriptor_I desc;
    memset(&desc, 0, sizeof(desc));
    desc.vertex.module = (WGPUShaderModule_T)shader_module;
    desc.vertex.entryPoint = vertex_entry;
    desc.vertex.bufferCount = vertex_buffer_count;
    desc.vertex.buffers = vb_layouts;
    desc.primitive.topology = bridge_topology_to_wgpu(topology);
    desc.primitive.stripIndexFormat = 0; /* Undefined */
    desc.multisample.count = 1;
    desc.multisample.mask = 0xFFFFFFFF;
    desc.fragment = &frag;
    desc.layout = NULL; /* Auto layout */

    WGPURenderPipeline_T pipeline = g_create_render_pipeline((WGPUDevice)device, &desc);

    free(all_attrs);
    free(vb_layouts);

    if (pipeline == NULL) {
        set_error("wgpuDeviceCreateRenderPipeline returned null");
        return 0;
    }

    *out_pipeline = (void*)pipeline;
    return 1;
}

void wgpu_bridge_release_render_pipeline(void* pipeline) {
    if (pipeline != NULL && g_render_pipeline_release != NULL) {
        g_render_pipeline_release((WGPURenderPipeline_T)pipeline);
    }
}

/* ═══════════════════════════════════════════════════════════════════
   Public API — Buffer
   ═══════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_buffer(void* device,
                              const WGPUBridgeBufferDesc* desc,
                              void** out_buffer) {
    if (device == NULL || desc == NULL || out_buffer == NULL) {
        set_error("invalid create_buffer arguments");
        return 0;
    }
    if (g_create_buffer == NULL) {
        set_error("wgpuDeviceCreateBuffer not loaded");
        return 0;
    }

    WGPUBufferDescriptor_I bd;
    memset(&bd, 0, sizeof(bd));
    bd.usage = (uint32_t)desc->usage_flags;
    bd.size = desc->size;
    bd.mappedAtCreation = desc->mapped_at_creation ? 1 : 0;

    WGPUBuffer_T buffer = g_create_buffer((WGPUDevice)device, &bd);
    if (buffer == NULL) {
        set_error("wgpuDeviceCreateBuffer returned null");
        return 0;
    }

    *out_buffer = (void*)buffer;
    return 1;
}

void wgpu_bridge_write_buffer(void* queue, void* buffer,
                              uint64_t offset, const void* data, size_t size) {
    if (queue == NULL || buffer == NULL || data == NULL || size == 0) return;
    if (g_queue_write_buffer == NULL) return;
    g_queue_write_buffer((WGPUQueue)queue, (WGPUBuffer_T)buffer, offset, data, size);
}

void wgpu_bridge_release_buffer(void* buffer) {
    if (buffer != NULL && g_buffer_release != NULL) {
        g_buffer_release((WGPUBuffer_T)buffer);
    }
}

/* ═══════════════════════════════════════════════════════════════════
   Public API — Command Encoding
   ═══════════════════════════════════════════════════════════════════ */

int wgpu_bridge_create_command_encoder(void* device, void** out_encoder) {
    if (device == NULL || out_encoder == NULL) {
        set_error("invalid create_command_encoder arguments");
        return 0;
    }
    if (g_create_command_encoder == NULL) {
        set_error("wgpuDeviceCreateCommandEncoder not loaded");
        return 0;
    }

    WGPUCommandEncoderDescriptor_I desc;
    memset(&desc, 0, sizeof(desc));

    WGPUCommandEncoder_T encoder = g_create_command_encoder((WGPUDevice)device, &desc);
    if (encoder == NULL) {
        set_error("wgpuDeviceCreateCommandEncoder returned null");
        return 0;
    }

    *out_encoder = (void*)encoder;
    return 1;
}

int wgpu_bridge_begin_render_pass(void* encoder,
                                  void* color_view,
                                  WGPUBridgeLoadOp load_op,
                                  WGPUBridgeStoreOp store_op,
                                  WGPUBridgeColor clear_color,
                                  void** out_pass) {
    if (encoder == NULL || color_view == NULL || out_pass == NULL) {
        set_error("invalid begin_render_pass arguments");
        return 0;
    }
    if (g_begin_render_pass == NULL) {
        set_error("wgpuCommandEncoderBeginRenderPass not loaded");
        return 0;
    }

    WGPURenderPassColorAttachment_I ca;
    memset(&ca, 0, sizeof(ca));
    ca.view = (WGPUTextureView_T)color_view;
    ca.depthSlice = 0xFFFFFFFF; /* WGPU_DEPTH_SLICE_UNDEFINED */
    ca.loadOp = bridge_load_op_to_wgpu(load_op);
    ca.storeOp = bridge_store_op_to_wgpu(store_op);
    ca.clearValue.r = clear_color.r;
    ca.clearValue.g = clear_color.g;
    ca.clearValue.b = clear_color.b;
    ca.clearValue.a = clear_color.a;

    WGPURenderPassDescriptor_I desc;
    memset(&desc, 0, sizeof(desc));
    desc.colorAttachmentCount = 1;
    desc.colorAttachments = &ca;

    WGPURenderPassEncoder_T pass = g_begin_render_pass((WGPUCommandEncoder_T)encoder, &desc);
    if (pass == NULL) {
        set_error("wgpuCommandEncoderBeginRenderPass returned null");
        return 0;
    }

    *out_pass = (void*)pass;
    return 1;
}

void wgpu_bridge_render_pass_set_pipeline(void* pass, void* pipeline) {
    if (pass != NULL && pipeline != NULL && g_rp_set_pipeline != NULL) {
        g_rp_set_pipeline((WGPURenderPassEncoder_T)pass, (WGPURenderPipeline_T)pipeline);
    }
}

void wgpu_bridge_render_pass_set_vertex_buffer(void* pass, uint32_t slot,
                                               void* buffer, uint64_t offset,
                                               uint64_t size) {
    if (pass != NULL && buffer != NULL && g_rp_set_vertex_buffer != NULL) {
        g_rp_set_vertex_buffer((WGPURenderPassEncoder_T)pass, slot,
                               (WGPUBuffer_T)buffer, offset, size);
    }
}

void wgpu_bridge_render_pass_draw(void* pass,
                                  uint32_t vertex_count,
                                  uint32_t instance_count,
                                  uint32_t first_vertex,
                                  uint32_t first_instance) {
    if (pass != NULL && g_rp_draw != NULL) {
        g_rp_draw((WGPURenderPassEncoder_T)pass,
                  vertex_count, instance_count, first_vertex, first_instance);
    }
}

void wgpu_bridge_render_pass_end(void* pass) {
    if (pass != NULL && g_rp_end != NULL) {
        g_rp_end((WGPURenderPassEncoder_T)pass);
    }
}

int wgpu_bridge_encoder_finish(void* encoder, void** out_command_buffer) {
    if (encoder == NULL || out_command_buffer == NULL) {
        set_error("invalid encoder_finish arguments");
        return 0;
    }
    if (g_encoder_finish == NULL) {
        set_error("wgpuCommandEncoderFinish not loaded");
        return 0;
    }

    WGPUCommandBufferDescriptor_I desc;
    memset(&desc, 0, sizeof(desc));

    WGPUCommandBuffer_T cb = g_encoder_finish((WGPUCommandEncoder_T)encoder, &desc);
    if (cb == NULL) {
        set_error("wgpuCommandEncoderFinish returned null");
        return 0;
    }

    *out_command_buffer = (void*)cb;
    return 1;
}

void wgpu_bridge_queue_submit(void* queue, void** command_buffers, uint32_t count) {
    if (queue == NULL || command_buffers == NULL || count == 0) return;
    if (g_queue_submit == NULL) return;
    g_queue_submit((WGPUQueue)queue, (size_t)count, (const WGPUCommandBuffer_T*)command_buffers);
}

void wgpu_bridge_release_command_buffer(void* command_buffer) {
    if (command_buffer != NULL && g_command_buffer_release != NULL) {
        g_command_buffer_release((WGPUCommandBuffer_T)command_buffer);
    }
}

void wgpu_bridge_release_command_encoder(void* encoder) {
    if (encoder != NULL && g_command_encoder_release != NULL) {
        g_command_encoder_release((WGPUCommandEncoder_T)encoder);
    }
}

void wgpu_bridge_release_render_pass_encoder(void* pass) {
    if (pass != NULL && g_rp_release != NULL) {
        g_rp_release((WGPURenderPassEncoder_T)pass);
    }
}
