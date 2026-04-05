#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <IOSurface/IOSurface.h>
#include <cstdio>
#include <cstring>
#include <unordered_map>
#include <vector>
#include "metal_rhi_bridge.h"

// ---------------------------------------------------------------------------
// Metal RHI Bridge — real Metal API implementation
// ---------------------------------------------------------------------------

// Per-set binding data stored after registration
struct BindingSetData {
    std::vector<GuavaMetalBindingEntry> entries;
};

// Main bridge context — owns all Metal objects
struct GuavaMetalRhiContext {
    id<MTLDevice>       device;
    id<MTLCommandQueue> graphics_queue;
    id<MTLCommandQueue> compute_queue;

    // Swapchain state
    CAMetalLayer*        metal_layer    = nil;
    id<CAMetalDrawable>  current_drawable = nil;
    uint32_t             swapchain_texture_id = 0; // texture ID for current drawable
    bool                 vsync_enabled = true;

    uint32_t next_buffer_id   = 1;
    uint32_t next_texture_id  = 1;
    uint32_t next_sampler_id  = 1;
    uint32_t next_shader_id   = 1;
    uint32_t next_gfx_pipe_id = 1;
    uint32_t next_cmp_pipe_id = 1;

    std::unordered_map<uint32_t, id<MTLBuffer>>               buffers;
    std::unordered_map<uint32_t, id<MTLTexture>>              textures;
    std::unordered_map<uint32_t, id<MTLSamplerState>>         samplers;
    std::unordered_map<uint32_t, id<MTLFunction>>             shader_functions;
    std::unordered_map<uint32_t, id<MTLRenderPipelineState>>  gfx_pipelines;
    std::unordered_map<uint32_t, id<MTLComputePipelineState>> cmp_pipelines;
    std::unordered_map<uint32_t, BindingSetData>              binding_sets;
    std::unordered_map<uint32_t, id<MTLDepthStencilState>>    depth_stencil_states;
    std::unordered_map<uint32_t, MTLPrimitiveType>             pipeline_primitives;
    std::unordered_map<uint32_t, id<MTLSharedEvent>>          shared_events;

    // IOSurface references keyed by texture_id (to prevent premature deallocation)
    std::unordered_map<uint32_t, IOSurfaceRef>                 iosurfaces;

    // Last committed command buffer — used for GPU completion sync
    id<MTLCommandBuffer> last_command_buffer = nil;

    // Shader libraries cached per shader module (for Metal library compilation)
    std::unordered_map<uint32_t, id<MTLLibrary>>              shader_libraries;
};

// ---------------------------------------------------------------------------
// Helper: map RHI TextureFormat ordinal → MTLPixelFormat
// ---------------------------------------------------------------------------
static MTLPixelFormat mapPixelFormat(uint32_t fmt) {
    // Must match types.zig TextureFormat enum ordering:
    // unknown=0, r8_unorm=1, rgba8_unorm=2, bgra8_unorm=3,
    // bgra8_unorm_srgb=4, rgba8_unorm_srgb=5, rgba16_float=6,
    // rgba32_float=7, d24_unorm=8, d24_unorm_s8_uint=9, d32_float=10
    switch (fmt) {
        case 1:  return MTLPixelFormatR8Unorm;
        case 2:  return MTLPixelFormatRGBA8Unorm;
        case 3:  return MTLPixelFormatBGRA8Unorm;
        case 4:  return MTLPixelFormatBGRA8Unorm_sRGB;
        case 5:  return MTLPixelFormatRGBA8Unorm_sRGB;
        case 6:  return MTLPixelFormatRGBA16Float;
        case 7:  return MTLPixelFormatRGBA32Float;
        case 8:  return MTLPixelFormatDepth24Unorm_Stencil8; // closest on macOS
        case 9:  return MTLPixelFormatDepth24Unorm_Stencil8;
        case 10: return MTLPixelFormatDepth32Float;
        default: return MTLPixelFormatRGBA8Unorm;
    }
}

// ---------------------------------------------------------------------------
// Helper: map RHI SamplerAddressMode ordinal → MTLSamplerAddressMode
// ---------------------------------------------------------------------------
static MTLSamplerAddressMode mapAddressMode(uint32_t mode) {
    switch (mode) {
        case 0:  return MTLSamplerAddressModeRepeat;
        case 1:  return MTLSamplerAddressModeMirrorRepeat;
        case 2:  return MTLSamplerAddressModeClampToEdge;
        default: return MTLSamplerAddressModeRepeat;
    }
}

// ---------------------------------------------------------------------------
// Helper: map RHI PrimitiveType ordinal → MTLPrimitiveType
// ---------------------------------------------------------------------------
static MTLPrimitiveType mapPrimitive(uint32_t prim) {
    switch (prim) {
        case 0:  return MTLPrimitiveTypeTriangle;
        case 1:  return MTLPrimitiveTypeTriangleStrip;
        case 2:  return MTLPrimitiveTypeLine;
        case 3:  return MTLPrimitiveTypeLineStrip;
        case 4:  return MTLPrimitiveTypePoint;
        default: return MTLPrimitiveTypeTriangle;
    }
}

// ---------------------------------------------------------------------------
// Helper: map RHI TextureFormat ordinal → bytes per pixel
// ---------------------------------------------------------------------------
static uint32_t bytesPerPixel(uint32_t fmt) {
    switch (fmt) {
        case 1:  return 1;   // r8_unorm
        case 2:  return 4;   // rgba8_unorm
        case 3:  return 4;   // bgra8_unorm
        case 4:  return 4;   // bgra8_unorm_srgb
        case 5:  return 4;   // rgba8_unorm_srgb
        case 6:  return 8;   // rgba16_float
        case 7:  return 16;  // rgba32_float
        case 10: return 4;   // d32_float
        default: return 4;
    }
}

static id<MTLSharedEvent> findOrCreateSharedEvent(GuavaMetalRhiContext* ctx, uint32_t semaphore_id) {
    auto it = ctx->shared_events.find(semaphore_id);
    if (it != ctx->shared_events.end()) {
        return it->second;
    }

    if (@available(macOS 10.14, iOS 12.0, *)) {
        id<MTLSharedEvent> event = [ctx->device newSharedEvent];
        if (!event) {
            fprintf(stderr, "[GuavaMetal] Failed to allocate MTLSharedEvent for timeline semaphore %u\n", semaphore_id);
            return nil;
        }
        ctx->shared_events[semaphore_id] = event;
        return event;
    }

    fprintf(stderr, "[GuavaMetal] Timeline semaphore submit requested but MTLSharedEvent is unavailable\n");
    return nil;
}

// ---------------------------------------------------------------------------
// Helper: map RHI CompareOp ordinal → MTLCompareFunction
// ---------------------------------------------------------------------------
static MTLCompareFunction mapCompareOp(uint32_t op) {
    switch (op) {
        case 0:  return MTLCompareFunctionNever;
        case 1:  return MTLCompareFunctionLess;
        case 2:  return MTLCompareFunctionEqual;
        case 3:  return MTLCompareFunctionLessEqual;
        case 4:  return MTLCompareFunctionGreater;
        case 5:  return MTLCompareFunctionNotEqual;
        case 6:  return MTLCompareFunctionGreaterEqual;
        case 7:  return MTLCompareFunctionAlways;
        default: return MTLCompareFunctionAlways;
    }
}

// ---------------------------------------------------------------------------
// Helper: map RHI VertexElementFormat ordinal → MTLVertexFormat
// ---------------------------------------------------------------------------
static MTLVertexFormat mapVertexFormat(uint32_t fmt) {
    switch (fmt) {
        case 0:  return MTLVertexFormatFloat2;
        case 1:  return MTLVertexFormatFloat3;
        case 2:  return MTLVertexFormatFloat4;
        default: return MTLVertexFormatFloat3;
    }
}

// Vertex buffer base index in Metal argument table (must match submit decoder)
static constexpr uint32_t kVertexBufferBaseIndex = 30;

// ---------------------------------------------------------------------------
// Helper: map RHI BlendFactor ordinal → MTLBlendFactor
// ---------------------------------------------------------------------------
static MTLBlendFactor mapBlendFactor(uint32_t f) {
    switch (f) {
        case 0:  return MTLBlendFactorZero;
        case 1:  return MTLBlendFactorOne;
        case 2:  return MTLBlendFactorSourceColor;
        case 3:  return MTLBlendFactorOneMinusSourceColor;
        case 4:  return MTLBlendFactorDestinationColor;
        case 5:  return MTLBlendFactorOneMinusDestinationColor;
        case 6:  return MTLBlendFactorSourceAlpha;
        case 7:  return MTLBlendFactorOneMinusSourceAlpha;
        case 8:  return MTLBlendFactorDestinationAlpha;
        case 9:  return MTLBlendFactorOneMinusDestinationAlpha;
        case 10: return MTLBlendFactorBlendColor;
        case 11: return MTLBlendFactorOneMinusBlendColor;
        case 12: return MTLBlendFactorSourceAlphaSaturated;
        default: return MTLBlendFactorOne;
    }
}

// ---------------------------------------------------------------------------
// Helper: map RHI BlendOp ordinal → MTLBlendOperation
// ---------------------------------------------------------------------------
static MTLBlendOperation mapBlendOp(uint32_t op) {
    switch (op) {
        case 0:  return MTLBlendOperationAdd;
        case 1:  return MTLBlendOperationSubtract;
        case 2:  return MTLBlendOperationReverseSubtract;
        case 3:  return MTLBlendOperationMin;
        case 4:  return MTLBlendOperationMax;
        default: return MTLBlendOperationAdd;
    }
}

// ── Command buffer opcode constants (must match command_buffer.zig) ────────
enum RhiOpCode : uint8_t {
    OP_BEGIN_RENDER_PASS  = 0,
    OP_END_RENDER_PASS    = 1,
    OP_BEGIN_COMPUTE_PASS = 2,
    OP_END_COMPUTE_PASS   = 3,
    OP_BEGIN_COPY_PASS    = 4,
    OP_END_COPY_PASS      = 5,
    OP_SET_BINDING_SET    = 6,
    OP_SET_VERTEX_BUFFER  = 7,
    OP_SET_INDEX_BUFFER   = 8,
    OP_SET_PIPELINE       = 9,
    OP_DRAW_INDEXED       = 10,
    OP_DRAW_INDIRECT      = 11,
    OP_DISPATCH           = 12,
    OP_DISPATCH_INDIRECT  = 13,
    OP_PIPELINE_BARRIER   = 14,
    OP_DRAW               = 15,
    OP_PUSH_UNIFORM       = 16,
    OP_SET_VIEWPORT       = 17,
    OP_SET_SCISSOR        = 18,
};

// Packed command structs (must match command_buffer.zig extern struct layout)
#pragma pack(push, 1)
struct CmdBeginRenderPass  {
    uint32_t color_target_id;
    uint32_t depth_target_id;
    uint32_t clear_mask;
    float clear_r;
    float clear_g;
    float clear_b;
    float clear_a;
    float clear_depth;
};
struct CmdBeginComputePass { uint32_t reserved; };
struct CmdBeginCopyPass    { uint32_t reserved; };
struct CmdSetBindingSet    { uint32_t slot; uint32_t set_id; };
struct CmdSetVertexBuffer  { uint32_t slot; uint32_t buffer_id; uint32_t offset; };
struct CmdSetIndexBuffer   { uint32_t buffer_id; uint32_t offset; uint32_t format; };
struct CmdSetPipeline      { uint32_t pipeline_id; };
struct CmdDrawIndexed      { uint32_t index_count; uint32_t instance_count; uint32_t first_index; int32_t vertex_offset; uint32_t first_instance; };
struct CmdDrawIndirect     { uint32_t buffer_id; uint32_t offset; uint32_t draw_count; };
struct CmdDispatch         { uint32_t x; uint32_t y; uint32_t z; };
struct CmdDispatchIndirect { uint32_t buffer_id; uint32_t offset; };
struct CmdPipelineBarrier  {
    uint32_t resource_id;
    uint32_t src_state_bits;
    uint32_t dst_state_bits;
    uint16_t subresource_base;
    uint16_t subresource_count;
    uint8_t resource_kind;
    uint8_t sync_action;
    uint8_t pass_scope;
    uint8_t src_queue;
    uint8_t dst_queue;
    uint8_t _padding[3];
};
struct CmdDraw             { uint32_t vertex_count; uint32_t instance_count; uint32_t first_vertex; uint32_t first_instance; };
struct CmdPushUniform      { uint8_t stage; uint8_t slot; uint16_t _pad; uint32_t data_len; /* followed by data_len bytes */ };
struct CmdSetViewport      { float x; float y; float w; float h; float min_depth; float max_depth; };
struct CmdSetScissor       { uint32_t x; uint32_t y; uint32_t w; uint32_t h; };
#pragma pack(pop)

// Max entries per binding set slot in the Metal argument table
static constexpr uint32_t kEntriesPerSlot = 8;

// ===================================================================
// Public C API
// ===================================================================

void* guava_metal_rhi_init(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "[GuavaMetal] MTLCreateSystemDefaultDevice failed\n");
            return nullptr;
        }

        auto* ctx = new GuavaMetalRhiContext();
        ctx->device = device;
        ctx->graphics_queue = [device newCommandQueue];
        ctx->compute_queue  = [device newCommandQueue];

        fprintf(stderr, "[GuavaMetal] RHI init — device: %s\n",
                [[device name] UTF8String]);
        return ctx;
    }
}

void guava_metal_rhi_destroy(void* raw) {
    if (!raw) return;
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
        // ARC handles Metal object release
        ctx->buffers.clear();
        ctx->textures.clear();
        ctx->samplers.clear();
        ctx->shader_functions.clear();
        ctx->shader_libraries.clear();
        ctx->gfx_pipelines.clear();
        ctx->cmp_pipelines.clear();
        ctx->binding_sets.clear();
        ctx->depth_stencil_states.clear();
        ctx->shared_events.clear();
        ctx->current_drawable = nil;
        ctx->metal_layer = nil;
        delete ctx;
    }
}

// ---------------------------------------------------------------------------
// Swapchain layer configuration
// ---------------------------------------------------------------------------

void guava_metal_rhi_set_layer(void* raw, void* ca_metal_layer) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    ctx->metal_layer = (__bridge CAMetalLayer*)ca_metal_layer;
    ctx->metal_layer.device = ctx->device;
    ctx->metal_layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    ctx->metal_layer.framebufferOnly = YES;
    if ([ctx->metal_layer respondsToSelector:@selector(setDisplaySyncEnabled:)]) {
        ctx->metal_layer.displaySyncEnabled = ctx->vsync_enabled ? YES : NO;
    }
}

void guava_metal_rhi_set_vsync_enabled(void* raw, bool enabled) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    ctx->vsync_enabled = enabled;
    if (ctx->metal_layer && [ctx->metal_layer respondsToSelector:@selector(setDisplaySyncEnabled:)]) {
        ctx->metal_layer.displaySyncEnabled = enabled ? YES : NO;
    }
}

// ---------------------------------------------------------------------------
// Resource creation
// ---------------------------------------------------------------------------

uint32_t guava_metal_rhi_create_buffer(void* raw, uint64_t size,
                                       uint32_t usage_bits,
                                       const char* label) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        MTLResourceOptions opts = MTLResourceStorageModeShared;
        id<MTLBuffer> buf = [ctx->device newBufferWithLength:(NSUInteger)size
                                                     options:opts];
        if (!buf) return 0;

        if (label) buf.label = [NSString stringWithUTF8String:label];

        uint32_t id = ctx->next_buffer_id++;
        ctx->buffers[id] = buf;
        return id;
    }
}

uint32_t guava_metal_rhi_create_texture(void* raw,
                                        const GuavaMetalTextureDesc* desc,
                                        const char* label) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        MTLTextureDescriptor* td = [[MTLTextureDescriptor alloc] init];
        td.pixelFormat = mapPixelFormat(desc->format);
        td.width  = desc->width;
        td.height = desc->height;
        td.depth  = desc->depth;
        td.mipmapLevelCount = desc->mip_levels;
        td.sampleCount = desc->sample_count;
        td.storageMode = MTLStorageModePrivate;

        // Dimension
        switch (desc->dimension) {
            case 1:  td.textureType = MTLTextureType3D; break;
            case 2:  td.textureType = MTLTextureTypeCube;
                     td.arrayLength = 1; break;
            case 3:  td.textureType = MTLTextureType2DArray;
                     td.arrayLength = desc->layers; break;
            default: td.textureType = MTLTextureType2D; break;
        }

        // Usage flags
        MTLTextureUsage usage = 0;
        if (desc->usage_bits & 0x01) usage |= MTLTextureUsageShaderRead;       // sampled
        if (desc->usage_bits & 0x02) usage |= MTLTextureUsageRenderTarget;     // color_target
        if (desc->usage_bits & 0x04) usage |= MTLTextureUsageRenderTarget;     // depth_stencil_target
        // New RHI texture usage bits:
        // 0x08 = storage_read, 0x10 = storage_write, 0x20/0x40 = transfer flags.
        if (desc->usage_bits & 0x08) usage |= MTLTextureUsageShaderRead;       // storage_read
        if (desc->usage_bits & 0x10) usage |= MTLTextureUsageShaderWrite;      // storage_write
        td.usage = usage;

        id<MTLTexture> tex = [ctx->device newTextureWithDescriptor:td];
        if (!tex) return 0;

        if (label) tex.label = [NSString stringWithUTF8String:label];

        uint32_t id = ctx->next_texture_id++;
        ctx->textures[id] = tex;
        return id;
    }
}

uint32_t guava_metal_rhi_create_sampler(void* raw,
                                        const GuavaMetalSamplerDesc* desc) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        MTLSamplerDescriptor* sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter    = desc->min_filter == 0 ? MTLSamplerMinMagFilterNearest
                                                : MTLSamplerMinMagFilterLinear;
        sd.magFilter    = desc->mag_filter == 0 ? MTLSamplerMinMagFilterNearest
                                                : MTLSamplerMinMagFilterLinear;
        sd.mipFilter    = desc->mipmap_mode == 0 ? MTLSamplerMipFilterNearest
                                                  : MTLSamplerMipFilterLinear;
        sd.sAddressMode = mapAddressMode(desc->address_u);
        sd.tAddressMode = mapAddressMode(desc->address_v);
        sd.rAddressMode = mapAddressMode(desc->address_w);

        if (desc->enable_compare) {
            sd.compareFunction = mapCompareOp(desc->compare_op);
        }

        id<MTLSamplerState> sampler = [ctx->device newSamplerStateWithDescriptor:sd];
        if (!sampler) return 0;

        uint32_t id = ctx->next_sampler_id++;
        ctx->samplers[id] = sampler;
        return id;
    }
}

uint32_t guava_metal_rhi_create_shader_module(void* raw,
                                              uint32_t stage,
                                              uint32_t format,
                                              const uint8_t* code,
                                              uint32_t code_len,
                                              const char* entry_point) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        id<MTLLibrary> lib = nil;

        if (format == 2) {  // MSL source
            NSString* src = [[NSString alloc] initWithBytes:code
                                                     length:code_len
                                                   encoding:NSUTF8StringEncoding];
            NSError* err = nil;
            lib = [ctx->device newLibraryWithSource:src options:nil error:&err];
            if (!lib) {
                fprintf(stderr, "[GuavaMetal] MSL compile error: %s\n",
                        err ? [[err localizedDescription] UTF8String] : "unknown");
                return 0;
            }
        } else if (format == 0) {  // SPIRV — needs SPIRV-Cross, stub for now
            fprintf(stderr, "[GuavaMetal] SPIRV shader loading not yet implemented\n");
            return 0;
        } else {
            fprintf(stderr, "[GuavaMetal] Unsupported shader format: %u\n", format);
            return 0;
        }

        NSString* ep = [NSString stringWithUTF8String:entry_point];
        id<MTLFunction> func = [lib newFunctionWithName:ep];
        if (!func) {
            fprintf(stderr, "[GuavaMetal] Function '%s' not found in library\n",
                    entry_point);
            return 0;
        }

        uint32_t id = ctx->next_shader_id++;
        ctx->shader_functions[id] = func;
        ctx->shader_libraries[id] = lib;
        return id;
    }
}

uint32_t guava_metal_rhi_create_graphics_pipeline(
    void* raw, const GuavaMetalGraphicsPipelineDesc* desc,
    const GuavaMetalVertexAttribute* attrs,
    const GuavaMetalVertexBufferLayout* buf_layouts) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        auto vit = ctx->shader_functions.find(desc->vertex_shader_id);
        if (vit == ctx->shader_functions.end()) {
            fprintf(stderr, "[GuavaMetal] Graphics pipeline creation: shader not found\n");
            return 0;
        }
        id<MTLFunction> fragment_function = nil;
        if (desc->fragment_shader_id != 0) {
            auto fit = ctx->shader_functions.find(desc->fragment_shader_id);
            if (fit == ctx->shader_functions.end()) {
                fprintf(stderr, "[GuavaMetal] Graphics pipeline creation: shader not found\n");
                return 0;
            }
            fragment_function = fit->second;
        }

        MTLRenderPipelineDescriptor* pd =
            [[MTLRenderPipelineDescriptor alloc] init];
        pd.vertexFunction   = vit->second;
        pd.fragmentFunction = fragment_function;
        if (desc->color_format != 0) {
            pd.colorAttachments[0].pixelFormat = mapPixelFormat(desc->color_format);
        } else {
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatInvalid;
        }

        // ── Blend state ───────────────────────────────────────────────
        if (desc->blend_enabled && desc->color_format != 0) {
            pd.colorAttachments[0].blendingEnabled             = YES;
            pd.colorAttachments[0].sourceRGBBlendFactor        = mapBlendFactor(desc->src_color_blend);
            pd.colorAttachments[0].destinationRGBBlendFactor   = mapBlendFactor(desc->dst_color_blend);
            pd.colorAttachments[0].rgbBlendOperation           = mapBlendOp(desc->color_blend_op);
            pd.colorAttachments[0].sourceAlphaBlendFactor      = mapBlendFactor(desc->src_alpha_blend);
            pd.colorAttachments[0].destinationAlphaBlendFactor = mapBlendFactor(desc->dst_alpha_blend);
            pd.colorAttachments[0].alphaBlendOperation         = mapBlendOp(desc->alpha_blend_op);
        }

        if (desc->depth_format != 0) {
            pd.depthAttachmentPixelFormat = mapPixelFormat(desc->depth_format);
        }

        // ── Vertex descriptor ─────────────────────────────────────────
        if (desc->vertex_attr_count > 0 && attrs && buf_layouts) {
            MTLVertexDescriptor* vd = [[MTLVertexDescriptor alloc] init];

            for (uint32_t i = 0; i < desc->vertex_attr_count; i++) {
                vd.attributes[attrs[i].location].format =
                    mapVertexFormat(attrs[i].format);
                vd.attributes[attrs[i].location].offset = attrs[i].offset;
                vd.attributes[attrs[i].location].bufferIndex =
                    kVertexBufferBaseIndex + attrs[i].buffer_index;
            }

            for (uint32_t i = 0; i < desc->vertex_buffer_layout_count; i++) {
                vd.layouts[kVertexBufferBaseIndex + i].stride =
                    buf_layouts[i].stride;
                vd.layouts[kVertexBufferBaseIndex + i].stepFunction =
                    (buf_layouts[i].step_rate == 0)
                        ? MTLVertexStepFunctionPerVertex
                        : MTLVertexStepFunctionPerInstance;
                vd.layouts[kVertexBufferBaseIndex + i].stepRate = 1;
            }

            pd.vertexDescriptor = vd;
        }

        NSError* err = nil;
        id<MTLRenderPipelineState> pso =
            [ctx->device newRenderPipelineStateWithDescriptor:pd error:&err];
        if (!pso) {
            fprintf(stderr, "[GuavaMetal] Graphics pipeline error: %s\n",
                    err ? [[err localizedDescription] UTF8String] : "unknown");
            return 0;
        }

        uint32_t pipe_id = ctx->next_gfx_pipe_id++;
        ctx->gfx_pipelines[pipe_id] = pso;
        ctx->pipeline_primitives[pipe_id] = mapPrimitive(desc->primitive);

        // ── Depth/stencil state (paired with this pipeline) ───────────
        if (desc->depth_format != 0) {
            MTLDepthStencilDescriptor* dsd =
                [[MTLDepthStencilDescriptor alloc] init];
            dsd.depthCompareFunction = mapCompareOp(desc->depth_compare_op);
            dsd.depthWriteEnabled = (desc->depth_write_enabled != 0);
            id<MTLDepthStencilState> dss =
                [ctx->device newDepthStencilStateWithDescriptor:dsd];
            if (dss) {
                ctx->depth_stencil_states[pipe_id] = dss;
            }
        }

        return pipe_id;
    }
}

uint32_t guava_metal_rhi_create_compute_pipeline(void* raw,
                                                  uint32_t shader_id) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        auto it = ctx->shader_functions.find(shader_id);
        if (it == ctx->shader_functions.end()) {
            fprintf(stderr, "[GuavaMetal] Compute pipeline: shader %u not found\n",
                    shader_id);
            return 0;
        }

        NSError* err = nil;
        id<MTLComputePipelineState> pso =
            [ctx->device newComputePipelineStateWithFunction:it->second
                                                      error:&err];
        if (!pso) {
            fprintf(stderr, "[GuavaMetal] Compute pipeline error: %s\n",
                    err ? [[err localizedDescription] UTF8String] : "unknown");
            return 0;
        }

        uint32_t id = ctx->next_cmp_pipe_id++;
        ctx->cmp_pipelines[id] = pso;
        return id;
    }
}

// ---------------------------------------------------------------------------
// Resource destruction
// ---------------------------------------------------------------------------

void guava_metal_rhi_destroy_buffer(void* raw, uint32_t buffer_id) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    ctx->buffers.erase(buffer_id);
}

void guava_metal_rhi_destroy_texture(void* raw, uint32_t texture_id) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    ctx->textures.erase(texture_id);
    // Release backing IOSurface if this was an IOSurface-backed texture
    auto it = ctx->iosurfaces.find(texture_id);
    if (it != ctx->iosurfaces.end()) {
        CFRelease(it->second);
        ctx->iosurfaces.erase(it);
    }
}

void guava_metal_rhi_destroy_sampler(void* raw, uint32_t sampler_id) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    ctx->samplers.erase(sampler_id);
}

void guava_metal_rhi_destroy_graphics_pipeline(void* raw, uint32_t id) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    ctx->gfx_pipelines.erase(id);
    ctx->depth_stencil_states.erase(id);
    ctx->pipeline_primitives.erase(id);
}

void guava_metal_rhi_destroy_compute_pipeline(void* raw, uint32_t id) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    ctx->cmp_pipelines.erase(id);
}

// ---------------------------------------------------------------------------
// Data upload
// ---------------------------------------------------------------------------

bool guava_metal_rhi_upload_buffer_data(void* raw, uint32_t buffer_id,
                                        uint64_t offset,
                                        const uint8_t* data, uint64_t size) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    auto it = ctx->buffers.find(buffer_id);
    if (it == ctx->buffers.end()) return false;

    id<MTLBuffer> buf = it->second;
    if (offset + size > buf.length) return false;

    memcpy(static_cast<uint8_t*>(buf.contents) + offset, data, (size_t)size);
    return true;
}

bool guava_metal_rhi_upload_texture_data(void* raw, uint32_t texture_id,
                                         const uint8_t* data, uint64_t size,
                                         uint32_t width, uint32_t height,
                                         uint32_t bytes_per_row) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
        auto it = ctx->textures.find(texture_id);
        if (it == ctx->textures.end()) return false;

        id<MTLTexture> tex = it->second;

        // Use a staging buffer + blit encoder for non-shared textures
        id<MTLBuffer> staging = [ctx->device newBufferWithBytes:data
                                                        length:(NSUInteger)size
                                                       options:MTLResourceStorageModeShared];
        if (!staging) return false;

        id<MTLCommandBuffer> cmdBuf = [ctx->graphics_queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
        [blit copyFromBuffer:staging
                sourceOffset:0
           sourceBytesPerRow:bytes_per_row
         sourceBytesPerImage:(NSUInteger)(bytes_per_row * height)
                  sourceSize:MTLSizeMake(width, height, 1)
                   toTexture:tex
            destinationSlice:0
            destinationLevel:0
           destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        [cmdBuf commit];
        [cmdBuf waitUntilCompleted];
        return true;
    }
}

bool guava_metal_rhi_read_texture_data(void* raw, uint32_t texture_id,
                                                                             uint32_t width, uint32_t height,
                                                                             uint32_t bytes_per_row,
                                                                             uint8_t* out_data, uint64_t out_size) {
        @autoreleasepool {
                auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
                auto it = ctx->textures.find(texture_id);
                if (it == ctx->textures.end()) return false;
                if (!out_data) return false;

                const uint64_t needed = (uint64_t)bytes_per_row * (uint64_t)height;
                if (out_size < needed) return false;

                id<MTLTexture> tex = it->second;
                id<MTLBuffer> staging = [ctx->device newBufferWithLength:(NSUInteger)needed
                                                                                                                    options:MTLResourceStorageModeShared];
                if (!staging) return false;

                id<MTLCommandBuffer> cmdBuf = [ctx->graphics_queue commandBuffer];
                id<MTLBlitCommandEncoder> blit = [cmdBuf blitCommandEncoder];
                [blit copyFromTexture:tex
                                    sourceSlice:0
                                    sourceLevel:0
                                 sourceOrigin:MTLOriginMake(0, 0, 0)
                                     sourceSize:MTLSizeMake(width, height, 1)
                                         toBuffer:staging
                        destinationOffset:0
             destinationBytesPerRow:bytes_per_row
         destinationBytesPerImage:(NSUInteger)needed];
                [blit endEncoding];
                [cmdBuf commit];
                [cmdBuf waitUntilCompleted];

                memcpy(out_data, [staging contents], (size_t)needed);
                return true;
        }
}

void* guava_metal_rhi_get_mtl_device(void* raw) {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
        return (__bridge void*)ctx->device;
}

void* guava_metal_rhi_get_texture_handle(void* raw, uint32_t texture_id) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    auto it = ctx->textures.find(texture_id);
    if (it == ctx->textures.end()) {
        return nullptr;
    }
    return (__bridge void*)it->second;
}

// ---------------------------------------------------------------------------
// Binding set registration
// ---------------------------------------------------------------------------

void guava_metal_rhi_register_binding_set(void* raw, uint32_t set_id,
                                          const GuavaMetalBindingEntry* entries,
                                          uint32_t count) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    BindingSetData bsd;
    bsd.entries.assign(entries, entries + count);
    ctx->binding_sets[set_id] = std::move(bsd);
}

// ---------------------------------------------------------------------------
// Command submission — decode and translate to Metal
// ---------------------------------------------------------------------------

// Mini decoder: reads typed data from the serialized command bytes
struct CmdDecoder {
    const uint8_t* data;
    uint32_t       len;
    uint32_t       cursor;

    bool hasMore() const { return cursor < len; }

    uint8_t readU8() {
        if (cursor >= len) return 0xFF;
        return data[cursor++];
    }

    template <typename T>
    T read() {
        T val{};
        if (cursor + sizeof(T) <= len) {
            memcpy(&val, data + cursor, sizeof(T));
            cursor += sizeof(T);
        }
        return val;
    }

    const uint8_t* peek(uint32_t n) const {
        if (cursor + n > len) return nullptr;
        return data + cursor;
    }

    void skip(uint32_t n) {
        cursor = std::min(cursor + n, len);
    }
};

// Apply a registered binding set to the current render encoder
static void applyBindingSetRender(GuavaMetalRhiContext* ctx,
                                  id<MTLRenderCommandEncoder> enc,
                                  uint32_t pipeline_slot,
                                  uint32_t set_id) {
    (void)pipeline_slot;
    auto it = ctx->binding_sets.find(set_id);
    if (it == ctx->binding_sets.end()) return;

    for (auto& e : it->second.entries) {
        // Zig RHI interleaves texture (even slots) and sampler (odd slots) in
        // createBindGroup.  Metal has independent index spaces for textures,
        // samplers, and buffers.  spirv-cross --msl maps GLSL binding N to
        // texture(N) and sampler(N).  So we remap: for textures/samplers
        // created via createBindGroup (interleaved), Metal index = slot / 2.
        // Buffers and storage resources use the slot directly.
        uint32_t mtl_index = e.slot;
        // For texture/sampler created via createBindGroup's interleaved scheme,
        // remap to the correct Metal index (slot/2).
        if (e.resource_type <= 2) { // sampler(0), texture(1), storage_texture(2)
            mtl_index = e.slot / 2;
        }

        switch (e.resource_type) {
            case 3: { // uniform_buffer
                auto bit = ctx->buffers.find(e.resource_id);
                if (bit == ctx->buffers.end()) break;
                if (e.stage == 0) // vertex
                    [enc setVertexBuffer:bit->second offset:0 atIndex:mtl_index];
                else // fragment
                    [enc setFragmentBuffer:bit->second offset:0 atIndex:mtl_index];
                break;
            }
            case 4: { // storage_buffer
                auto bit = ctx->buffers.find(e.resource_id);
                if (bit == ctx->buffers.end()) break;
                if (e.stage == 0)
                    [enc setVertexBuffer:bit->second offset:0 atIndex:mtl_index];
                else
                    [enc setFragmentBuffer:bit->second offset:0 atIndex:mtl_index];
                break;
            }
            case 1: { // texture
                auto tit = ctx->textures.find(e.resource_id);
                if (tit == ctx->textures.end()) break;
                if (e.stage == 0)
                    [enc setVertexTexture:tit->second atIndex:mtl_index];
                else
                    [enc setFragmentTexture:tit->second atIndex:mtl_index];
                break;
            }
            case 2: { // storage_texture
                auto tit = ctx->textures.find(e.resource_id);
                if (tit == ctx->textures.end()) break;
                if (e.stage == 0)
                    [enc setVertexTexture:tit->second atIndex:mtl_index];
                else
                    [enc setFragmentTexture:tit->second atIndex:mtl_index];
                break;
            }
            case 0: { // sampler
                auto sit = ctx->samplers.find(e.resource_id);
                if (sit == ctx->samplers.end()) break;
                if (e.stage == 0)
                    [enc setVertexSamplerState:sit->second atIndex:mtl_index];
                else
                    [enc setFragmentSamplerState:sit->second atIndex:mtl_index];
                break;
            }
            default: break;
        }
    }
}

// Apply a registered binding set to the current compute encoder
static void applyBindingSetCompute(GuavaMetalRhiContext* ctx,
                                   id<MTLComputeCommandEncoder> enc,
                                   uint32_t pipeline_slot,
                                   uint32_t set_id) {
    (void)pipeline_slot;
    auto it = ctx->binding_sets.find(set_id);
    if (it == ctx->binding_sets.end()) return;

    for (auto& e : it->second.entries) {
        uint32_t mtl_index = e.slot;
        if (e.resource_type <= 2) {
            mtl_index = e.slot / 2;
        }

        switch (e.resource_type) {
            case 3: case 4: { // uniform/storage buffer
                auto bit = ctx->buffers.find(e.resource_id);
                if (bit != ctx->buffers.end())
                    [enc setBuffer:bit->second offset:0 atIndex:mtl_index];
                break;
            }
            case 1: case 2: { // texture / storage_texture
                auto tit = ctx->textures.find(e.resource_id);
                if (tit != ctx->textures.end())
                    [enc setTexture:tit->second atIndex:mtl_index];
                break;
            }
            case 0: { // sampler
                auto sit = ctx->samplers.find(e.resource_id);
                if (sit != ctx->samplers.end())
                    [enc setSamplerState:sit->second atIndex:mtl_index];
                break;
            }
            default: break;
        }
    }
}

bool guava_metal_rhi_submit(void* raw, uint32_t queue_class,
                            const uint8_t* cmd_bytes, uint32_t cmd_len,
                            const GuavaMetalSubmitDesc* submit_desc) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
        const GuavaMetalSubmitDesc empty_desc = {};
        if (!submit_desc) submit_desc = &empty_desc;

        id<MTLCommandQueue> queue = (queue_class == 1)
            ? ctx->compute_queue : ctx->graphics_queue;

        id<MTLCommandBuffer> mtlCmd = [queue commandBuffer];
        if (!mtlCmd) return false;

        for (uint32_t i = 0; i < submit_desc->wait_count; ++i) {
            const GuavaMetalTimelineSemaphore wait = submit_desc->wait_semaphores[i];
            id<MTLSharedEvent> event = findOrCreateSharedEvent(ctx, wait.id);
            if (!event) return false;
            if (@available(macOS 10.14, iOS 12.0, *)) {
                [mtlCmd encodeWaitForEvent:event value:wait.value];
            }
        }

        CmdDecoder dec{cmd_bytes, cmd_len, 0};

        id<MTLRenderCommandEncoder>  renderEnc  = nil;
        id<MTLComputeCommandEncoder> computeEnc = nil;
        MTLRenderPassDescriptor* current_rpd = nil;

        // Remembered index buffer state for draw_indexed
        id<MTLBuffer> current_index_buffer = nil;
        uint64_t      current_index_offset = 0;
        MTLIndexType   current_index_type  = MTLIndexTypeUInt32;
        MTLPrimitiveType current_primitive = MTLPrimitiveTypeTriangle;

        while (dec.hasMore()) {
            uint8_t opcode = dec.readU8();

            switch (static_cast<RhiOpCode>(opcode)) {
            case OP_BEGIN_RENDER_PASS: {
                // End any still-open encoder to avoid Metal assertion
                if (renderEnc)  { [renderEnc endEncoding];  renderEnc  = nil; }
                if (computeEnc) { [computeEnc endEncoding]; computeEnc = nil; }

                auto cmd = dec.read<CmdBeginRenderPass>();
                MTLRenderPassDescriptor* rpd =
                    [MTLRenderPassDescriptor renderPassDescriptor];

                // Look up color target texture
                auto cit = ctx->textures.find(cmd.color_target_id);
                if (cit != ctx->textures.end()) {
                    rpd.colorAttachments[0].texture = cit->second;
                    rpd.colorAttachments[0].loadAction =
                        (cmd.clear_mask & 0x1) ? MTLLoadActionClear
                                               : MTLLoadActionLoad;
                    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
                    rpd.colorAttachments[0].clearColor =
                        MTLClearColorMake(cmd.clear_r, cmd.clear_g, cmd.clear_b, cmd.clear_a);
                }

                // Look up depth target texture
                auto dit = ctx->textures.find(cmd.depth_target_id);
                if (dit != ctx->textures.end()) {
                    rpd.depthAttachment.texture = dit->second;
                    rpd.depthAttachment.loadAction =
                        (cmd.clear_mask & 0x2) ? MTLLoadActionClear
                                               : MTLLoadActionLoad;
                    rpd.depthAttachment.storeAction = MTLStoreActionStore;
                    rpd.depthAttachment.clearDepth = cmd.clear_depth;
                }

                renderEnc = [mtlCmd renderCommandEncoderWithDescriptor:rpd];
                current_rpd = rpd;
                break;
            }
            case OP_END_RENDER_PASS: {
                if (renderEnc) {
                    [renderEnc endEncoding];
                    renderEnc = nil;
                }
                current_rpd = nil;
                current_index_buffer = nil;
                break;
            }
            case OP_BEGIN_COMPUTE_PASS: {
                // End any still-open encoder to avoid Metal assertion
                if (renderEnc)  { [renderEnc endEncoding];  renderEnc  = nil; }
                if (computeEnc) { [computeEnc endEncoding]; computeEnc = nil; }

                dec.read<CmdBeginComputePass>(); // consume reserved field
                computeEnc = [mtlCmd computeCommandEncoder];
                break;
            }
            case OP_END_COMPUTE_PASS: {
                if (computeEnc) {
                    [computeEnc endEncoding];
                    computeEnc = nil;
                }
                break;
            }
            case OP_BEGIN_COPY_PASS: {
                dec.read<CmdBeginCopyPass>(); // consume reserved
                // Blit encoder — TODO when copy pass is needed
                break;
            }
            case OP_END_COPY_PASS: {
                break;
            }
            case OP_SET_PIPELINE: {
                auto cmd = dec.read<CmdSetPipeline>();
                if (renderEnc) {
                    auto it = ctx->gfx_pipelines.find(cmd.pipeline_id);
                    if (it != ctx->gfx_pipelines.end())
                        [renderEnc setRenderPipelineState:it->second];
                    auto pit = ctx->pipeline_primitives.find(cmd.pipeline_id);
                    if (pit != ctx->pipeline_primitives.end())
                        current_primitive = pit->second;
                    // Also apply the paired depth/stencil state
                    auto dit = ctx->depth_stencil_states.find(cmd.pipeline_id);
                    if (dit != ctx->depth_stencil_states.end())
                        [renderEnc setDepthStencilState:dit->second];
                } else if (computeEnc) {
                    auto it = ctx->cmp_pipelines.find(cmd.pipeline_id);
                    if (it != ctx->cmp_pipelines.end())
                        [computeEnc setComputePipelineState:it->second];
                }
                break;
            }
            case OP_SET_BINDING_SET: {
                auto cmd = dec.read<CmdSetBindingSet>();
                if (renderEnc) {
                    applyBindingSetRender(ctx, renderEnc, cmd.slot, cmd.set_id);
                } else if (computeEnc) {
                    applyBindingSetCompute(ctx, computeEnc, cmd.slot, cmd.set_id);
                }
                break;
            }
            case OP_SET_VERTEX_BUFFER: {
                auto cmd = dec.read<CmdSetVertexBuffer>();
                if (renderEnc) {
                    auto it = ctx->buffers.find(cmd.buffer_id);
                    if (it != ctx->buffers.end()) {
                        // Vertex buffers use a high base index to avoid
                        // clashing with uniform buffer slots
                        [renderEnc setVertexBuffer:it->second
                                            offset:(NSUInteger)cmd.offset
                                           atIndex:30 + cmd.slot];
                    }
                }
                break;
            }
            case OP_SET_INDEX_BUFFER: {
                auto cmd = dec.read<CmdSetIndexBuffer>();
                auto it = ctx->buffers.find(cmd.buffer_id);
                if (it != ctx->buffers.end()) {
                    current_index_buffer = it->second;
                    current_index_offset = cmd.offset;
                    current_index_type = (cmd.format == 0)
                        ? MTLIndexTypeUInt16 : MTLIndexTypeUInt32;
                }
                break;
            }
            case OP_DRAW_INDEXED: {
                auto cmd = dec.read<CmdDrawIndexed>();
                if (renderEnc && current_index_buffer) {
                    uint32_t idx_size = (current_index_type == MTLIndexTypeUInt16)
                                            ? 2 : 4;
                    [renderEnc drawIndexedPrimitives:current_primitive
                                         indexCount:cmd.index_count
                                          indexType:current_index_type
                                        indexBuffer:current_index_buffer
                                  indexBufferOffset:current_index_offset +
                                                    cmd.first_index * idx_size
                                      instanceCount:cmd.instance_count
                                         baseVertex:cmd.vertex_offset
                                       baseInstance:cmd.first_instance];
                }
                break;
            }
            case OP_DRAW_INDIRECT: {
                auto cmd = dec.read<CmdDrawIndirect>();
                if (renderEnc) {
                    auto it = ctx->buffers.find(cmd.buffer_id);
                    if (it != ctx->buffers.end()) {
                        // Metal indirect draw uses MTLDrawIndexedPrimitivesIndirectArguments
                        // For now, draw_count=1 indirect
                        [renderEnc drawPrimitives:current_primitive
                                   indirectBuffer:it->second
                             indirectBufferOffset:(NSUInteger)cmd.offset];
                    }
                }
                break;
            }
            case OP_DISPATCH: {
                auto cmd = dec.read<CmdDispatch>();
                if (computeEnc) {
                    MTLSize grid = MTLSizeMake(cmd.x, cmd.y, cmd.z);
                    MTLSize tg   = MTLSizeMake(8, 8, 1); // default workgroup
                    [computeEnc dispatchThreadgroups:grid
                               threadsPerThreadgroup:tg];
                }
                break;
            }
            case OP_DISPATCH_INDIRECT: {
                auto cmd = dec.read<CmdDispatchIndirect>();
                if (computeEnc) {
                    auto it = ctx->buffers.find(cmd.buffer_id);
                    if (it != ctx->buffers.end()) {
                        MTLSize tg = MTLSizeMake(8, 8, 1);
                        [computeEnc dispatchThreadgroupsWithIndirectBuffer:it->second
                                                      indirectBufferOffset:(NSUInteger)cmd.offset
                                                     threadsPerThreadgroup:tg];
                    }
                }
                break;
            }
            case OP_PIPELINE_BARRIER: {
                dec.read<CmdPipelineBarrier>(); // state tracking only for now
                break;
            }
            case OP_DRAW: {
                auto cmd = dec.read<CmdDraw>();
                if (renderEnc) {
                    [renderEnc drawPrimitives:current_primitive
                                 vertexStart:cmd.first_vertex
                                 vertexCount:cmd.vertex_count
                               instanceCount:cmd.instance_count
                                baseInstance:cmd.first_instance];
                }
                break;
            }
            case OP_PUSH_UNIFORM: {
                auto hdr = dec.read<CmdPushUniform>();
                const uint8_t* data = dec.peek(hdr.data_len);
                if (!data) { return false; }
                dec.skip(hdr.data_len);
                // Metal setVertexBytes/setFragmentBytes has a 4096-byte limit.
                // For larger data, fall back to a temporary buffer.
                static const NSUInteger kMaxInlineBytes = 4096;
                if (renderEnc) {
                    if (hdr.data_len <= kMaxInlineBytes) {
                        if (hdr.stage == 0) {
                            [renderEnc setVertexBytes:data length:hdr.data_len atIndex:hdr.slot];
                        } else if (hdr.stage == 1) {
                            [renderEnc setFragmentBytes:data length:hdr.data_len atIndex:hdr.slot];
                        }
                    } else {
                        id<MTLBuffer> tmpBuf = [ctx->device newBufferWithBytes:data
                                                                       length:hdr.data_len
                                                                      options:MTLResourceStorageModeShared];
                        if (hdr.stage == 0) {
                            [renderEnc setVertexBuffer:tmpBuf offset:0 atIndex:hdr.slot];
                        } else if (hdr.stage == 1) {
                            [renderEnc setFragmentBuffer:tmpBuf offset:0 atIndex:hdr.slot];
                        }
                    }
                } else if (computeEnc) {
                    if (hdr.data_len <= kMaxInlineBytes) {
                        [computeEnc setBytes:data length:hdr.data_len atIndex:hdr.slot];
                    } else {
                        id<MTLBuffer> tmpBuf = [ctx->device newBufferWithBytes:data
                                                                       length:hdr.data_len
                                                                      options:MTLResourceStorageModeShared];
                        [computeEnc setBuffer:tmpBuf offset:0 atIndex:hdr.slot];
                    }
                }
                break;
            }
            case OP_SET_VIEWPORT: {
                auto cmd = dec.read<CmdSetViewport>();
                if (renderEnc) {
                    MTLViewport vp = { cmd.x, cmd.y, cmd.w, cmd.h, cmd.min_depth, cmd.max_depth };
                    [renderEnc setViewport:vp];
                }
                break;
            }
            case OP_SET_SCISSOR: {
                auto cmd = dec.read<CmdSetScissor>();
                if (renderEnc) {
                    MTLScissorRect sr = { cmd.x, cmd.y, cmd.w, cmd.h };
                    [renderEnc setScissorRect:sr];
                }
                break;
            }
            default:
                fprintf(stderr, "[GuavaMetal] Unknown opcode: %u\n", opcode);
                return false;
            }
        }

        // End any still-open encoders
        if (renderEnc)  [renderEnc endEncoding];
        if (computeEnc) [computeEnc endEncoding];

        for (uint32_t i = 0; i < submit_desc->signal_count; ++i) {
            const GuavaMetalTimelineSemaphore signal = submit_desc->signal_semaphores[i];
            id<MTLSharedEvent> event = findOrCreateSharedEvent(ctx, signal.id);
            if (!event) return false;
            if (@available(macOS 10.14, iOS 12.0, *)) {
                [mtlCmd encodeSignalEvent:event value:signal.value];
            }
        }

        [mtlCmd commit];
        ctx->last_command_buffer = mtlCmd;
        return true;
    }
}

// ---------------------------------------------------------------------------
// Swapchain — real CAMetalLayer drawable acquisition
// ---------------------------------------------------------------------------

bool guava_metal_rhi_acquire_swapchain(void* raw,
                                       uint32_t* out_id,
                                       uint32_t* out_width,
                                       uint32_t* out_height) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        if (!ctx->metal_layer) {
            fprintf(stderr, "[GuavaMetal] acquire_swapchain: no CAMetalLayer configured\n");
            return false;
        }

        id<CAMetalDrawable> drawable = [ctx->metal_layer nextDrawable];
        if (!drawable) {
            fprintf(stderr, "[GuavaMetal] acquire_swapchain: nextDrawable returned nil\n");
            return false;
        }

        // Remove previous swapchain texture entry if any
        if (ctx->swapchain_texture_id != 0) {
            ctx->textures.erase(ctx->swapchain_texture_id);
        }

        // Register the drawable's texture in the texture map so render passes
        // can reference it by ID like any other texture.
        uint32_t tex_id = ctx->next_texture_id++;
        ctx->textures[tex_id] = drawable.texture;
        ctx->current_drawable = drawable;
        ctx->swapchain_texture_id = tex_id;

        CGSize sz = ctx->metal_layer.drawableSize;
        *out_id    = tex_id;
        *out_width = (uint32_t)sz.width;
        *out_height = (uint32_t)sz.height;
        return true;
    }
}

// ---------------------------------------------------------------------------
// IOSurface-backed textures — for cross-process GPU texture sharing
// ---------------------------------------------------------------------------

uint32_t guava_metal_rhi_create_iosurface_texture(void* raw,
                                                   uint32_t width,
                                                   uint32_t height,
                                                   uint32_t format,
                                                   uint32_t usage_bits,
                                                   uint32_t* out_surface_id,
                                                   const char* label) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        // Determine bytes-per-pixel from the RHI format enum ordinal
        uint32_t bpe = 4; // default BGRA8
        MTLPixelFormat mtl_fmt = mapPixelFormat(format);
        switch (mtl_fmt) {
            case MTLPixelFormatR8Unorm:        bpe = 1; break;
            case MTLPixelFormatRGBA8Unorm:
            case MTLPixelFormatBGRA8Unorm:
            case MTLPixelFormatRGBA8Unorm_sRGB:
            case MTLPixelFormatBGRA8Unorm_sRGB: bpe = 4; break;
            case MTLPixelFormatRGBA16Float:     bpe = 8; break;
            case MTLPixelFormatRGBA32Float:     bpe = 16; break;
            default:                            bpe = 4; break;
        }

        // Metal requires IOSurface bytesPerRow to be aligned to 16 bytes.
        uint32_t rawBytesPerRow = width * bpe;
        uint32_t alignedBytesPerRow = (rawBytesPerRow + 15) & ~15u;

        NSDictionary* props = @{
            (id)kIOSurfaceWidth:           @(width),
            (id)kIOSurfaceHeight:          @(height),
            (id)kIOSurfaceBytesPerElement:  @(bpe),
            (id)kIOSurfaceBytesPerRow:      @(alignedBytesPerRow),
            (id)kIOSurfaceAllocSize:        @((uint64_t)alignedBytesPerRow * height),
            (id)kIOSurfacePixelFormat:      @((uint32_t)'BGRA'),
            (id)kIOSurfaceIsGlobal:         @YES, // Required for cross-process IOSurfaceLookup
        };
        IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (!surface) {
            fprintf(stderr, "[GuavaMetal] create_iosurface_texture: IOSurfaceCreate failed\n");
            if (out_surface_id) *out_surface_id = 0;
            return 0;
        }

        MTLTextureDescriptor* td = [[MTLTextureDescriptor alloc] init];
        td.pixelFormat      = mtl_fmt;
        td.width            = width;
        td.height           = height;
        td.storageMode      = MTLStorageModeShared; // required for IOSurface backing
        td.textureType      = MTLTextureType2D;

        MTLTextureUsage usage = 0;
        if (usage_bits & 0x01) usage |= MTLTextureUsageShaderRead;
        if (usage_bits & 0x02) usage |= MTLTextureUsageRenderTarget;
        if (usage_bits & 0x04) usage |= MTLTextureUsageRenderTarget;
        if (usage_bits & 0x08) usage |= MTLTextureUsageShaderRead;
        if (usage_bits & 0x10) usage |= MTLTextureUsageShaderWrite;
        td.usage = usage;

        id<MTLTexture> tex = [ctx->device newTextureWithDescriptor:td
                                                         iosurface:surface
                                                             plane:0];
        if (!tex) {
            fprintf(stderr, "[GuavaMetal] create_iosurface_texture: newTextureWithDescriptor:iosurface failed\n");
            CFRelease(surface);
            if (out_surface_id) *out_surface_id = 0;
            return 0;
        }

        if (label) tex.label = [NSString stringWithUTF8String:label];

        uint32_t tex_id = ctx->next_texture_id++;
        ctx->textures[tex_id]   = tex;
        ctx->iosurfaces[tex_id] = surface; // prevent premature deallocation

        IOSurfaceID sid = IOSurfaceGetID(surface);
        if (out_surface_id) *out_surface_id = sid;
        return tex_id;
    }
}

bool guava_metal_rhi_present(void* raw, uint32_t /*swapchain_id*/) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);

        if (!ctx->current_drawable) {
            fprintf(stderr, "[GuavaMetal] present: no current drawable\n");
            return false;
        }

        [ctx->current_drawable present];
        ctx->current_drawable = nil;
        return true;
    }
}

// ---------------------------------------------------------------------------
// Debug
// ---------------------------------------------------------------------------

const char* guava_metal_rhi_get_device_name(void* raw) {
    auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
    return [[ctx->device name] UTF8String];
}

// ---------------------------------------------------------------------------
// GPU synchronization — wait for last committed command buffer to complete
// ---------------------------------------------------------------------------

void guava_metal_rhi_wait_for_gpu(void* raw) {
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
        if (ctx->last_command_buffer) {
            [ctx->last_command_buffer waitUntilCompleted];
            ctx->last_command_buffer = nil;
        }
    }
}

// ---------------------------------------------------------------------------
// IOSurface staging copy — CPU memcpy from render surface to staging surface
// ---------------------------------------------------------------------------
// Lazily creates a staging IOSurface matching the source dimensions.
// After waitForGpu(), the render IOSurface has stable pixels.  We copy them
// to a separate staging IOSurface that the editor addon reads from, so the
// GPU can start the next frame without racing with the addon's readback.

static IOSurfaceRef g_staging_surface = nullptr;
static uint32_t     g_staging_surface_id = 0;
static uint32_t     g_staging_width  = 0;
static uint32_t     g_staging_height = 0;

uint32_t guava_metal_rhi_copy_to_staging(void* raw, uint32_t src_texture_id) {
    if (!raw) return 0;
    @autoreleasepool {
        auto* ctx = static_cast<GuavaMetalRhiContext*>(raw);
        if (!ctx) return 0;

        // Find the source IOSurface
        auto it = ctx->iosurfaces.find(src_texture_id);
        if (it == ctx->iosurfaces.end()) {
            fprintf(stderr, "[GuavaMetal] copy_to_staging: texture %u not in iosurfaces map\n", src_texture_id);
            return 0;
        }
        IOSurfaceRef src_surface = it->second;
        if (!src_surface) return 0;

        uint32_t width  = (uint32_t)IOSurfaceGetWidth(src_surface);
        uint32_t height = (uint32_t)IOSurfaceGetHeight(src_surface);
        size_t src_bpr  = IOSurfaceGetBytesPerRow(src_surface);
        if (width == 0 || height == 0) return 0;

        // (Re)create staging surface if dimensions changed
        if (!g_staging_surface || g_staging_width != width || g_staging_height != height) {
            if (g_staging_surface) {
                CFRelease(g_staging_surface);
                g_staging_surface = nullptr;
            }
            uint32_t bpe = 4;
            uint32_t alignedBpr = ((width * bpe) + 15) & ~15u;
            NSDictionary* props = @{
                (id)kIOSurfaceWidth:           @(width),
                (id)kIOSurfaceHeight:          @(height),
                (id)kIOSurfaceBytesPerElement:  @(bpe),
                (id)kIOSurfaceBytesPerRow:      @(alignedBpr),
                (id)kIOSurfaceAllocSize:        @((uint64_t)alignedBpr * height),
                (id)kIOSurfacePixelFormat:      @((uint32_t)'BGRA'),
                (id)kIOSurfaceIsGlobal:         @YES,
            };
            g_staging_surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
            if (!g_staging_surface) return 0;
            g_staging_surface_id = IOSurfaceGetID(g_staging_surface);
            g_staging_width  = width;
            g_staging_height = height;
        }

        // CPU copy: lock both surfaces, memcpy, unlock
        kern_return_t kr1 = IOSurfaceLock(src_surface, kIOSurfaceLockReadOnly, nullptr);
        if (kr1 != kIOReturnSuccess) return g_staging_surface_id;

        kern_return_t kr2 = IOSurfaceLock(g_staging_surface, 0, nullptr); // exclusive write
        if (kr2 != kIOReturnSuccess) {
            IOSurfaceUnlock(src_surface, kIOSurfaceLockReadOnly, nullptr);
            return g_staging_surface_id;
        }

        const uint8_t* src = static_cast<const uint8_t*>(IOSurfaceGetBaseAddress(src_surface));
        uint8_t* dst = static_cast<uint8_t*>(IOSurfaceGetBaseAddress(g_staging_surface));
        size_t dst_bpr = IOSurfaceGetBytesPerRow(g_staging_surface);

        if (src_bpr == dst_bpr) {
            std::memcpy(dst, src, src_bpr * height);
        } else {
            size_t row = std::min(src_bpr, dst_bpr);
            for (uint32_t y = 0; y < height; y++) {
                std::memcpy(dst + y * dst_bpr, src + y * src_bpr, row);
            }
        }

        IOSurfaceUnlock(g_staging_surface, 0, nullptr);
        IOSurfaceUnlock(src_surface, kIOSurfaceLockReadOnly, nullptr);

        return g_staging_surface_id;
    }
}
