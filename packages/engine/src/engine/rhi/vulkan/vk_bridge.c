// ---------------------------------------------------------------------------
// Vulkan RHI Bridge — real Vulkan API implementation
//
// This is the C-side bridge that the Zig VulkanDevice calls via extern.
// It owns all VkDevice/VkBuffer/VkImage/VkPipeline objects and manages
// their lifecycle. Command buffer submission decodes the same byte-stream
// opcodes as the Metal bridge, translating them to Vulkan API calls.
// ---------------------------------------------------------------------------

#include "vk_bridge.h"
#include "../../platform/window_vulkan_sdl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

// POSIX shared memory (Linux shared texture support)
#if defined(__linux__)
#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
#endif

// Vulkan headers — SDK must be installed; build.zig links libvulkan
#include <vulkan/vulkan.h>

// ---------------------------------------------------------------------------
// Command buffer opcodes — must match command_buffer.zig OpCode enum(u8)
// ---------------------------------------------------------------------------
enum GuavaOpCode {
    OP_BEGIN_RENDER_PASS   = 0,
    OP_END_RENDER_PASS     = 1,
    OP_BEGIN_COMPUTE_PASS  = 2,
    OP_END_COMPUTE_PASS    = 3,
    OP_BEGIN_COPY_PASS     = 4,
    OP_END_COPY_PASS       = 5,
    OP_SET_BINDING_SET     = 6,
    OP_SET_VERTEX_BUFFER   = 7,
    OP_SET_INDEX_BUFFER    = 8,
    OP_SET_PIPELINE        = 9,
    OP_DRAW_INDEXED        = 10,
    OP_DRAW_INDIRECT       = 11,
    OP_DISPATCH            = 12,
    OP_DISPATCH_INDIRECT   = 13,
    OP_PIPELINE_BARRIER    = 14,
    OP_DRAW                = 15,
    OP_PUSH_UNIFORM        = 16,
    OP_SET_VIEWPORT        = 17,
    OP_SET_SCISSOR         = 18,
};

// ---------------------------------------------------------------------------
// Command structs — must match extern structs in command_buffer.zig
// ---------------------------------------------------------------------------
#pragma pack(push, 1)
typedef struct { uint32_t color_target_id; uint32_t depth_target_id; uint32_t clear_mask; float clear_r, clear_g, clear_b, clear_a, clear_depth; } CmdBeginRenderPass;
typedef struct { uint32_t reserved; } CmdBeginComputePass;
typedef struct { uint32_t reserved; } CmdBeginCopyPass;
typedef struct { uint32_t slot; uint32_t set_id; } CmdSetBindingSet;
typedef struct { uint32_t slot; uint32_t buffer_id; uint32_t offset; } CmdSetVertexBuffer;
typedef struct { uint32_t buffer_id; uint32_t offset; uint32_t format; } CmdSetIndexBuffer;
typedef struct { uint32_t pipeline_id; } CmdSetPipeline;
typedef struct { uint32_t index_count; uint32_t instance_count; uint32_t first_index; int32_t vertex_offset; uint32_t first_instance; } CmdDrawIndexed;
typedef struct { uint32_t buffer_id; uint32_t offset; uint32_t draw_count; } CmdDrawIndirect;
typedef struct { uint32_t x; uint32_t y; uint32_t z; } CmdDispatch;
typedef struct { uint32_t buffer_id; uint32_t offset; } CmdDispatchIndirect;
typedef struct {
    uint32_t resource_id;
    uint32_t src_state;
    uint32_t dst_state;
    uint16_t subresource_base;
    uint16_t subresource_count;
    uint8_t resource_kind;
    uint8_t sync_action;
    uint8_t pass_scope;
    uint8_t src_queue;
    uint8_t dst_queue;
    uint8_t pad[3];
} CmdPipelineBarrier;
typedef struct { uint32_t vertex_count; uint32_t instance_count; uint32_t first_vertex; uint32_t first_instance; } CmdDraw;
typedef struct { uint8_t stage; uint8_t slot; uint16_t pad; uint32_t data_len; } CmdPushUniform;
typedef struct { float x; float y; float width; float height; float min_depth; float max_depth; } CmdSetViewport;
typedef struct { int32_t x; int32_t y; uint32_t width; uint32_t height; } CmdSetScissor;
#pragma pack(pop)

// ---------------------------------------------------------------------------
// Forward declarations for internal resource maps (simple dynamic arrays)
// Using simple C arrays with linear search for initial skeleton.
// Production code would use hash maps.
// ---------------------------------------------------------------------------

#define MAX_RESOURCES 4096

typedef struct {
    uint32_t id;
    VkBuffer buffer;
    VkDeviceMemory memory;
    VkDeviceSize size;
} BufferEntry;

typedef struct {
    uint32_t id;
    VkImage image;
    VkImageView view;
    VkDeviceMemory memory;
    uint32_t width, height, depth, layers, mip_levels;
    VkFormat format;
    VkImageLayout current_layout;
    bool is_swapchain_image; // swapchain images are not owned
} TextureEntry;

typedef struct {
    uint32_t id;
    VkSampler sampler;
} SamplerEntry;

typedef struct {
    uint32_t id;
    VkSemaphore semaphore;
} TimelineSemaphoreEntry;

typedef struct {
    uint32_t id;
    VkShaderModule module;
    uint32_t stage; // ShaderStage ordinal
    char entry_point[64];
} ShaderEntry;

typedef struct {
    uint32_t id;
    VkPipeline pipeline;
    VkPipelineLayout layout;
    VkRenderPass render_pass;
    uint32_t primitive; // PrimitiveType ordinal
} GfxPipelineEntry;

typedef struct {
    uint32_t id;
    VkPipeline pipeline;
    VkPipelineLayout layout;
} ComputePipelineEntry;

typedef struct {
    uint32_t id;
    uint32_t entry_count;
    GuavaVkBindingEntry entries[32]; // max 32 bindings per set
    VkDescriptorSetLayout layout;
    VkDescriptorSet descriptor_set;
} BindingSetData;

typedef struct {
    VkRenderPass render_pass;
    VkFormat color_format;
    VkFormat depth_format;
    uint32_t clear_mask;
} RenderPassCacheEntry;

typedef struct {
    VkFramebuffer framebuffer;
    VkRenderPass render_pass;
    VkImageView color_view;
    VkImageView depth_view;
    uint32_t width, height;
} FramebufferCacheEntry;

// Shared texture entry — tracks staging buffer + shm for cross-process readback
typedef struct {
    uint32_t texture_id;          // the GPU texture this is associated with
    VkBuffer staging_buffer;
    VkDeviceMemory staging_memory;
    uint32_t width, height;
    uint32_t bytes_per_pixel;
    uint64_t buffer_size;
    char shm_name[64];
#if defined(__linux__)
    int shm_fd;
    void* shm_ptr;                // mmap'd shared memory pointer
#endif
} SharedTextureEntry;

// ---------------------------------------------------------------------------
// Main bridge context — owns all Vulkan objects
// ---------------------------------------------------------------------------
typedef struct {
    // Core Vulkan objects
    VkInstance       instance;
    VkPhysicalDevice physical_device;
    VkDevice         device;
    VkQueue          graphics_queue;
    VkQueue          compute_queue;
    VkQueue          transfer_queue;
    uint32_t         graphics_family;
    uint32_t         compute_family;
    uint32_t         transfer_family;

    // Memory properties
    VkPhysicalDeviceMemoryProperties mem_properties;
    VkPhysicalDeviceProperties       device_properties;

    // Command pools
    VkCommandPool graphics_cmd_pool;
    VkCommandPool compute_cmd_pool;
    VkCommandPool transfer_cmd_pool;

    // Swapchain
    VkSurfaceKHR     surface;
    VkSwapchainKHR   swapchain;
    VkFormat          swapchain_format;
    VkExtent2D        swapchain_extent;
    uint32_t          swapchain_image_count;
    VkImage*          swapchain_images;
    VkImageView*      swapchain_image_views;
    uint32_t          current_swapchain_index;
    uint32_t          swapchain_texture_id; // RHI texture ID for current swapchain image
    VkSemaphore       image_available_semaphore;
    VkSemaphore       render_finished_semaphore;
    VkFence           in_flight_fence;
    bool              timeline_semaphores_supported;

    // Validation layers
    VkDebugUtilsMessengerEXT debug_messenger;
    bool validation_enabled;

    // Resource ID counters
    uint32_t next_buffer_id;
    uint32_t next_texture_id;
    uint32_t next_sampler_id;
    uint32_t next_shader_id;
    uint32_t next_gfx_pipe_id;
    uint32_t next_cmp_pipe_id;

    // Resource maps (simple linear arrays, sufficient for skeleton)
    BufferEntry          buffers[MAX_RESOURCES];
    uint32_t             buffer_count;
    TextureEntry         textures[MAX_RESOURCES];
    uint32_t             texture_count;
    SamplerEntry         samplers[MAX_RESOURCES];
    uint32_t             sampler_count;
    TimelineSemaphoreEntry timeline_semaphores[MAX_RESOURCES];
    uint32_t               timeline_semaphore_count;
    ShaderEntry          shaders[MAX_RESOURCES];
    uint32_t             shader_count;
    GfxPipelineEntry     gfx_pipelines[MAX_RESOURCES];
    uint32_t             gfx_pipeline_count;
    ComputePipelineEntry cmp_pipelines[MAX_RESOURCES];
    uint32_t             cmp_pipeline_count;
    BindingSetData       binding_sets[MAX_RESOURCES];
    uint32_t             binding_set_count;

    // Descriptor pool for binding sets
    VkDescriptorPool descriptor_pool;

    // Render pass cache (keyed by format + clear mode)
    RenderPassCacheEntry rp_cache[256];
    uint32_t rp_cache_count;

    // Framebuffer cache
    FramebufferCacheEntry fb_cache[1024];
    uint32_t fb_cache_count;

    // Shared textures (cross-process viewport readback)
    SharedTextureEntry shared_textures[16]; // small — only a few viewports
    uint32_t shared_texture_count;
} GuavaVkContext;

// ---------------------------------------------------------------------------
// Internal lookup helpers
// ---------------------------------------------------------------------------
static BufferEntry* find_buffer(GuavaVkContext* ctx, uint32_t id) {
    for (uint32_t i = 0; i < ctx->buffer_count; i++)
        if (ctx->buffers[i].id == id) return &ctx->buffers[i];
    return NULL;
}

static TextureEntry* find_texture(GuavaVkContext* ctx, uint32_t id) {
    for (uint32_t i = 0; i < ctx->texture_count; i++)
        if (ctx->textures[i].id == id) return &ctx->textures[i];
    return NULL;
}

static SamplerEntry* find_sampler(GuavaVkContext* ctx, uint32_t id) {
    for (uint32_t i = 0; i < ctx->sampler_count; i++)
        if (ctx->samplers[i].id == id) return &ctx->samplers[i];
    return NULL;
}

static TimelineSemaphoreEntry* find_timeline_semaphore(GuavaVkContext* ctx, uint32_t id) {
    for (uint32_t i = 0; i < ctx->timeline_semaphore_count; i++)
        if (ctx->timeline_semaphores[i].id == id) return &ctx->timeline_semaphores[i];
    return NULL;
}

static VkSemaphore get_or_create_timeline_semaphore(GuavaVkContext* ctx, uint32_t id) {
    TimelineSemaphoreEntry* existing = find_timeline_semaphore(ctx, id);
    if (existing) return existing->semaphore;
    if (!ctx->timeline_semaphores_supported) return VK_NULL_HANDLE;
    if (ctx->timeline_semaphore_count >= MAX_RESOURCES) return VK_NULL_HANDLE;

    VkSemaphoreTypeCreateInfo type_info = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
        .semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE,
        .initialValue = 0,
    };
    VkSemaphoreCreateInfo create_info = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = &type_info,
    };

    TimelineSemaphoreEntry* entry = &ctx->timeline_semaphores[ctx->timeline_semaphore_count];
    if (vkCreateSemaphore(ctx->device, &create_info, NULL, &entry->semaphore) != VK_SUCCESS) {
        return VK_NULL_HANDLE;
    }

    entry->id = id;
    ctx->timeline_semaphore_count += 1;
    return entry->semaphore;
}

static ShaderEntry* find_shader(GuavaVkContext* ctx, uint32_t id) {
    for (uint32_t i = 0; i < ctx->shader_count; i++)
        if (ctx->shaders[i].id == id) return &ctx->shaders[i];
    return NULL;
}

static GfxPipelineEntry* find_gfx_pipeline(GuavaVkContext* ctx, uint32_t id) {
    for (uint32_t i = 0; i < ctx->gfx_pipeline_count; i++)
        if (ctx->gfx_pipelines[i].id == id) return &ctx->gfx_pipelines[i];
    return NULL;
}

static ComputePipelineEntry* find_cmp_pipeline(GuavaVkContext* ctx, uint32_t id) {
    for (uint32_t i = 0; i < ctx->cmp_pipeline_count; i++)
        if (ctx->cmp_pipelines[i].id == id) return &ctx->cmp_pipelines[i];
    return NULL;
}

static BindingSetData* find_binding_set(GuavaVkContext* ctx, uint32_t id) {
    for (uint32_t i = 0; i < ctx->binding_set_count; i++)
        if (ctx->binding_sets[i].id == id) return &ctx->binding_sets[i];
    return NULL;
}

// ---------------------------------------------------------------------------
// Format conversion helpers
// ---------------------------------------------------------------------------
static VkFormat map_texture_format(uint32_t fmt) {
    switch (fmt) {
        case 1:  return VK_FORMAT_R8_UNORM;
        case 2:  return VK_FORMAT_R8G8B8A8_UNORM;
        case 3:  return VK_FORMAT_B8G8R8A8_UNORM;
        case 4:  return VK_FORMAT_B8G8R8A8_SRGB;
        case 5:  return VK_FORMAT_R8G8B8A8_SRGB;
        case 6:  return VK_FORMAT_R16G16B16A16_SFLOAT;
        case 7:  return VK_FORMAT_R32G32B32A32_SFLOAT;
        case 8:  return VK_FORMAT_D24_UNORM_S8_UINT;
        case 9:  return VK_FORMAT_D24_UNORM_S8_UINT;
        case 10: return VK_FORMAT_D32_SFLOAT;
        default: return VK_FORMAT_R8G8B8A8_UNORM;
    }
}

static VkCompareOp map_compare_op(uint32_t op) {
    switch (op) {
        case 0: return VK_COMPARE_OP_NEVER;
        case 1: return VK_COMPARE_OP_LESS;
        case 2: return VK_COMPARE_OP_EQUAL;
        case 3: return VK_COMPARE_OP_LESS_OR_EQUAL;
        case 4: return VK_COMPARE_OP_GREATER;
        case 5: return VK_COMPARE_OP_NOT_EQUAL;
        case 6: return VK_COMPARE_OP_GREATER_OR_EQUAL;
        case 7: return VK_COMPARE_OP_ALWAYS;
        default: return VK_COMPARE_OP_ALWAYS;
    }
}

static VkBlendFactor map_blend_factor(uint32_t f) {
    switch (f) {
        case 0:  return VK_BLEND_FACTOR_ZERO;
        case 1:  return VK_BLEND_FACTOR_ONE;
        case 2:  return VK_BLEND_FACTOR_SRC_COLOR;
        case 3:  return VK_BLEND_FACTOR_ONE_MINUS_SRC_COLOR;
        case 4:  return VK_BLEND_FACTOR_DST_COLOR;
        case 5:  return VK_BLEND_FACTOR_ONE_MINUS_DST_COLOR;
        case 6:  return VK_BLEND_FACTOR_SRC_ALPHA;
        case 7:  return VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        case 8:  return VK_BLEND_FACTOR_DST_ALPHA;
        case 9:  return VK_BLEND_FACTOR_ONE_MINUS_DST_ALPHA;
        case 10: return VK_BLEND_FACTOR_CONSTANT_COLOR;
        case 11: return VK_BLEND_FACTOR_ONE_MINUS_CONSTANT_COLOR;
        case 12: return VK_BLEND_FACTOR_SRC_ALPHA_SATURATE;
        default: return VK_BLEND_FACTOR_ONE;
    }
}

static VkBlendOp map_blend_op(uint32_t op) {
    switch (op) {
        case 0: return VK_BLEND_OP_ADD;
        case 1: return VK_BLEND_OP_SUBTRACT;
        case 2: return VK_BLEND_OP_REVERSE_SUBTRACT;
        case 3: return VK_BLEND_OP_MIN;
        case 4: return VK_BLEND_OP_MAX;
        default: return VK_BLEND_OP_ADD;
    }
}

static VkPrimitiveTopology map_primitive(uint32_t prim) {
    switch (prim) {
        case 0: return VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        case 1: return VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP;
        case 2: return VK_PRIMITIVE_TOPOLOGY_LINE_LIST;
        case 3: return VK_PRIMITIVE_TOPOLOGY_LINE_STRIP;
        case 4: return VK_PRIMITIVE_TOPOLOGY_POINT_LIST;
        default: return VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    }
}

static VkFormat map_vertex_format(uint32_t fmt) {
    switch (fmt) {
        case 0: return VK_FORMAT_R32G32_SFLOAT;       // float2
        case 1: return VK_FORMAT_R32G32B32_SFLOAT;    // float3
        case 2: return VK_FORMAT_R32G32B32A32_SFLOAT;  // float4
        default: return VK_FORMAT_R32G32B32_SFLOAT;
    }
}

static VkSamplerAddressMode map_address_mode(uint32_t mode) {
    switch (mode) {
        case 0: return VK_SAMPLER_ADDRESS_MODE_REPEAT;
        case 1: return VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT;
        case 2: return VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
        default: return VK_SAMPLER_ADDRESS_MODE_REPEAT;
    }
}

static VkFilter map_filter(uint32_t f) {
    return (f == 0) ? VK_FILTER_NEAREST : VK_FILTER_LINEAR;
}

static VkSamplerMipmapMode map_mipmap_mode(uint32_t m) {
    return (m == 0) ? VK_SAMPLER_MIPMAP_MODE_NEAREST : VK_SAMPLER_MIPMAP_MODE_LINEAR;
}

static bool format_has_depth(VkFormat fmt) {
    return fmt == VK_FORMAT_D32_SFLOAT ||
           fmt == VK_FORMAT_D24_UNORM_S8_UINT ||
           fmt == VK_FORMAT_D16_UNORM;
}

// ---------------------------------------------------------------------------
// Render pass & framebuffer cache helpers
// ---------------------------------------------------------------------------

static VkRenderPass find_or_create_render_pass(GuavaVkContext* ctx,
                                                VkFormat color_fmt, VkFormat depth_fmt,
                                                uint32_t clear_mask) {
    for (uint32_t i = 0; i < ctx->rp_cache_count; i++) {
        if (ctx->rp_cache[i].color_format == color_fmt &&
            ctx->rp_cache[i].depth_format == depth_fmt &&
            ctx->rp_cache[i].clear_mask == clear_mask)
            return ctx->rp_cache[i].render_pass;
    }

    VkAttachmentDescription attachments[2];
    uint32_t att_count = 0;

    VkAttachmentReference color_ref = { .attachment = 0, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkAttachmentReference depth_ref = { .attachment = 1, .layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };

    bool clear_color = (clear_mask & 1) != 0;
    attachments[att_count++] = (VkAttachmentDescription){
        .format = color_fmt,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = clear_color ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = clear_color ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    bool has_depth = depth_fmt != VK_FORMAT_UNDEFINED;
    if (has_depth) {
        bool clear_depth = (clear_mask & 2) != 0;
        attachments[att_count++] = (VkAttachmentDescription){
            .format = depth_fmt,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .loadOp = clear_depth ? VK_ATTACHMENT_LOAD_OP_CLEAR : VK_ATTACHMENT_LOAD_OP_LOAD,
            .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = clear_depth ? VK_IMAGE_LAYOUT_UNDEFINED : VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            .finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };
    }

    VkSubpassDescription subpass = {
        .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_ref,
        .pDepthStencilAttachment = has_depth ? &depth_ref : NULL,
    };

    VkSubpassDependency dep = {
        .srcSubpass = VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        .srcAccessMask = 0,
        .dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | (has_depth ? VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT : 0),
    };

    VkRenderPassCreateInfo rp_info = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = att_count,
        .pAttachments = attachments,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dep,
    };

    VkRenderPass rp;
    if (vkCreateRenderPass(ctx->device, &rp_info, NULL, &rp) != VK_SUCCESS)
        return VK_NULL_HANDLE;

    if (ctx->rp_cache_count < 256) {
        ctx->rp_cache[ctx->rp_cache_count++] = (RenderPassCacheEntry){
            .render_pass = rp,
            .color_format = color_fmt,
            .depth_format = depth_fmt,
            .clear_mask = clear_mask,
        };
    }
    return rp;
}

static VkFramebuffer find_or_create_framebuffer(GuavaVkContext* ctx, VkRenderPass rp,
                                                  VkImageView color_view, VkImageView depth_view,
                                                  uint32_t w, uint32_t h) {
    for (uint32_t i = 0; i < ctx->fb_cache_count; i++) {
        FramebufferCacheEntry* e = &ctx->fb_cache[i];
        if (e->render_pass == rp && e->color_view == color_view &&
            e->depth_view == depth_view && e->width == w && e->height == h)
            return e->framebuffer;
    }

    VkImageView views[2];
    uint32_t view_count = 0;
    if (color_view) views[view_count++] = color_view;
    if (depth_view) views[view_count++] = depth_view;

    VkFramebufferCreateInfo fb_info = {
        .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = rp,
        .attachmentCount = view_count,
        .pAttachments = views,
        .width = w,
        .height = h,
        .layers = 1,
    };

    VkFramebuffer fb;
    if (vkCreateFramebuffer(ctx->device, &fb_info, NULL, &fb) != VK_SUCCESS)
        return VK_NULL_HANDLE;

    if (ctx->fb_cache_count < 1024) {
        ctx->fb_cache[ctx->fb_cache_count++] = (FramebufferCacheEntry){
            .framebuffer = fb,
            .render_pass = rp,
            .color_view = color_view,
            .depth_view = depth_view,
            .width = w,
            .height = h,
        };
    }
    return fb;
}

// ---------------------------------------------------------------------------
// Memory helpers
// ---------------------------------------------------------------------------
static uint32_t find_memory_type(GuavaVkContext* ctx, uint32_t type_filter, VkMemoryPropertyFlags properties) {
    for (uint32_t i = 0; i < ctx->mem_properties.memoryTypeCount; i++) {
        if ((type_filter & (1 << i)) &&
            (ctx->mem_properties.memoryTypes[i].propertyFlags & properties) == properties) {
            return i;
        }
    }
    fprintf(stderr, "[Guava VK] Failed to find suitable memory type\n");
    return 0;
}

// ---------------------------------------------------------------------------
// Validation layer callback
// ---------------------------------------------------------------------------
static VKAPI_ATTR VkBool32 VKAPI_CALL debug_callback(
    VkDebugUtilsMessageSeverityFlagBitsEXT severity,
    VkDebugUtilsMessageTypeFlagsEXT type,
    const VkDebugUtilsMessengerCallbackDataEXT* callback_data,
    void* user_data
) {
    (void)type;
    (void)user_data;
    if (severity >= VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) {
        fprintf(stderr, "[Guava VK Validation] %s\n", callback_data->pMessage);
    }
    return VK_FALSE;
}

// ---------------------------------------------------------------------------
// Image layout transition helper
// ---------------------------------------------------------------------------
static void transition_image_layout(
    GuavaVkContext* ctx, VkCommandBuffer cmd,
    VkImage image, VkImageLayout old_layout, VkImageLayout new_layout,
    VkImageAspectFlags aspect_mask
) {
    VkImageMemoryBarrier barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .oldLayout = old_layout,
        .newLayout = new_layout,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = {
            .aspectMask = aspect_mask,
            .baseMipLevel = 0,
            .levelCount = VK_REMAINING_MIP_LEVELS,
            .baseArrayLayer = 0,
            .layerCount = VK_REMAINING_ARRAY_LAYERS,
        },
    };

    VkPipelineStageFlags src_stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkPipelineStageFlags dst_stage = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    barrier.srcAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT | VK_ACCESS_MEMORY_WRITE_BIT;

    (void)ctx;
    vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0,
                         0, NULL, 0, NULL, 1, &barrier);
}

// ===========================================================================
// Lifecycle
// ===========================================================================

void* guava_vk_rhi_init(bool enable_validation) {
    GuavaVkContext* ctx = (GuavaVkContext*)calloc(1, sizeof(GuavaVkContext));
    if (!ctx) return NULL;
    ctx->validation_enabled = enable_validation;
    ctx->next_buffer_id = 1;
    ctx->next_texture_id = 1;
    ctx->next_sampler_id = 1;
    ctx->next_shader_id = 1;
    ctx->next_gfx_pipe_id = 1;
    ctx->next_cmp_pipe_id = 1;

    // ── Create VkInstance ──────────────────────────────────────────────
    VkApplicationInfo app_info = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "Guava Engine",
        .applicationVersion = VK_MAKE_VERSION(0, 1, 0),
        .pEngineName = "Guava",
        .engineVersion = VK_MAKE_VERSION(0, 1, 0),
        .apiVersion = VK_API_VERSION_1_3,
    };

    // Gather required window-system extensions from the platform layer.
    uint32_t platform_ext_count = 0;
    const char* const* platform_extensions = guava_window_vulkan_instance_extensions(&platform_ext_count);

    uint32_t ext_count = platform_ext_count;
    const char* extensions[64];
    for (uint32_t i = 0; i < platform_ext_count && i < 60; i++)
        extensions[i] = platform_extensions[i];

    if (enable_validation)
        extensions[ext_count++] = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;

    // Portability enumeration (needed for MoltenVK on macOS)
#ifdef __APPLE__
    extensions[ext_count++] = VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME;
#endif

    const char* validation_layer = "VK_LAYER_KHRONOS_validation";

    VkInstanceCreateInfo create_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app_info,
        .enabledExtensionCount = ext_count,
        .ppEnabledExtensionNames = extensions,
        .enabledLayerCount = enable_validation ? 1 : 0,
        .ppEnabledLayerNames = enable_validation ? &validation_layer : NULL,
#ifdef __APPLE__
        .flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
#endif
    };

    VkResult result = vkCreateInstance(&create_info, NULL, &ctx->instance);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "[Guava VK] vkCreateInstance failed: %d\n", result);
        free(ctx);
        return NULL;
    }

    // ── Validation debug messenger ────────────────────────────────────
    if (enable_validation) {
        PFN_vkCreateDebugUtilsMessengerEXT createDbg =
            (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(ctx->instance, "vkCreateDebugUtilsMessengerEXT");
        if (createDbg) {
            VkDebugUtilsMessengerCreateInfoEXT dbg_info = {
                .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                                   VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
                .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                               VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                               VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
                .pfnUserCallback = debug_callback,
            };
            createDbg(ctx->instance, &dbg_info, NULL, &ctx->debug_messenger);
        }
    }

    // ── Pick physical device ──────────────────────────────────────────
    uint32_t dev_count = 0;
    vkEnumeratePhysicalDevices(ctx->instance, &dev_count, NULL);
    if (dev_count == 0) {
        fprintf(stderr, "[Guava VK] No Vulkan physical devices found\n");
        vkDestroyInstance(ctx->instance, NULL);
        free(ctx);
        return NULL;
    }
    VkPhysicalDevice devices[16];
    dev_count = dev_count > 16 ? 16 : dev_count;
    vkEnumeratePhysicalDevices(ctx->instance, &dev_count, devices);

    // Prefer discrete GPU
    ctx->physical_device = devices[0];
    for (uint32_t i = 0; i < dev_count; i++) {
        VkPhysicalDeviceProperties props;
        vkGetPhysicalDeviceProperties(devices[i], &props);
        if (props.deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
            ctx->physical_device = devices[i];
            break;
        }
    }

    vkGetPhysicalDeviceProperties(ctx->physical_device, &ctx->device_properties);
    vkGetPhysicalDeviceMemoryProperties(ctx->physical_device, &ctx->mem_properties);
    fprintf(stderr, "[Guava VK] Using device: %s\n", ctx->device_properties.deviceName);

    // ── Find queue families ───────────────────────────────────────────
    uint32_t qf_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(ctx->physical_device, &qf_count, NULL);
    VkQueueFamilyProperties qf_props[32];
    qf_count = qf_count > 32 ? 32 : qf_count;
    vkGetPhysicalDeviceQueueFamilyProperties(ctx->physical_device, &qf_count, qf_props);

    ctx->graphics_family = UINT32_MAX;
    ctx->compute_family = UINT32_MAX;
    ctx->transfer_family = UINT32_MAX;

    for (uint32_t i = 0; i < qf_count; i++) {
        if ((qf_props[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && ctx->graphics_family == UINT32_MAX)
            ctx->graphics_family = i;
        if ((qf_props[i].queueFlags & VK_QUEUE_COMPUTE_BIT) && !(qf_props[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && ctx->compute_family == UINT32_MAX)
            ctx->compute_family = i;
        if ((qf_props[i].queueFlags & VK_QUEUE_TRANSFER_BIT) && !(qf_props[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && ctx->transfer_family == UINT32_MAX)
            ctx->transfer_family = i;
    }
    // Fallbacks
    if (ctx->compute_family == UINT32_MAX)
        ctx->compute_family = ctx->graphics_family;
    if (ctx->transfer_family == UINT32_MAX)
        ctx->transfer_family = ctx->graphics_family;

    // ── Create logical device ─────────────────────────────────────────
    float priority = 1.0f;
    uint32_t unique_families[3];
    uint32_t unique_count = 0;
    unique_families[unique_count++] = ctx->graphics_family;
    if (ctx->compute_family != ctx->graphics_family)
        unique_families[unique_count++] = ctx->compute_family;
    if (ctx->transfer_family != ctx->graphics_family && ctx->transfer_family != ctx->compute_family)
        unique_families[unique_count++] = ctx->transfer_family;

    VkDeviceQueueCreateInfo queue_infos[3];
    for (uint32_t i = 0; i < unique_count; i++) {
        queue_infos[i] = (VkDeviceQueueCreateInfo){
            .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = unique_families[i],
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
    }

    const char* device_extensions[] = {
        VK_KHR_SWAPCHAIN_EXTENSION_NAME,
#ifdef __APPLE__
        "VK_KHR_portability_subset",
#endif
    };
    uint32_t device_ext_count = sizeof(device_extensions) / sizeof(device_extensions[0]);

    VkPhysicalDeviceFeatures features = {0};
    features.samplerAnisotropy = VK_TRUE;
    features.fillModeNonSolid = VK_TRUE;

    VkPhysicalDeviceVulkan12Features supported_vulkan12 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
    };
    VkPhysicalDeviceFeatures2 features2 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2,
        .pNext = &supported_vulkan12,
    };
    vkGetPhysicalDeviceFeatures2(ctx->physical_device, &features2);
    ctx->timeline_semaphores_supported = supported_vulkan12.timelineSemaphore == VK_TRUE;

    VkPhysicalDeviceVulkan12Features enabled_vulkan12 = {
        .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
        .timelineSemaphore = ctx->timeline_semaphores_supported ? VK_TRUE : VK_FALSE,
    };

    VkDeviceCreateInfo dev_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = &enabled_vulkan12,
        .queueCreateInfoCount = unique_count,
        .pQueueCreateInfos = queue_infos,
        .enabledExtensionCount = device_ext_count,
        .ppEnabledExtensionNames = device_extensions,
        .pEnabledFeatures = &features,
    };

    result = vkCreateDevice(ctx->physical_device, &dev_info, NULL, &ctx->device);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "[Guava VK] vkCreateDevice failed: %d\n", result);
        vkDestroyInstance(ctx->instance, NULL);
        free(ctx);
        return NULL;
    }

    vkGetDeviceQueue(ctx->device, ctx->graphics_family, 0, &ctx->graphics_queue);
    vkGetDeviceQueue(ctx->device, ctx->compute_family, 0, &ctx->compute_queue);
    vkGetDeviceQueue(ctx->device, ctx->transfer_family, 0, &ctx->transfer_queue);

    // ── Command pools ─────────────────────────────────────────────────
    VkCommandPoolCreateInfo pool_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = ctx->graphics_family,
    };
    vkCreateCommandPool(ctx->device, &pool_info, NULL, &ctx->graphics_cmd_pool);

    pool_info.queueFamilyIndex = ctx->compute_family;
    vkCreateCommandPool(ctx->device, &pool_info, NULL, &ctx->compute_cmd_pool);

    pool_info.queueFamilyIndex = ctx->transfer_family;
    vkCreateCommandPool(ctx->device, &pool_info, NULL, &ctx->transfer_cmd_pool);

    // ── Sync objects ──────────────────────────────────────────────────
    VkSemaphoreCreateInfo sem_info = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    vkCreateSemaphore(ctx->device, &sem_info, NULL, &ctx->image_available_semaphore);
    vkCreateSemaphore(ctx->device, &sem_info, NULL, &ctx->render_finished_semaphore);

    VkFenceCreateInfo fence_info = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = VK_FENCE_CREATE_SIGNALED_BIT,
    };
    vkCreateFence(ctx->device, &fence_info, NULL, &ctx->in_flight_fence);

    // ── Descriptor pool ───────────────────────────────────────────────
    VkDescriptorPoolSize desc_pool_sizes[] = {
        { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1000 },
        { VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, 1000 },
        { VK_DESCRIPTOR_TYPE_SAMPLER, 1000 },
        { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1000 },
        { VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1000 },
        { VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 1000 },
    };
    VkDescriptorPoolCreateInfo desc_pool_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        .maxSets = 4096,
        .poolSizeCount = sizeof(desc_pool_sizes) / sizeof(desc_pool_sizes[0]),
        .pPoolSizes = desc_pool_sizes,
    };
    vkCreateDescriptorPool(ctx->device, &desc_pool_info, NULL, &ctx->descriptor_pool);

    return ctx;
}

void guava_vk_rhi_destroy(void* raw) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    if (!ctx) return;

    vkDeviceWaitIdle(ctx->device);

    // Destroy resources
    for (uint32_t i = 0; i < ctx->buffer_count; i++) {
        vkDestroyBuffer(ctx->device, ctx->buffers[i].buffer, NULL);
        vkFreeMemory(ctx->device, ctx->buffers[i].memory, NULL);
    }
    for (uint32_t i = 0; i < ctx->texture_count; i++) {
        if (!ctx->textures[i].is_swapchain_image) {
            vkDestroyImageView(ctx->device, ctx->textures[i].view, NULL);
            vkDestroyImage(ctx->device, ctx->textures[i].image, NULL);
            vkFreeMemory(ctx->device, ctx->textures[i].memory, NULL);
        }
    }
    for (uint32_t i = 0; i < ctx->sampler_count; i++)
        vkDestroySampler(ctx->device, ctx->samplers[i].sampler, NULL);
    for (uint32_t i = 0; i < ctx->timeline_semaphore_count; i++)
        vkDestroySemaphore(ctx->device, ctx->timeline_semaphores[i].semaphore, NULL);
    for (uint32_t i = 0; i < ctx->shader_count; i++)
        vkDestroyShaderModule(ctx->device, ctx->shaders[i].module, NULL);
    for (uint32_t i = 0; i < ctx->gfx_pipeline_count; i++) {
        vkDestroyPipeline(ctx->device, ctx->gfx_pipelines[i].pipeline, NULL);
        vkDestroyPipelineLayout(ctx->device, ctx->gfx_pipelines[i].layout, NULL);
        vkDestroyRenderPass(ctx->device, ctx->gfx_pipelines[i].render_pass, NULL);
    }
    for (uint32_t i = 0; i < ctx->cmp_pipeline_count; i++) {
        vkDestroyPipeline(ctx->device, ctx->cmp_pipelines[i].pipeline, NULL);
        vkDestroyPipelineLayout(ctx->device, ctx->cmp_pipelines[i].layout, NULL);
    }

    // Binding set layouts
    for (uint32_t i = 0; i < ctx->binding_set_count; i++) {
        if (ctx->binding_sets[i].layout)
            vkDestroyDescriptorSetLayout(ctx->device, ctx->binding_sets[i].layout, NULL);
    }

    // Framebuffer cache
    for (uint32_t i = 0; i < ctx->fb_cache_count; i++)
        vkDestroyFramebuffer(ctx->device, ctx->fb_cache[i].framebuffer, NULL);

    // Render pass cache
    for (uint32_t i = 0; i < ctx->rp_cache_count; i++)
        vkDestroyRenderPass(ctx->device, ctx->rp_cache[i].render_pass, NULL);

    // Descriptor pool
    if (ctx->descriptor_pool)
        vkDestroyDescriptorPool(ctx->device, ctx->descriptor_pool, NULL);

    // Swapchain
    if (ctx->swapchain_image_views) {
        for (uint32_t i = 0; i < ctx->swapchain_image_count; i++)
            vkDestroyImageView(ctx->device, ctx->swapchain_image_views[i], NULL);
        free(ctx->swapchain_image_views);
    }
    if (ctx->swapchain_images) free(ctx->swapchain_images);
    if (ctx->swapchain) vkDestroySwapchainKHR(ctx->device, ctx->swapchain, NULL);
    if (ctx->surface) vkDestroySurfaceKHR(ctx->instance, ctx->surface, NULL);

    // Sync
    vkDestroySemaphore(ctx->device, ctx->image_available_semaphore, NULL);
    vkDestroySemaphore(ctx->device, ctx->render_finished_semaphore, NULL);
    vkDestroyFence(ctx->device, ctx->in_flight_fence, NULL);

    // Pools
    vkDestroyCommandPool(ctx->device, ctx->graphics_cmd_pool, NULL);
    vkDestroyCommandPool(ctx->device, ctx->compute_cmd_pool, NULL);
    vkDestroyCommandPool(ctx->device, ctx->transfer_cmd_pool, NULL);

    // Debug messenger
    if (ctx->debug_messenger) {
        PFN_vkDestroyDebugUtilsMessengerEXT destroyDbg =
            (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(ctx->instance, "vkDestroyDebugUtilsMessengerEXT");
        if (destroyDbg)
            destroyDbg(ctx->instance, ctx->debug_messenger, NULL);
    }

    vkDestroyDevice(ctx->device, NULL);
    vkDestroyInstance(ctx->instance, NULL);
    free(ctx);
}

// ===========================================================================
// Surface / Swapchain
// ===========================================================================

static void destroy_swapchain_resources(GuavaVkContext* ctx) {
    if (!ctx->device) return;

    vkDeviceWaitIdle(ctx->device);

    for (uint32_t i = 0; i < ctx->fb_cache_count; i++) {
        vkDestroyFramebuffer(ctx->device, ctx->fb_cache[i].framebuffer, NULL);
    }
    ctx->fb_cache_count = 0;

    if (ctx->swapchain_image_views) {
        for (uint32_t i = 0; i < ctx->swapchain_image_count; i++) {
            vkDestroyImageView(ctx->device, ctx->swapchain_image_views[i], NULL);
        }
        free(ctx->swapchain_image_views);
        ctx->swapchain_image_views = NULL;
    }

    if (ctx->swapchain_images) {
        free(ctx->swapchain_images);
        ctx->swapchain_images = NULL;
    }

    if (ctx->swapchain) {
        vkDestroySwapchainKHR(ctx->device, ctx->swapchain, NULL);
        ctx->swapchain = VK_NULL_HANDLE;
    }

    ctx->swapchain_image_count = 0;
    ctx->current_swapchain_index = 0;
    ctx->swapchain_texture_id = 0;
}

bool guava_vk_rhi_create_surface(void* raw, void* native_window) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    if (!guava_window_create_vulkan_surface(native_window, ctx->instance, &ctx->surface)) {
        fprintf(stderr, "[Guava VK] create surface failed: %s\n", guava_window_vulkan_last_error());
        return false;
    }
    return true;
}

bool guava_vk_rhi_create_swapchain(void* raw, uint32_t width, uint32_t height, bool vsync_enabled) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;

    if (ctx->swapchain || ctx->swapchain_image_views || ctx->swapchain_images) {
        destroy_swapchain_resources(ctx);
    }

    VkSurfaceCapabilitiesKHR caps;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(ctx->physical_device, ctx->surface, &caps);

    // Choose format
    uint32_t fmt_count = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(ctx->physical_device, ctx->surface, &fmt_count, NULL);
    VkSurfaceFormatKHR formats[32];
    fmt_count = fmt_count > 32 ? 32 : fmt_count;
    vkGetPhysicalDeviceSurfaceFormatsKHR(ctx->physical_device, ctx->surface, &fmt_count, formats);

    VkSurfaceFormatKHR chosen = formats[0];
    for (uint32_t i = 0; i < fmt_count; i++) {
        if (formats[i].format == VK_FORMAT_B8G8R8A8_SRGB &&
            formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
            chosen = formats[i];
            break;
        }
    }
    ctx->swapchain_format = chosen.format;

    // Choose present mode based on VSync preference.
    uint32_t pm_count = 0;
    vkGetPhysicalDeviceSurfacePresentModesKHR(ctx->physical_device, ctx->surface, &pm_count, NULL);
    VkPresentModeKHR modes[16];
    pm_count = pm_count > 16 ? 16 : pm_count;
    vkGetPhysicalDeviceSurfacePresentModesKHR(ctx->physical_device, ctx->surface, &pm_count, modes);

    VkPresentModeKHR present_mode = VK_PRESENT_MODE_FIFO_KHR;
    if (vsync_enabled) {
        present_mode = VK_PRESENT_MODE_FIFO_KHR;
    } else {
        for (uint32_t i = 0; i < pm_count; i++) {
            if (modes[i] == VK_PRESENT_MODE_IMMEDIATE_KHR) {
                present_mode = VK_PRESENT_MODE_IMMEDIATE_KHR;
                break;
            }
        }
        if (present_mode == VK_PRESENT_MODE_FIFO_KHR) {
            for (uint32_t i = 0; i < pm_count; i++) {
                if (modes[i] == VK_PRESENT_MODE_MAILBOX_KHR) {
                    present_mode = VK_PRESENT_MODE_MAILBOX_KHR;
                    break;
                }
            }
        }
    }

    ctx->swapchain_extent.width = width;
    ctx->swapchain_extent.height = height;
    if (caps.currentExtent.width != UINT32_MAX) {
        ctx->swapchain_extent = caps.currentExtent;
    }

    uint32_t image_count = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && image_count > caps.maxImageCount)
        image_count = caps.maxImageCount;

    VkSwapchainCreateInfoKHR sc_info = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = ctx->surface,
        .minImageCount = image_count,
        .imageFormat = chosen.format,
        .imageColorSpace = chosen.colorSpace,
        .imageExtent = ctx->swapchain_extent,
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = caps.currentTransform,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = present_mode,
        .clipped = VK_TRUE,
    };

    VkResult result = vkCreateSwapchainKHR(ctx->device, &sc_info, NULL, &ctx->swapchain);
    if (result != VK_SUCCESS) {
        fprintf(stderr, "[Guava VK] vkCreateSwapchainKHR failed: %d\n", result);
        return false;
    }

    // Get swapchain images
    vkGetSwapchainImagesKHR(ctx->device, ctx->swapchain, &ctx->swapchain_image_count, NULL);
    ctx->swapchain_images = (VkImage*)malloc(sizeof(VkImage) * ctx->swapchain_image_count);
    vkGetSwapchainImagesKHR(ctx->device, ctx->swapchain, &ctx->swapchain_image_count, ctx->swapchain_images);

    // Create image views
    ctx->swapchain_image_views = (VkImageView*)malloc(sizeof(VkImageView) * ctx->swapchain_image_count);
    for (uint32_t i = 0; i < ctx->swapchain_image_count; i++) {
        VkImageViewCreateInfo view_info = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = ctx->swapchain_images[i],
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = ctx->swapchain_format,
            .components = { VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY,
                           VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY },
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        vkCreateImageView(ctx->device, &view_info, NULL, &ctx->swapchain_image_views[i]);
    }

    return true;
}

// ===========================================================================
// Resource creation
// ===========================================================================

uint32_t guava_vk_rhi_create_buffer(void* raw, uint64_t size, uint32_t usage_bits, const char* label) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    (void)label;

    VkBufferUsageFlags vk_usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    if (usage_bits & (1 << 0)) vk_usage |= VK_BUFFER_USAGE_VERTEX_BUFFER_BIT;
    if (usage_bits & (1 << 1)) vk_usage |= VK_BUFFER_USAGE_INDEX_BUFFER_BIT;
    if (usage_bits & (1 << 2)) vk_usage |= VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    if (usage_bits & ((1 << 3) | (1 << 4))) vk_usage |= VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    if (usage_bits & (1 << 5)) vk_usage |= VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT;

    VkBufferCreateInfo buf_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = vk_usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };

    VkBuffer buffer;
    if (vkCreateBuffer(ctx->device, &buf_info, NULL, &buffer) != VK_SUCCESS)
        return 0;

    VkMemoryRequirements mem_reqs;
    vkGetBufferMemoryRequirements(ctx->device, buffer, &mem_reqs);

    VkMemoryAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = find_memory_type(ctx, mem_reqs.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };

    VkDeviceMemory memory;
    if (vkAllocateMemory(ctx->device, &alloc_info, NULL, &memory) != VK_SUCCESS) {
        vkDestroyBuffer(ctx->device, buffer, NULL);
        return 0;
    }
    vkBindBufferMemory(ctx->device, buffer, memory, 0);

    uint32_t id = ctx->next_buffer_id++;
    if (ctx->buffer_count < MAX_RESOURCES) {
        ctx->buffers[ctx->buffer_count++] = (BufferEntry){
            .id = id,
            .buffer = buffer,
            .memory = memory,
            .size = size,
        };
    }
    return id;
}

uint32_t guava_vk_rhi_create_texture(void* raw, const GuavaVkTextureDesc* desc, const char* label) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    (void)label;

    VkFormat format = map_texture_format(desc->format);
    bool is_depth = format_has_depth(format);

    VkImageUsageFlags vk_usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    if (desc->usage_bits & (1 << 0)) vk_usage |= VK_IMAGE_USAGE_SAMPLED_BIT;
    if (desc->usage_bits & (1 << 1)) vk_usage |= VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    if (desc->usage_bits & (1 << 2)) vk_usage |= VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT;
    if (desc->usage_bits & ((1 << 3) | (1 << 4) | (1 << 5) | (1 << 6)))
        vk_usage |= VK_IMAGE_USAGE_STORAGE_BIT;

    VkImageType image_type = VK_IMAGE_TYPE_2D;
    VkImageViewType view_type = VK_IMAGE_VIEW_TYPE_2D;
    uint32_t array_layers = desc->layers;

    if (desc->dimension == 1) { // d3
        image_type = VK_IMAGE_TYPE_3D;
        view_type = VK_IMAGE_VIEW_TYPE_3D;
    } else if (desc->dimension == 2) { // cube
        view_type = VK_IMAGE_VIEW_TYPE_CUBE;
        array_layers = 6;
    } else if (desc->dimension == 3) { // array
        view_type = VK_IMAGE_VIEW_TYPE_2D_ARRAY;
    }

    VkImageCreateFlags flags = 0;
    if (desc->dimension == 2) flags |= VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT;

    VkImageCreateInfo img_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .flags = flags,
        .imageType = image_type,
        .format = format,
        .extent = { desc->width, desc->height, desc->depth },
        .mipLevels = desc->mip_levels,
        .arrayLayers = array_layers,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = vk_usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
    };

    VkImage image;
    if (vkCreateImage(ctx->device, &img_info, NULL, &image) != VK_SUCCESS)
        return 0;

    VkMemoryRequirements mem_reqs;
    vkGetImageMemoryRequirements(ctx->device, image, &mem_reqs);

    VkMemoryAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = find_memory_type(ctx, mem_reqs.memoryTypeBits,
            VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
    };

    VkDeviceMemory memory;
    if (vkAllocateMemory(ctx->device, &alloc_info, NULL, &memory) != VK_SUCCESS) {
        vkDestroyImage(ctx->device, image, NULL);
        return 0;
    }
    vkBindImageMemory(ctx->device, image, memory, 0);

    // Create image view
    VkImageViewCreateInfo view_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = view_type,
        .format = format,
        .subresourceRange = {
            .aspectMask = is_depth ? VK_IMAGE_ASPECT_DEPTH_BIT : VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = desc->mip_levels,
            .baseArrayLayer = 0,
            .layerCount = array_layers,
        },
    };

    VkImageView view;
    if (vkCreateImageView(ctx->device, &view_info, NULL, &view) != VK_SUCCESS) {
        vkDestroyImage(ctx->device, image, NULL);
        vkFreeMemory(ctx->device, memory, NULL);
        return 0;
    }

    uint32_t id = ctx->next_texture_id++;
    if (ctx->texture_count < MAX_RESOURCES) {
        ctx->textures[ctx->texture_count++] = (TextureEntry){
            .id = id,
            .image = image,
            .view = view,
            .memory = memory,
            .width = desc->width,
            .height = desc->height,
            .depth = desc->depth,
            .layers = array_layers,
            .mip_levels = desc->mip_levels,
            .format = format,
            .current_layout = VK_IMAGE_LAYOUT_UNDEFINED,
            .is_swapchain_image = false,
        };
    }
    return id;
}

uint32_t guava_vk_rhi_create_sampler(void* raw, const GuavaVkSamplerDesc* desc) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;

    VkSamplerCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = map_filter(desc->mag_filter),
        .minFilter = map_filter(desc->min_filter),
        .mipmapMode = map_mipmap_mode(desc->mipmap_mode),
        .addressModeU = map_address_mode(desc->address_u),
        .addressModeV = map_address_mode(desc->address_v),
        .addressModeW = map_address_mode(desc->address_w),
        .mipLodBias = 0.0f,
        .anisotropyEnable = VK_TRUE,
        .maxAnisotropy = ctx->device_properties.limits.maxSamplerAnisotropy,
        .compareEnable = desc->enable_compare ? VK_TRUE : VK_FALSE,
        .compareOp = map_compare_op(desc->compare_op),
        .minLod = 0.0f,
        .maxLod = VK_LOD_CLAMP_NONE,
        .borderColor = VK_BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = VK_FALSE,
    };

    VkSampler sampler;
    if (vkCreateSampler(ctx->device, &info, NULL, &sampler) != VK_SUCCESS)
        return 0;

    uint32_t id = ctx->next_sampler_id++;
    if (ctx->sampler_count < MAX_RESOURCES) {
        ctx->samplers[ctx->sampler_count++] = (SamplerEntry){ .id = id, .sampler = sampler };
    }
    return id;
}

uint32_t guava_vk_rhi_create_shader_module(void* raw, uint32_t stage, uint32_t format,
                                            const uint8_t* code, uint32_t code_len,
                                            const char* entry_point) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;

    // Only SPIR-V is supported for Vulkan
    if (format != 0) { // 0 = spirv
        fprintf(stderr, "[Guava VK] Unsupported shader format %u (only SPIR-V)\n", format);
        return 0;
    }

    VkShaderModuleCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code_len,
        .pCode = (const uint32_t*)code,
    };

    VkShaderModule module;
    if (vkCreateShaderModule(ctx->device, &info, NULL, &module) != VK_SUCCESS)
        return 0;

    uint32_t id = ctx->next_shader_id++;
    if (ctx->shader_count < MAX_RESOURCES) {
        ShaderEntry entry = {
            .id = id,
            .module = module,
            .stage = stage,
        };
        strncpy(entry.entry_point, entry_point ? entry_point : "main", sizeof(entry.entry_point) - 1);
        entry.entry_point[sizeof(entry.entry_point) - 1] = '\0';
        ctx->shaders[ctx->shader_count++] = entry;
    }
    return id;
}

uint32_t guava_vk_rhi_create_graphics_pipeline(void* raw,
                                                 const GuavaVkGraphicsPipelineDesc* desc,
                                                 const GuavaVkVertexAttribute* attrs,
                                                 const GuavaVkVertexBufferLayout* buf_layouts) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;

    ShaderEntry* vs = find_shader(ctx, desc->vertex_shader_id);
    ShaderEntry* fs = desc->fragment_shader_id != 0 ? find_shader(ctx, desc->fragment_shader_id) : NULL;
    if (!vs || (desc->fragment_shader_id != 0 && !fs)) return 0;

    // ── Shader stages ──────────────────────────────────────────────
    VkPipelineShaderStageCreateInfo stages[2] = {0};
    uint32_t stage_count = 0;
    stages[stage_count++] = (VkPipelineShaderStageCreateInfo){
        .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = VK_SHADER_STAGE_VERTEX_BIT,
        .module = vs->module,
        .pName = vs->entry_point,
    };
    if (fs) {
        stages[stage_count++] = (VkPipelineShaderStageCreateInfo){
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = fs->module,
            .pName = fs->entry_point,
        };
    }

    // ── Vertex input ───────────────────────────────────────────────
    VkVertexInputAttributeDescription vk_attrs[32];
    VkVertexInputBindingDescription vk_bindings[8];
    uint32_t attr_count = desc->vertex_attr_count;
    uint32_t bind_count = desc->vertex_buffer_layout_count;

    if (attr_count > 32) attr_count = 32;
    if (bind_count > 8) bind_count = 8;

    for (uint32_t i = 0; i < attr_count && attrs; i++) {
        vk_attrs[i] = (VkVertexInputAttributeDescription){
            .location = attrs[i].location,
            .binding = attrs[i].buffer_index,
            .format = map_vertex_format(attrs[i].format),
            .offset = attrs[i].offset,
        };
    }
    for (uint32_t i = 0; i < bind_count && buf_layouts; i++) {
        vk_bindings[i] = (VkVertexInputBindingDescription){
            .binding = i,
            .stride = buf_layouts[i].stride,
            .inputRate = buf_layouts[i].step_rate == 0 ? VK_VERTEX_INPUT_RATE_VERTEX : VK_VERTEX_INPUT_RATE_INSTANCE,
        };
    }

    VkPipelineVertexInputStateCreateInfo vertex_input = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = bind_count,
        .pVertexBindingDescriptions = bind_count > 0 ? vk_bindings : NULL,
        .vertexAttributeDescriptionCount = attr_count,
        .pVertexAttributeDescriptions = attr_count > 0 ? vk_attrs : NULL,
    };

    // ── Input assembly ─────────────────────────────────────────────
    VkPipelineInputAssemblyStateCreateInfo input_assembly = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = map_primitive(desc->primitive),
        .primitiveRestartEnable = VK_FALSE,
    };

    // ── Dynamic state (viewport + scissor) ─────────────────────────
    VkDynamicState dynamic_states[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dynamic_state = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .dynamicStateCount = 2,
        .pDynamicStates = dynamic_states,
    };

    VkPipelineViewportStateCreateInfo viewport_state = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .scissorCount = 1,
    };

    // ── Rasterization ──────────────────────────────────────────────
    VkPipelineRasterizationStateCreateInfo rasterizer = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .depthClampEnable = VK_FALSE,
        .rasterizerDiscardEnable = VK_FALSE,
        .polygonMode = VK_POLYGON_MODE_FILL,
        .lineWidth = 1.0f,
        .cullMode = VK_CULL_MODE_BACK_BIT,
        .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .depthBiasEnable = VK_FALSE,
    };

    // ── Multisampling ──────────────────────────────────────────────
    VkPipelineMultisampleStateCreateInfo multisampling = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .sampleShadingEnable = VK_FALSE,
        .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
    };

    // ── Depth/stencil ──────────────────────────────────────────────
    VkPipelineDepthStencilStateCreateInfo depth_stencil = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = desc->depth_format != 0 ? VK_TRUE : VK_FALSE,
        .depthWriteEnable = desc->depth_write_enabled ? VK_TRUE : VK_FALSE,
        .depthCompareOp = map_compare_op(desc->depth_compare_op),
        .depthBoundsTestEnable = VK_FALSE,
        .stencilTestEnable = VK_FALSE,
    };

    VkFormat color_format = map_texture_format(desc->color_format);
    bool has_color = color_format != VK_FORMAT_UNDEFINED;

    // ── Color blending ─────────────────────────────────────────────
    VkPipelineColorBlendAttachmentState color_blend_attachment = {
        .colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                          VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT,
        .blendEnable = (has_color && desc->blend_enabled) ? VK_TRUE : VK_FALSE,
        .srcColorBlendFactor = map_blend_factor(desc->src_color_blend),
        .dstColorBlendFactor = map_blend_factor(desc->dst_color_blend),
        .colorBlendOp = map_blend_op(desc->color_blend_op),
        .srcAlphaBlendFactor = map_blend_factor(desc->src_alpha_blend),
        .dstAlphaBlendFactor = map_blend_factor(desc->dst_alpha_blend),
        .alphaBlendOp = map_blend_op(desc->alpha_blend_op),
    };

    VkPipelineColorBlendStateCreateInfo color_blending = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = VK_FALSE,
        .attachmentCount = has_color ? 1 : 0,
        .pAttachments = has_color ? &color_blend_attachment : NULL,
    };

    // ── Pipeline layout (push constants + descriptor set layouts) ──
    VkPushConstantRange push_range = {
        .stageFlags = VK_SHADER_STAGE_VERTEX_BIT | (fs ? VK_SHADER_STAGE_FRAGMENT_BIT : 0),
        .offset = 0,
        .size = 256, // max push constant size
    };

    // Collect unique descriptor set layouts from registered binding sets
    VkDescriptorSetLayout set_layouts[4];
    uint32_t set_layout_count = 0;
    for (uint32_t i = 0; i < ctx->binding_set_count && set_layout_count < 4; i++) {
        if (ctx->binding_sets[i].layout) {
            set_layouts[set_layout_count++] = ctx->binding_sets[i].layout;
        }
    }

    VkPipelineLayoutCreateInfo layout_info = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = set_layout_count,
        .pSetLayouts = set_layout_count > 0 ? set_layouts : NULL,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_range,
    };

    VkPipelineLayout pipeline_layout;
    if (vkCreatePipelineLayout(ctx->device, &layout_info, NULL, &pipeline_layout) != VK_SUCCESS)
        return 0;

    // ── Render pass ────────────────────────────────────────────────
    VkAttachmentDescription attachments[2];
    uint32_t attachment_count = 0;

    VkAttachmentReference color_ref = { .attachment = 0, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkAttachmentReference depth_ref = { .attachment = has_color ? 1 : 0, .layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };

    if (has_color) {
        attachments[attachment_count++] = (VkAttachmentDescription){
            .format = color_format,
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };
    }

    bool has_depth = desc->depth_format != 0;
    if (has_depth) {
        attachments[attachment_count++] = (VkAttachmentDescription){
            .format = map_texture_format(desc->depth_format),
            .samples = VK_SAMPLE_COUNT_1_BIT,
            .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        };
    }

    VkSubpassDescription subpass = {
        .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = has_color ? 1 : 0,
        .pColorAttachments = has_color ? &color_ref : NULL,
        .pDepthStencilAttachment = has_depth ? &depth_ref : NULL,
    };

    VkSubpassDependency dependency = {
        .srcSubpass = VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = (has_color ? VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT : 0) | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        .srcAccessMask = 0,
        .dstStageMask = (has_color ? VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT : 0) | VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        .dstAccessMask = (has_color ? VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT : 0) | (has_depth ? VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT : 0),
    };

    VkRenderPassCreateInfo rp_info = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = attachment_count,
        .pAttachments = attachments,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    VkRenderPass render_pass;
    if (vkCreateRenderPass(ctx->device, &rp_info, NULL, &render_pass) != VK_SUCCESS) {
        vkDestroyPipelineLayout(ctx->device, pipeline_layout, NULL);
        return 0;
    }

    // ── Create pipeline ────────────────────────────────────────────
    VkGraphicsPipelineCreateInfo pipe_info = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = stage_count,
        .pStages = stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterizer,
        .pMultisampleState = &multisampling,
        .pDepthStencilState = &depth_stencil,
        .pColorBlendState = &color_blending,
        .pDynamicState = &dynamic_state,
        .layout = pipeline_layout,
        .renderPass = render_pass,
        .subpass = 0,
    };

    VkPipeline pipeline;
    if (vkCreateGraphicsPipelines(ctx->device, VK_NULL_HANDLE, 1, &pipe_info, NULL, &pipeline) != VK_SUCCESS) {
        vkDestroyRenderPass(ctx->device, render_pass, NULL);
        vkDestroyPipelineLayout(ctx->device, pipeline_layout, NULL);
        return 0;
    }

    uint32_t id = ctx->next_gfx_pipe_id++;
    if (ctx->gfx_pipeline_count < MAX_RESOURCES) {
        ctx->gfx_pipelines[ctx->gfx_pipeline_count++] = (GfxPipelineEntry){
            .id = id,
            .pipeline = pipeline,
            .layout = pipeline_layout,
            .render_pass = render_pass,
            .primitive = desc->primitive,
        };
    }
    return id;
}

uint32_t guava_vk_rhi_create_compute_pipeline(void* raw, uint32_t shader_id) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;

    ShaderEntry* shader = find_shader(ctx, shader_id);
    if (!shader) return 0;

    VkPushConstantRange push_range = {
        .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT,
        .offset = 0,
        .size = 256,
    };

    // Collect descriptor set layouts
    VkDescriptorSetLayout set_layouts[4];
    uint32_t set_layout_count = 0;
    for (uint32_t i = 0; i < ctx->binding_set_count && set_layout_count < 4; i++) {
        if (ctx->binding_sets[i].layout)
            set_layouts[set_layout_count++] = ctx->binding_sets[i].layout;
    }

    VkPipelineLayoutCreateInfo layout_info = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = set_layout_count,
        .pSetLayouts = set_layout_count > 0 ? set_layouts : NULL,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_range,
    };

    VkPipelineLayout layout;
    if (vkCreatePipelineLayout(ctx->device, &layout_info, NULL, &layout) != VK_SUCCESS)
        return 0;

    VkComputePipelineCreateInfo pipe_info = {
        .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = {
            .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = VK_SHADER_STAGE_COMPUTE_BIT,
            .module = shader->module,
            .pName = shader->entry_point,
        },
        .layout = layout,
    };

    VkPipeline pipeline;
    if (vkCreateComputePipelines(ctx->device, VK_NULL_HANDLE, 1, &pipe_info, NULL, &pipeline) != VK_SUCCESS) {
        vkDestroyPipelineLayout(ctx->device, layout, NULL);
        return 0;
    }

    uint32_t id = ctx->next_cmp_pipe_id++;
    if (ctx->cmp_pipeline_count < MAX_RESOURCES) {
        ctx->cmp_pipelines[ctx->cmp_pipeline_count++] = (ComputePipelineEntry){
            .id = id,
            .pipeline = pipeline,
            .layout = layout,
        };
    }
    return id;
}

// ===========================================================================
// Resource destruction
// ===========================================================================

void guava_vk_rhi_destroy_buffer(void* raw, uint32_t id) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    for (uint32_t i = 0; i < ctx->buffer_count; i++) {
        if (ctx->buffers[i].id == id) {
            vkDestroyBuffer(ctx->device, ctx->buffers[i].buffer, NULL);
            vkFreeMemory(ctx->device, ctx->buffers[i].memory, NULL);
            ctx->buffers[i] = ctx->buffers[--ctx->buffer_count];
            return;
        }
    }
}

void guava_vk_rhi_destroy_texture(void* raw, uint32_t id) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    for (uint32_t i = 0; i < ctx->texture_count; i++) {
        if (ctx->textures[i].id == id) {
            if (!ctx->textures[i].is_swapchain_image) {
                vkDestroyImageView(ctx->device, ctx->textures[i].view, NULL);
                vkDestroyImage(ctx->device, ctx->textures[i].image, NULL);
                vkFreeMemory(ctx->device, ctx->textures[i].memory, NULL);
            }
            ctx->textures[i] = ctx->textures[--ctx->texture_count];
            return;
        }
    }
}

void guava_vk_rhi_destroy_sampler(void* raw, uint32_t id) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    for (uint32_t i = 0; i < ctx->sampler_count; i++) {
        if (ctx->samplers[i].id == id) {
            vkDestroySampler(ctx->device, ctx->samplers[i].sampler, NULL);
            ctx->samplers[i] = ctx->samplers[--ctx->sampler_count];
            return;
        }
    }
}

void guava_vk_rhi_destroy_graphics_pipeline(void* raw, uint32_t id) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    for (uint32_t i = 0; i < ctx->gfx_pipeline_count; i++) {
        if (ctx->gfx_pipelines[i].id == id) {
            vkDestroyPipeline(ctx->device, ctx->gfx_pipelines[i].pipeline, NULL);
            vkDestroyPipelineLayout(ctx->device, ctx->gfx_pipelines[i].layout, NULL);
            vkDestroyRenderPass(ctx->device, ctx->gfx_pipelines[i].render_pass, NULL);
            ctx->gfx_pipelines[i] = ctx->gfx_pipelines[--ctx->gfx_pipeline_count];
            return;
        }
    }
}

void guava_vk_rhi_destroy_compute_pipeline(void* raw, uint32_t id) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    for (uint32_t i = 0; i < ctx->cmp_pipeline_count; i++) {
        if (ctx->cmp_pipelines[i].id == id) {
            vkDestroyPipeline(ctx->device, ctx->cmp_pipelines[i].pipeline, NULL);
            vkDestroyPipelineLayout(ctx->device, ctx->cmp_pipelines[i].layout, NULL);
            ctx->cmp_pipelines[i] = ctx->cmp_pipelines[--ctx->cmp_pipeline_count];
            return;
        }
    }
}

// ===========================================================================
// Data transfer
// ===========================================================================

bool guava_vk_rhi_upload_buffer_data(void* raw, uint32_t buffer_id,
                                      uint64_t offset,
                                      const uint8_t* data, uint64_t size) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    BufferEntry* buf = find_buffer(ctx, buffer_id);
    if (!buf) return false;

    void* mapped;
    if (vkMapMemory(ctx->device, buf->memory, offset, size, 0, &mapped) != VK_SUCCESS)
        return false;
    memcpy(mapped, data, (size_t)size);
    vkUnmapMemory(ctx->device, buf->memory);
    return true;
}

bool guava_vk_rhi_upload_texture_data(void* raw, uint32_t texture_id,
                                       const uint8_t* data, uint64_t size,
                                       uint32_t width, uint32_t height,
                                       uint32_t bytes_per_row) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    TextureEntry* tex = find_texture(ctx, texture_id);
    if (!tex) return false;

    // Create staging buffer
    VkBufferCreateInfo buf_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VkBuffer staging;
    vkCreateBuffer(ctx->device, &buf_info, NULL, &staging);

    VkMemoryRequirements mem_reqs;
    vkGetBufferMemoryRequirements(ctx->device, staging, &mem_reqs);

    VkMemoryAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = find_memory_type(ctx, mem_reqs.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    VkDeviceMemory staging_mem;
    vkAllocateMemory(ctx->device, &alloc_info, NULL, &staging_mem);
    vkBindBufferMemory(ctx->device, staging, staging_mem, 0);

    void* mapped;
    vkMapMemory(ctx->device, staging_mem, 0, size, 0, &mapped);
    memcpy(mapped, data, (size_t)size);
    vkUnmapMemory(ctx->device, staging_mem);

    // Record copy command
    VkCommandBufferAllocateInfo cmd_alloc = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = ctx->graphics_cmd_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer cmd;
    vkAllocateCommandBuffers(ctx->device, &cmd_alloc, &cmd);

    VkCommandBufferBeginInfo begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    vkBeginCommandBuffer(cmd, &begin);

    transition_image_layout(ctx, cmd, tex->image, tex->current_layout, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                           VK_IMAGE_ASPECT_COLOR_BIT);

    VkBufferImageCopy region = {
        .bufferOffset = 0,
        .bufferRowLength = bytes_per_row / 4, // pixels per row (approximate)
        .bufferImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = { 0, 0, 0 },
        .imageExtent = { width, height, 1 },
    };
    vkCmdCopyBufferToImage(cmd, staging, tex->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    transition_image_layout(ctx, cmd, tex->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                           VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_IMAGE_ASPECT_COLOR_BIT);
    tex->current_layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    vkEndCommandBuffer(cmd);

    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
    };
    vkQueueSubmit(ctx->graphics_queue, 1, &submit, VK_NULL_HANDLE);
    vkQueueWaitIdle(ctx->graphics_queue);

    vkFreeCommandBuffers(ctx->device, ctx->graphics_cmd_pool, 1, &cmd);
    vkDestroyBuffer(ctx->device, staging, NULL);
    vkFreeMemory(ctx->device, staging_mem, NULL);

    return true;
}

bool guava_vk_rhi_read_texture_data(void* raw, uint32_t texture_id,
                                     uint32_t width, uint32_t height,
                                     uint32_t bytes_per_row,
                                     uint8_t* out_data, uint64_t out_size) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    TextureEntry* tex = find_texture(ctx, texture_id);
    if (!tex) return false;

    // Create staging buffer for readback
    VkBufferCreateInfo buf_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = out_size,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VkBuffer staging;
    vkCreateBuffer(ctx->device, &buf_info, NULL, &staging);

    VkMemoryRequirements mem_reqs;
    vkGetBufferMemoryRequirements(ctx->device, staging, &mem_reqs);

    VkMemoryAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = find_memory_type(ctx, mem_reqs.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    VkDeviceMemory staging_mem;
    vkAllocateMemory(ctx->device, &alloc_info, NULL, &staging_mem);
    vkBindBufferMemory(ctx->device, staging, staging_mem, 0);

    VkCommandBufferAllocateInfo cmd_alloc = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = ctx->graphics_cmd_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer cmd;
    vkAllocateCommandBuffers(ctx->device, &cmd_alloc, &cmd);

    VkCommandBufferBeginInfo begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    vkBeginCommandBuffer(cmd, &begin);

    transition_image_layout(ctx, cmd, tex->image, tex->current_layout, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           VK_IMAGE_ASPECT_COLOR_BIT);

    VkBufferImageCopy region = {
        .bufferOffset = 0,
        .bufferRowLength = bytes_per_row / 4,
        .bufferImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = { 0, 0, 0 },
        .imageExtent = { width, height, 1 },
    };
    vkCmdCopyImageToBuffer(cmd, tex->image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, staging, 1, &region);

    vkEndCommandBuffer(cmd);

    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
    };
    vkQueueSubmit(ctx->graphics_queue, 1, &submit, VK_NULL_HANDLE);
    vkQueueWaitIdle(ctx->graphics_queue);

    void* mapped;
    vkMapMemory(ctx->device, staging_mem, 0, out_size, 0, &mapped);
    memcpy(out_data, mapped, (size_t)out_size);
    vkUnmapMemory(ctx->device, staging_mem);

    vkFreeCommandBuffers(ctx->device, ctx->graphics_cmd_pool, 1, &cmd);
    vkDestroyBuffer(ctx->device, staging, NULL);
    vkFreeMemory(ctx->device, staging_mem, NULL);

    return true;
}

// ===========================================================================
// Binding set registration
// ===========================================================================

static VkDescriptorType map_resource_type_to_descriptor(uint32_t resource_type) {
    switch (resource_type) {
        case 0: return VK_DESCRIPTOR_TYPE_SAMPLER;
        case 1: return VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
        case 2: return VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
        case 3: return VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
        case 4: return VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        default: return VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE;
    }
}

static VkShaderStageFlags map_stage_to_shader_flags(uint32_t stage) {
    switch (stage) {
        case 0: return VK_SHADER_STAGE_VERTEX_BIT;
        case 1: return VK_SHADER_STAGE_FRAGMENT_BIT;
        case 2: return VK_SHADER_STAGE_COMPUTE_BIT;
        default: return VK_SHADER_STAGE_ALL;
    }
}

static void create_binding_set_descriptors(GuavaVkContext* ctx, BindingSetData* data,
                                            const GuavaVkBindingEntry* entries, uint32_t count) {
    // Create descriptor set layout from entries
    VkDescriptorSetLayoutBinding layout_bindings[32];
    for (uint32_t i = 0; i < count; i++) {
        layout_bindings[i] = (VkDescriptorSetLayoutBinding){
            .binding = entries[i].slot,
            .descriptorType = map_resource_type_to_descriptor(entries[i].resource_type),
            .descriptorCount = 1,
            .stageFlags = map_stage_to_shader_flags(entries[i].stage),
        };
    }

    VkDescriptorSetLayoutCreateInfo layout_ci = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = count,
        .pBindings = layout_bindings,
    };
    if (vkCreateDescriptorSetLayout(ctx->device, &layout_ci, NULL, &data->layout) != VK_SUCCESS) {
        fprintf(stderr, "[Guava VK] Failed to create descriptor set layout for set %u\n", data->id);
        return;
    }

    // Allocate descriptor set
    VkDescriptorSetAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = ctx->descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &data->layout,
    };
    if (vkAllocateDescriptorSets(ctx->device, &alloc_info, &data->descriptor_set) != VK_SUCCESS) {
        fprintf(stderr, "[Guava VK] Failed to allocate descriptor set for set %u\n", data->id);
        return;
    }

    // Write descriptors
    VkWriteDescriptorSet writes[32];
    VkDescriptorBufferInfo buffer_infos[32];
    VkDescriptorImageInfo image_infos[32];
    uint32_t write_count = 0;

    for (uint32_t i = 0; i < count; i++) {
        VkDescriptorType desc_type = map_resource_type_to_descriptor(entries[i].resource_type);

        writes[write_count] = (VkWriteDescriptorSet){
            .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = data->descriptor_set,
            .dstBinding = entries[i].slot,
            .dstArrayElement = 0,
            .descriptorType = desc_type,
            .descriptorCount = 1,
        };

        switch (entries[i].resource_type) {
            case 0: { // sampler
                SamplerEntry* s = find_sampler(ctx, entries[i].resource_id);
                if (!s) continue;
                image_infos[write_count] = (VkDescriptorImageInfo){
                    .sampler = s->sampler,
                };
                writes[write_count].pImageInfo = &image_infos[write_count];
                break;
            }
            case 1: { // texture (sampled image)
                TextureEntry* t = find_texture(ctx, entries[i].resource_id);
                if (!t) continue;
                image_infos[write_count] = (VkDescriptorImageInfo){
                    .imageView = t->view,
                    .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                };
                writes[write_count].pImageInfo = &image_infos[write_count];
                break;
            }
            case 2: { // storage texture
                TextureEntry* t = find_texture(ctx, entries[i].resource_id);
                if (!t) continue;
                image_infos[write_count] = (VkDescriptorImageInfo){
                    .imageView = t->view,
                    .imageLayout = VK_IMAGE_LAYOUT_GENERAL,
                };
                writes[write_count].pImageInfo = &image_infos[write_count];
                break;
            }
            case 3: { // uniform buffer
                BufferEntry* b = find_buffer(ctx, entries[i].resource_id);
                if (!b) continue;
                buffer_infos[write_count] = (VkDescriptorBufferInfo){
                    .buffer = b->buffer,
                    .offset = 0,
                    .range = b->size,
                };
                writes[write_count].pBufferInfo = &buffer_infos[write_count];
                break;
            }
            case 4: { // storage buffer
                BufferEntry* b = find_buffer(ctx, entries[i].resource_id);
                if (!b) continue;
                buffer_infos[write_count] = (VkDescriptorBufferInfo){
                    .buffer = b->buffer,
                    .offset = 0,
                    .range = b->size,
                };
                writes[write_count].pBufferInfo = &buffer_infos[write_count];
                break;
            }
            default: continue;
        }
        write_count++;
    }

    if (write_count > 0)
        vkUpdateDescriptorSets(ctx->device, write_count, writes, 0, NULL);
}

void guava_vk_rhi_register_binding_set(void* raw, uint32_t set_id,
                                        const GuavaVkBindingEntry* entries,
                                        uint32_t count) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;

    BindingSetData* existing = find_binding_set(ctx, set_id);
    if (existing) {
        existing->entry_count = count > 32 ? 32 : count;
        memcpy(existing->entries, entries, sizeof(GuavaVkBindingEntry) * existing->entry_count);
        // Free old descriptor set and layout, then recreate
        if (existing->descriptor_set)
            vkFreeDescriptorSets(ctx->device, ctx->descriptor_pool, 1, &existing->descriptor_set);
        if (existing->layout)
            vkDestroyDescriptorSetLayout(ctx->device, existing->layout, NULL);
        existing->layout = VK_NULL_HANDLE;
        existing->descriptor_set = VK_NULL_HANDLE;
        create_binding_set_descriptors(ctx, existing, entries, existing->entry_count);
        return;
    }

    if (ctx->binding_set_count >= MAX_RESOURCES) return;

    BindingSetData* data = &ctx->binding_sets[ctx->binding_set_count++];
    data->id = set_id;
    data->entry_count = count > 32 ? 32 : count;
    data->layout = VK_NULL_HANDLE;
    data->descriptor_set = VK_NULL_HANDLE;
    memcpy(data->entries, entries, sizeof(GuavaVkBindingEntry) * data->entry_count);
    create_binding_set_descriptors(ctx, data, entries, data->entry_count);
}

// ===========================================================================
// Command buffer submission (decode byte stream → Vulkan commands)
// ===========================================================================

bool guava_vk_rhi_submit(void* raw, uint32_t queue_class,
                          const uint8_t* cmd_bytes, uint32_t cmd_len,
                          const GuavaVkSubmitDesc* submit_desc) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    const GuavaVkSubmitDesc empty_desc = {0};
    if (!submit_desc) submit_desc = &empty_desc;

    VkCommandPool pool = ctx->graphics_cmd_pool;
    VkQueue queue = ctx->graphics_queue;
    if (queue_class == 1) {
        pool = ctx->compute_cmd_pool;
        queue = ctx->compute_queue;
    } else if (queue_class == 2) {
        pool = ctx->transfer_cmd_pool;
        queue = ctx->transfer_queue;
    }

    if ((submit_desc->wait_count > 0 || submit_desc->signal_count > 0) && !ctx->timeline_semaphores_supported) {
        fprintf(stderr, "[Guava VK] Timeline semaphore submit requested but the device does not support timeline semaphores\n");
        return false;
    }

    VkCommandBufferAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    VkCommandBuffer cmd;
    if (vkAllocateCommandBuffers(ctx->device, &alloc_info, &cmd) != VK_SUCCESS)
        return false;

    VkCommandBufferBeginInfo begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    if (vkBeginCommandBuffer(cmd, &begin) != VK_SUCCESS) {
        vkFreeCommandBuffers(ctx->device, pool, 1, &cmd);
        return false;
    }

    bool success = true;
    VkSemaphore* wait_semaphores = NULL;
    uint64_t* wait_values = NULL;
    VkPipelineStageFlags* wait_stage_masks = NULL;
    VkSemaphore* signal_semaphores = NULL;
    uint64_t* signal_values = NULL;
    VkResult submit_result = VK_SUCCESS;

    if (submit_desc->wait_count > 0) {
        wait_semaphores = (VkSemaphore*)malloc(sizeof(VkSemaphore) * submit_desc->wait_count);
        wait_values = (uint64_t*)malloc(sizeof(uint64_t) * submit_desc->wait_count);
        wait_stage_masks = (VkPipelineStageFlags*)malloc(sizeof(VkPipelineStageFlags) * submit_desc->wait_count);
        if (!wait_semaphores || !wait_values || !wait_stage_masks) {
            success = false;
            goto cleanup;
        }
        for (uint32_t i = 0; i < submit_desc->wait_count; ++i) {
            VkSemaphore semaphore = get_or_create_timeline_semaphore(ctx, submit_desc->wait_semaphores[i].id);
            if (semaphore == VK_NULL_HANDLE) {
                success = false;
                goto cleanup;
            }
            wait_semaphores[i] = semaphore;
            wait_values[i] = submit_desc->wait_semaphores[i].value;
            wait_stage_masks[i] = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
        }
    }

    if (submit_desc->signal_count > 0) {
        signal_semaphores = (VkSemaphore*)malloc(sizeof(VkSemaphore) * submit_desc->signal_count);
        signal_values = (uint64_t*)malloc(sizeof(uint64_t) * submit_desc->signal_count);
        if (!signal_semaphores || !signal_values) {
            success = false;
            goto cleanup;
        }
        for (uint32_t i = 0; i < submit_desc->signal_count; ++i) {
            VkSemaphore semaphore = get_or_create_timeline_semaphore(ctx, submit_desc->signal_semaphores[i].id);
            if (semaphore == VK_NULL_HANDLE) {
                success = false;
                goto cleanup;
            }
            signal_semaphores[i] = semaphore;
            signal_values[i] = submit_desc->signal_semaphores[i].value;
        }
    }

    // Decode the byte stream
    uint32_t offset = 0;
    VkRenderPass active_render_pass = VK_NULL_HANDLE;
    VkFramebuffer active_framebuffer = VK_NULL_HANDLE;
    VkPipelineLayout active_layout = VK_NULL_HANDLE;
    bool in_render_pass = false;
    bool in_compute_pass = false;

    while (offset < cmd_len) {
        uint8_t opcode = cmd_bytes[offset++];

        switch (opcode) {
            case OP_BEGIN_RENDER_PASS: {
                if (offset + sizeof(CmdBeginRenderPass) > cmd_len) goto end_recording;
                const CmdBeginRenderPass* rp = (const CmdBeginRenderPass*)(cmd_bytes + offset);
                offset += sizeof(CmdBeginRenderPass);

                TextureEntry* color_tex = rp->color_target_id ? find_texture(ctx, rp->color_target_id) : NULL;
                TextureEntry* depth_tex = rp->depth_target_id ? find_texture(ctx, rp->depth_target_id) : NULL;
                if (!color_tex && !depth_tex) { in_render_pass = true; break; }
                VkFormat color_fmt = color_tex ? color_tex->format : VK_FORMAT_UNDEFINED;
                VkFormat depth_fmt = depth_tex ? depth_tex->format : VK_FORMAT_UNDEFINED;

                active_render_pass = find_or_create_render_pass(ctx, color_fmt, depth_fmt, rp->clear_mask);
                if (!active_render_pass) { in_render_pass = true; break; }

                if (color_tex && color_tex->current_layout != VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL) {
                    transition_image_layout(ctx, cmd, color_tex->image,
                        color_tex->current_layout, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                        VK_IMAGE_ASPECT_COLOR_BIT);
                    color_tex->current_layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
                }
                if (depth_tex && depth_tex->current_layout != VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL) {
                    transition_image_layout(ctx, cmd, depth_tex->image,
                        depth_tex->current_layout, VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                        VK_IMAGE_ASPECT_DEPTH_BIT);
                    depth_tex->current_layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
                }

                VkImageView depth_view = depth_tex ? depth_tex->view : VK_NULL_HANDLE;
                VkImageView color_view = color_tex ? color_tex->view : VK_NULL_HANDLE;
                uint32_t target_width = color_tex ? color_tex->width : depth_tex->width;
                uint32_t target_height = color_tex ? color_tex->height : depth_tex->height;
                active_framebuffer = find_or_create_framebuffer(ctx, active_render_pass,
                    color_view, depth_view, target_width, target_height);
                if (!active_framebuffer) { in_render_pass = true; break; }

                VkClearValue clear_values[2];
                uint32_t clear_count = 0;
                if (color_tex) {
                    clear_values[clear_count++] = (VkClearValue){
                        .color = {{ rp->clear_r, rp->clear_g, rp->clear_b, rp->clear_a }}
                    };
                }
                if (depth_tex) {
                    clear_values[clear_count++] = (VkClearValue){
                        .depthStencil = { rp->clear_depth, 0 }
                    };
                }

                VkRenderPassBeginInfo rp_begin = {
                    .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                    .renderPass = active_render_pass,
                    .framebuffer = active_framebuffer,
                    .renderArea = { {0, 0}, {target_width, target_height} },
                    .clearValueCount = clear_count,
                    .pClearValues = clear_values,
                };
                vkCmdBeginRenderPass(cmd, &rp_begin, VK_SUBPASS_CONTENTS_INLINE);
                in_render_pass = true;
                break;
            }
            case OP_END_RENDER_PASS: {
                if (in_render_pass && active_render_pass) {
                    vkCmdEndRenderPass(cmd);
                }
                in_render_pass = false;
                active_render_pass = VK_NULL_HANDLE;
                active_framebuffer = VK_NULL_HANDLE;
                break;
            }
            case OP_BEGIN_COMPUTE_PASS: {
                if (offset + sizeof(CmdBeginComputePass) > cmd_len) goto end_recording;
                offset += sizeof(CmdBeginComputePass);
                in_compute_pass = true;
                break;
            }
            case OP_END_COMPUTE_PASS: {
                in_compute_pass = false;
                break;
            }
            case OP_BEGIN_COPY_PASS: {
                if (offset + sizeof(CmdBeginCopyPass) > cmd_len) goto end_recording;
                offset += sizeof(CmdBeginCopyPass);
                break;
            }
            case OP_END_COPY_PASS: {
                break;
            }
            case OP_SET_BINDING_SET: {
                if (offset + sizeof(CmdSetBindingSet) > cmd_len) goto end_recording;
                const CmdSetBindingSet* bs = (const CmdSetBindingSet*)(cmd_bytes + offset);
                offset += sizeof(CmdSetBindingSet);

                BindingSetData* set_data = find_binding_set(ctx, bs->set_id);
                if (set_data && set_data->descriptor_set && active_layout) {
                    VkPipelineBindPoint bp = in_compute_pass
                        ? VK_PIPELINE_BIND_POINT_COMPUTE
                        : VK_PIPELINE_BIND_POINT_GRAPHICS;
                    vkCmdBindDescriptorSets(cmd, bp, active_layout,
                                            bs->slot, 1, &set_data->descriptor_set, 0, NULL);
                }
                break;
            }
            case OP_SET_VERTEX_BUFFER: {
                if (offset + sizeof(CmdSetVertexBuffer) > cmd_len) goto end_recording;
                const CmdSetVertexBuffer* vb = (const CmdSetVertexBuffer*)(cmd_bytes + offset);
                offset += sizeof(CmdSetVertexBuffer);

                BufferEntry* buf = find_buffer(ctx, vb->buffer_id);
                if (buf) {
                    VkDeviceSize vk_offset = vb->offset;
                    vkCmdBindVertexBuffers(cmd, vb->slot, 1, &buf->buffer, &vk_offset);
                }
                break;
            }
            case OP_SET_INDEX_BUFFER: {
                if (offset + sizeof(CmdSetIndexBuffer) > cmd_len) goto end_recording;
                const CmdSetIndexBuffer* ib = (const CmdSetIndexBuffer*)(cmd_bytes + offset);
                offset += sizeof(CmdSetIndexBuffer);

                BufferEntry* buf = find_buffer(ctx, ib->buffer_id);
                if (buf) {
                    VkIndexType idx_type = (ib->format == 0) ? VK_INDEX_TYPE_UINT16 : VK_INDEX_TYPE_UINT32;
                    vkCmdBindIndexBuffer(cmd, buf->buffer, ib->offset, idx_type);
                }
                break;
            }
            case OP_SET_PIPELINE: {
                if (offset + sizeof(CmdSetPipeline) > cmd_len) goto end_recording;
                const CmdSetPipeline* sp = (const CmdSetPipeline*)(cmd_bytes + offset);
                offset += sizeof(CmdSetPipeline);

                if (in_compute_pass) {
                    ComputePipelineEntry* cp = find_cmp_pipeline(ctx, sp->pipeline_id);
                    if (cp) {
                        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, cp->pipeline);
                        active_layout = cp->layout;
                    }
                } else {
                    GfxPipelineEntry* gp = find_gfx_pipeline(ctx, sp->pipeline_id);
                    if (gp) {
                        vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, gp->pipeline);
                        active_layout = gp->layout;
                    }
                }
                break;
            }
            case OP_DRAW_INDEXED: {
                if (offset + sizeof(CmdDrawIndexed) > cmd_len) goto end_recording;
                const CmdDrawIndexed* di = (const CmdDrawIndexed*)(cmd_bytes + offset);
                offset += sizeof(CmdDrawIndexed);
                vkCmdDrawIndexed(cmd, di->index_count, di->instance_count,
                                di->first_index, di->vertex_offset, di->first_instance);
                break;
            }
            case OP_DRAW_INDIRECT: {
                if (offset + sizeof(CmdDrawIndirect) > cmd_len) goto end_recording;
                const CmdDrawIndirect* ind = (const CmdDrawIndirect*)(cmd_bytes + offset);
                offset += sizeof(CmdDrawIndirect);
                BufferEntry* buf = find_buffer(ctx, ind->buffer_id);
                if (buf) {
                    vkCmdDrawIndirect(cmd, buf->buffer, ind->offset, ind->draw_count, sizeof(VkDrawIndirectCommand));
                }
                break;
            }
            case OP_DISPATCH: {
                if (offset + sizeof(CmdDispatch) > cmd_len) goto end_recording;
                const CmdDispatch* d = (const CmdDispatch*)(cmd_bytes + offset);
                offset += sizeof(CmdDispatch);
                vkCmdDispatch(cmd, d->x, d->y, d->z);
                break;
            }
            case OP_DISPATCH_INDIRECT: {
                if (offset + sizeof(CmdDispatchIndirect) > cmd_len) goto end_recording;
                const CmdDispatchIndirect* di = (const CmdDispatchIndirect*)(cmd_bytes + offset);
                offset += sizeof(CmdDispatchIndirect);
                BufferEntry* buf = find_buffer(ctx, di->buffer_id);
                if (buf) {
                    vkCmdDispatchIndirect(cmd, buf->buffer, di->offset);
                }
                break;
            }
            case OP_PIPELINE_BARRIER: {
                if (offset + sizeof(CmdPipelineBarrier) > cmd_len) goto end_recording;
                offset += sizeof(CmdPipelineBarrier);
                VkMemoryBarrier barrier = {
                    .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                    .srcAccessMask = VK_ACCESS_MEMORY_WRITE_BIT,
                    .dstAccessMask = VK_ACCESS_MEMORY_READ_BIT,
                };
                vkCmdPipelineBarrier(cmd,
                    VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                    VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
                    0, 1, &barrier, 0, NULL, 0, NULL);
                break;
            }
            case OP_DRAW: {
                if (offset + sizeof(CmdDraw) > cmd_len) goto end_recording;
                const CmdDraw* d = (const CmdDraw*)(cmd_bytes + offset);
                offset += sizeof(CmdDraw);
                vkCmdDraw(cmd, d->vertex_count, d->instance_count,
                         d->first_vertex, d->first_instance);
                break;
            }
            case OP_PUSH_UNIFORM: {
                if (offset + sizeof(CmdPushUniform) > cmd_len) goto end_recording;
                const CmdPushUniform* pu = (const CmdPushUniform*)(cmd_bytes + offset);
                offset += sizeof(CmdPushUniform);
                if (offset + pu->data_len > cmd_len) goto end_recording;

                if (active_layout) {
                    VkShaderStageFlags stage_flags = 0;
                    if (pu->stage == 0) stage_flags = VK_SHADER_STAGE_VERTEX_BIT;
                    else if (pu->stage == 1) stage_flags = VK_SHADER_STAGE_FRAGMENT_BIT;
                    else if (pu->stage == 2) stage_flags = VK_SHADER_STAGE_COMPUTE_BIT;

                    vkCmdPushConstants(cmd, active_layout, stage_flags,
                                      pu->slot * 64, pu->data_len, cmd_bytes + offset);
                }
                offset += pu->data_len;
                break;
            }
            case OP_SET_VIEWPORT: {
                if (offset + sizeof(CmdSetViewport) > cmd_len) goto end_recording;
                const CmdSetViewport* vp = (const CmdSetViewport*)(cmd_bytes + offset);
                offset += sizeof(CmdSetViewport);
                VkViewport viewport = {
                    .x = vp->x, .y = vp->y,
                    .width = vp->width, .height = vp->height,
                    .minDepth = vp->min_depth, .maxDepth = vp->max_depth,
                };
                vkCmdSetViewport(cmd, 0, 1, &viewport);
                break;
            }
            case OP_SET_SCISSOR: {
                if (offset + sizeof(CmdSetScissor) > cmd_len) goto end_recording;
                const CmdSetScissor* sc = (const CmdSetScissor*)(cmd_bytes + offset);
                offset += sizeof(CmdSetScissor);
                VkRect2D scissor = {
                    .offset = { sc->x, sc->y },
                    .extent = { sc->width, sc->height },
                };
                vkCmdSetScissor(cmd, 0, 1, &scissor);
                break;
            }
            default:
                fprintf(stderr, "[Guava VK] Unknown opcode: %u at offset %u\n", opcode, offset - 1);
                goto end_recording;
        }
    }

end_recording:
    if (vkEndCommandBuffer(cmd) != VK_SUCCESS) {
        success = false;
        goto cleanup;
    }

    VkTimelineSemaphoreSubmitInfo timeline_info = {
        .sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
        .waitSemaphoreValueCount = submit_desc->wait_count,
        .pWaitSemaphoreValues = wait_values,
        .signalSemaphoreValueCount = submit_desc->signal_count,
        .pSignalSemaphoreValues = signal_values,
    };

    VkSubmitInfo submit_info = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = (submit_desc->wait_count > 0 || submit_desc->signal_count > 0) ? &timeline_info : NULL,
        .waitSemaphoreCount = submit_desc->wait_count,
        .pWaitSemaphores = wait_semaphores,
        .pWaitDstStageMask = wait_stage_masks,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
        .signalSemaphoreCount = submit_desc->signal_count,
        .pSignalSemaphores = signal_semaphores,
    };

    submit_result = vkQueueSubmit(queue, 1, &submit_info, VK_NULL_HANDLE);
    if (submit_result == VK_SUCCESS) {
        submit_result = vkQueueWaitIdle(queue);
    }
    success = submit_result == VK_SUCCESS;

cleanup:
    free(wait_semaphores);
    free(wait_values);
    free(wait_stage_masks);
    free(signal_semaphores);
    free(signal_values);
    vkFreeCommandBuffers(ctx->device, pool, 1, &cmd);
    return success;
}

// ===========================================================================
// Swapchain
// ===========================================================================

bool guava_vk_rhi_acquire_swapchain(void* raw, uint32_t* out_id,
                                     uint32_t* out_width, uint32_t* out_height) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    if (!ctx->swapchain) return false;

    vkWaitForFences(ctx->device, 1, &ctx->in_flight_fence, VK_TRUE, UINT64_MAX);
    vkResetFences(ctx->device, 1, &ctx->in_flight_fence);

    VkResult result = vkAcquireNextImageKHR(ctx->device, ctx->swapchain, UINT64_MAX,
                                            ctx->image_available_semaphore, VK_NULL_HANDLE,
                                            &ctx->current_swapchain_index);
    if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) return false;

    // Register the swapchain image as a texture
    uint32_t tex_id = ctx->next_texture_id++;
    ctx->swapchain_texture_id = tex_id;

    if (ctx->texture_count < MAX_RESOURCES) {
        ctx->textures[ctx->texture_count++] = (TextureEntry){
            .id = tex_id,
            .image = ctx->swapchain_images[ctx->current_swapchain_index],
            .view = ctx->swapchain_image_views[ctx->current_swapchain_index],
            .memory = VK_NULL_HANDLE,
            .width = ctx->swapchain_extent.width,
            .height = ctx->swapchain_extent.height,
            .depth = 1,
            .layers = 1,
            .mip_levels = 1,
            .format = ctx->swapchain_format,
            .current_layout = VK_IMAGE_LAYOUT_UNDEFINED,
            .is_swapchain_image = true,
        };
    }

    *out_id = tex_id;
    *out_width = ctx->swapchain_extent.width;
    *out_height = ctx->swapchain_extent.height;
    return true;
}

bool guava_vk_rhi_present(void* raw, uint32_t swapchain_id) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    (void)swapchain_id;

    // Remove the temporary swapchain texture entry
    for (uint32_t i = 0; i < ctx->texture_count; i++) {
        if (ctx->textures[i].id == ctx->swapchain_texture_id && ctx->textures[i].is_swapchain_image) {
            ctx->textures[i] = ctx->textures[--ctx->texture_count];
            break;
        }
    }

    VkPresentInfoKHR present = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &ctx->render_finished_semaphore,
        .swapchainCount = 1,
        .pSwapchains = &ctx->swapchain,
        .pImageIndices = &ctx->current_swapchain_index,
    };

    VkResult result = vkQueuePresentKHR(ctx->graphics_queue, &present);
    return result == VK_SUCCESS || result == VK_SUBOPTIMAL_KHR;
}

// ===========================================================================
// Debug
// ===========================================================================

const char* guava_vk_rhi_get_device_name(void* raw) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    return ctx->device_properties.deviceName;
}

// ===========================================================================
// Vulkan handle getters
// ===========================================================================

void* guava_vk_rhi_get_instance(void* raw) {
    return (void*)((GuavaVkContext*)raw)->instance;
}

void* guava_vk_rhi_get_physical_device(void* raw) {
    return (void*)((GuavaVkContext*)raw)->physical_device;
}

void* guava_vk_rhi_get_vk_device(void* raw) {
    return (void*)((GuavaVkContext*)raw)->device;
}

uint32_t guava_vk_rhi_get_graphics_queue_family(void* raw) {
    return ((GuavaVkContext*)raw)->graphics_family;
}

void* guava_vk_rhi_get_graphics_queue(void* raw) {
    return (void*)((GuavaVkContext*)raw)->graphics_queue;
}

uint32_t guava_vk_rhi_get_swapchain_image_count(void* raw) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    return ctx->swapchain_image_count > 0 ? ctx->swapchain_image_count : 2;
}

void* guava_vk_rhi_get_swapchain_render_pass(void* raw) {
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    VkFormat color_fmt = ctx->swapchain_format ? ctx->swapchain_format : VK_FORMAT_B8G8R8A8_SRGB;
    VkRenderPass rp = find_or_create_render_pass(ctx, color_fmt, VK_FORMAT_UNDEFINED, 0);
    return (void*)(uintptr_t)rp;
}

// ===========================================================================
// Shared texture (cross-process viewport readback via POSIX shm)
// ===========================================================================

static SharedTextureEntry* find_shared_texture(GuavaVkContext* ctx, uint32_t texture_id) {
    for (uint32_t i = 0; i < ctx->shared_texture_count; i++)
        if (ctx->shared_textures[i].texture_id == texture_id) return &ctx->shared_textures[i];
    return NULL;
}

GuavaVkSharedTextureResult guava_vk_rhi_create_shared_texture(
        void* raw, uint32_t width, uint32_t height,
        uint32_t format, uint32_t usage_bits, const char* label) {
    GuavaVkSharedTextureResult result = {0};
#if defined(__linux__)
    GuavaVkContext* ctx = (GuavaVkContext*)raw;

    // 1. Create the normal GPU texture for rendering (same as createTexture).
    GuavaVkTextureDesc desc = {
        .width = width,
        .height = height,
        .depth = 1,
        .layers = 1,
        .mip_levels = 1,
        .sample_count = 1,
        .format = format,
        .usage_bits = usage_bits,
        .dimension = 0, // 2D
    };
    uint32_t tex_id = guava_vk_rhi_create_texture(raw, &desc, label);
    if (tex_id == 0) return result;

    // 2. Determine bytes-per-pixel from the format.
    VkFormat vk_fmt = map_texture_format(format);
    uint32_t bpp = 4;
    switch (vk_fmt) {
        case VK_FORMAT_R8_UNORM:         bpp = 1; break;
        case VK_FORMAT_R16_SFLOAT:       bpp = 2; break;
        case VK_FORMAT_R8G8B8A8_UNORM:
        case VK_FORMAT_R8G8B8A8_SRGB:
        case VK_FORMAT_B8G8R8A8_UNORM:
        case VK_FORMAT_B8G8R8A8_SRGB:   bpp = 4; break;
        case VK_FORMAT_R16G16B16A16_SFLOAT: bpp = 8; break;
        case VK_FORMAT_R32G32B32A32_SFLOAT: bpp = 16; break;
        default: bpp = 4; break;
    }
    uint64_t buf_size = (uint64_t)width * height * bpp;

    // 3. Create a HOST_VISIBLE staging buffer for readback.
    VkBufferCreateInfo buf_info = {
        .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = buf_size,
        .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
    };
    VkBuffer staging;
    if (vkCreateBuffer(ctx->device, &buf_info, NULL, &staging) != VK_SUCCESS) {
        guava_vk_rhi_destroy_texture(raw, tex_id);
        return result;
    }

    VkMemoryRequirements mem_reqs;
    vkGetBufferMemoryRequirements(ctx->device, staging, &mem_reqs);

    VkMemoryAllocateInfo alloc_info = {
        .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_reqs.size,
        .memoryTypeIndex = find_memory_type(ctx, mem_reqs.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT),
    };
    VkDeviceMemory staging_mem;
    if (vkAllocateMemory(ctx->device, &alloc_info, NULL, &staging_mem) != VK_SUCCESS) {
        vkDestroyBuffer(ctx->device, staging, NULL);
        guava_vk_rhi_destroy_texture(raw, tex_id);
        return result;
    }
    vkBindBufferMemory(ctx->device, staging, staging_mem, 0);

    // 4. Create POSIX shared memory.
    char shm_name[64];
    snprintf(shm_name, sizeof(shm_name), "/guava-vp-%d-%u", (int)getpid(), tex_id);

    int shm_fd = shm_open(shm_name, O_CREAT | O_RDWR, 0600);
    if (shm_fd < 0) {
        fprintf(stderr, "[Guava VK] shm_open(\"%s\") failed\n", shm_name);
        vkDestroyBuffer(ctx->device, staging, NULL);
        vkFreeMemory(ctx->device, staging_mem, NULL);
        guava_vk_rhi_destroy_texture(raw, tex_id);
        return result;
    }
    if (ftruncate(shm_fd, (off_t)buf_size) != 0) {
        fprintf(stderr, "[Guava VK] ftruncate shm failed\n");
        close(shm_fd);
        shm_unlink(shm_name);
        vkDestroyBuffer(ctx->device, staging, NULL);
        vkFreeMemory(ctx->device, staging_mem, NULL);
        guava_vk_rhi_destroy_texture(raw, tex_id);
        return result;
    }
    void* shm_ptr = mmap(NULL, (size_t)buf_size, PROT_READ | PROT_WRITE, MAP_SHARED, shm_fd, 0);
    if (shm_ptr == MAP_FAILED) {
        fprintf(stderr, "[Guava VK] mmap shm failed\n");
        close(shm_fd);
        shm_unlink(shm_name);
        vkDestroyBuffer(ctx->device, staging, NULL);
        vkFreeMemory(ctx->device, staging_mem, NULL);
        guava_vk_rhi_destroy_texture(raw, tex_id);
        return result;
    }

    // 5. Register the shared texture entry.
    if (ctx->shared_texture_count < 16) {
        ctx->shared_textures[ctx->shared_texture_count++] = (SharedTextureEntry){
            .texture_id = tex_id,
            .staging_buffer = staging,
            .staging_memory = staging_mem,
            .width = width,
            .height = height,
            .bytes_per_pixel = bpp,
            .buffer_size = buf_size,
            .shm_fd = shm_fd,
            .shm_ptr = shm_ptr,
        };
        strncpy(ctx->shared_textures[ctx->shared_texture_count - 1].shm_name,
                shm_name, sizeof(ctx->shared_textures[0].shm_name) - 1);
    }

    result.texture_id = tex_id;
    strncpy(result.shm_name, shm_name, sizeof(result.shm_name) - 1);
    fprintf(stderr, "[Guava VK] shared texture: tex_id=%u shm=%s size=%ux%u\n",
            tex_id, shm_name, width, height);
    return result;
#else
    (void)raw; (void)width; (void)height; (void)format; (void)usage_bits; (void)label;
    fprintf(stderr, "[Guava VK] shared texture not supported on this platform\n");
    return result;
#endif
}

bool guava_vk_rhi_blit_shared_texture(void* raw, uint32_t texture_id) {
#if defined(__linux__)
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    SharedTextureEntry* st = find_shared_texture(ctx, texture_id);
    if (!st) return false;

    TextureEntry* tex = find_texture(ctx, texture_id);
    if (!tex) return false;

    // Record and submit a one-shot command buffer for the blit.
    VkCommandBufferAllocateInfo cmd_alloc = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = ctx->graphics_cmd_pool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    VkCommandBuffer cmd;
    vkAllocateCommandBuffers(ctx->device, &cmd_alloc, &cmd);

    VkCommandBufferBeginInfo begin = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };
    vkBeginCommandBuffer(cmd, &begin);

    // Transition image to TRANSFER_SRC.
    transition_image_layout(ctx, cmd, tex->image, tex->current_layout,
                            VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                            VK_IMAGE_ASPECT_COLOR_BIT);

    VkBufferImageCopy region = {
        .bufferOffset = 0,
        .bufferRowLength = st->width,
        .bufferImageHeight = 0,
        .imageSubresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = { 0, 0, 0 },
        .imageExtent = { st->width, st->height, 1 },
    };
    vkCmdCopyImageToBuffer(cmd, tex->image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           st->staging_buffer, 1, &region);

    vkEndCommandBuffer(cmd);

    VkSubmitInfo submit = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &cmd,
    };
    vkQueueSubmit(ctx->graphics_queue, 1, &submit, VK_NULL_HANDLE);
    vkQueueWaitIdle(ctx->graphics_queue);

    // Map staging buffer and copy to shared memory.
    void* mapped;
    vkMapMemory(ctx->device, st->staging_memory, 0, st->buffer_size, 0, &mapped);
    memcpy(st->shm_ptr, mapped, (size_t)st->buffer_size);
    vkUnmapMemory(ctx->device, st->staging_memory);

    vkFreeCommandBuffers(ctx->device, ctx->graphics_cmd_pool, 1, &cmd);
    return true;
#else
    (void)raw; (void)texture_id;
    return false;
#endif
}

void guava_vk_rhi_destroy_shared_texture(void* raw, uint32_t texture_id) {
#if defined(__linux__)
    GuavaVkContext* ctx = (GuavaVkContext*)raw;
    for (uint32_t i = 0; i < ctx->shared_texture_count; i++) {
        if (ctx->shared_textures[i].texture_id == texture_id) {
            SharedTextureEntry* st = &ctx->shared_textures[i];
            // Unmap and unlink shared memory.
            if (st->shm_ptr && st->shm_ptr != MAP_FAILED)
                munmap(st->shm_ptr, (size_t)st->buffer_size);
            if (st->shm_fd >= 0)
                close(st->shm_fd);
            shm_unlink(st->shm_name);
            // Destroy Vulkan staging resources.
            vkDestroyBuffer(ctx->device, st->staging_buffer, NULL);
            vkFreeMemory(ctx->device, st->staging_memory, NULL);
            // Destroy the GPU texture.
            guava_vk_rhi_destroy_texture(raw, texture_id);
            // Compact the array.
            ctx->shared_textures[i] = ctx->shared_textures[--ctx->shared_texture_count];
            return;
        }
    }
#else
    (void)raw; (void)texture_id;
#endif
}
