const builtin = @import("builtin");
const std = @import("std");

pub const GraphicsAPI = enum {
    vulkan,
    metal,
    dx12,
};

pub const default_backend_order: [3]GraphicsAPI = switch (builtin.target.os.tag) {
    .windows => .{ .dx12, .vulkan, .metal },
    .macos, .ios => .{ .metal, .vulkan, .dx12 },
    else => .{ .vulkan, .dx12, .metal },
};

pub const defaultPreferredBackends: []const GraphicsAPI = default_backend_order[0..];

pub fn defaultBackendOrder() [3]GraphicsAPI {
    return default_backend_order;
}

pub const ShaderFormat = enum {
    spirv,
    dxil,
    msl,
};

pub const ShaderStage = enum {
    vertex,
    fragment,
    compute,
};

pub const PrimitiveType = enum {
    triangle_list,
    triangle_strip,
    line_list,
    line_strip,
    point_list,
};

pub const FillMode = enum {
    fill,
    line,
};

pub const CullMode = enum {
    none,
    front,
    back,
};

pub const FrontFace = enum {
    counter_clockwise,
    clockwise,
};

pub const CompareOp = enum {
    never,
    less,
    equal,
    less_or_equal,
    greater,
    not_equal,
    greater_or_equal,
    always,
};

pub const BlendFactor = enum {
    zero,
    one,
    src_color,
    one_minus_src_color,
    dst_color,
    one_minus_dst_color,
    src_alpha,
    one_minus_src_alpha,
    dst_alpha,
    one_minus_dst_alpha,
    constant_color,
    one_minus_constant_color,
    src_alpha_saturate,
};

pub const BlendOp = enum {
    add,
    subtract,
    reverse_subtract,
    min,
    max,
};

pub const ColorTargetBlendState = struct {
    src_color_blendfactor: BlendFactor = .src_alpha,
    dst_color_blendfactor: BlendFactor = .one_minus_src_alpha,
    color_blend_op: BlendOp = .add,
    src_alpha_blendfactor: BlendFactor = .one,
    dst_alpha_blendfactor: BlendFactor = .one_minus_src_alpha,
    alpha_blend_op: BlendOp = .add,
    enable_blend: bool = false,
};

pub const SamplerFilter = enum {
    nearest,
    linear,
};

pub const SamplerMipmapMode = enum {
    nearest,
    linear,
};

pub const SamplerAddressMode = enum {
    repeat,
    mirrored_repeat,
    clamp_to_edge,
};

pub const VertexInputRate = enum {
    per_vertex,
    per_instance,
};

pub const VertexElementFormat = enum {
    float2,
    float3,
    float4,
};

pub const IndexElementSize = enum {
    u16,
    u32,
};

pub const BackendSelectionPolicy = enum {
    explicit_order,
    platform_default,
};

pub const DeviceConfig = struct {
    preferred_backends: []const GraphicsAPI = defaultPreferredBackends,
    selection_policy: BackendSelectionPolicy = .explicit_order,
    enable_validation: bool = true,
    frames_in_flight: u32 = 2,
    prefer_low_power: bool = false,
    vsync_enabled: bool = true,
};

pub const TextureFormat = enum {
    unknown,
    r8_unorm,
    rgba8_unorm,
    bgra8_unorm,
    bgra8_unorm_srgb,
    rgba8_unorm_srgb,
    rgba16_float,
    rgba32_float,
    d24_unorm,
    d24_unorm_s8_uint,
    d32_float,
    r32_uint, // single-channel 32-bit unsigned integer (used for cluster data textures)

    pub fn bytesPerPixel(self: TextureFormat) u32 {
        return switch (self) {
            .r8_unorm => 1,
            .rgba8_unorm, .bgra8_unorm, .bgra8_unorm_srgb, .rgba8_unorm_srgb, .d24_unorm, .d32_float => 4,
            .d24_unorm_s8_uint => 4,
            .rgba16_float => 8,
            .rgba32_float => 16,
            .r32_uint => 4,
            .unknown => 4,
        };
    }
};

pub const BufferUsage = struct {
    pub const vertex: u32 = 1 << 0;
    pub const index: u32 = 1 << 1;
    pub const indirect: u32 = 1 << 2;
    pub const graphics_storage_read: u32 = 1 << 3;
    pub const compute_storage_read: u32 = 1 << 4;
    pub const compute_storage_write: u32 = 1 << 5;
};

pub const TextureUsage = struct {
    pub const sampler: u32 = 1 << 0;
    pub const color_target: u32 = 1 << 1;
    pub const depth_stencil_target: u32 = 1 << 2;
    pub const graphics_storage_read: u32 = 1 << 3;
    pub const compute_storage_read: u32 = 1 << 4;
    pub const compute_storage_write: u32 = 1 << 5;
    pub const compute_storage_rw: u32 = 1 << 6;
};

pub const ResourceStates = packed struct(u32) {
    constant_buffer: bool = false,
    vertex_buffer: bool = false,
    index_buffer: bool = false,
    indirect_argument: bool = false,
    shader_resource: bool = false,
    unordered_access: bool = false,
    render_target: bool = false,
    depth_write: bool = false,
    depth_read: bool = false,
    copy_dest: bool = false,
    copy_source: bool = false,
    present: bool = false,
    accel_struct_read: bool = false,
    accel_struct_write: bool = false,
    resolve_dest: bool = false,
    resolve_source: bool = false,
    _padding: u16 = 0,

    pub fn asBits(self: ResourceStates) u32 {
        return @bitCast(self);
    }

    pub fn fromBits(bits: u32) ResourceStates {
        return @bitCast(bits);
    }
};

pub const ResourceKind = enum(u8) {
    buffer,
    texture,
    accel_structure,
};

pub const ResourceRef = struct {
    kind: ResourceKind,
    id: u32,
    subresource_base: u16 = 0,
    subresource_count: u16 = 1,
};

pub const BarrierSyncAction = enum(u8) {
    full,
    acquire,
    release,
};

pub const BarrierPassScope = enum(u8) {
    outside_pass,
    before_pass,
    after_pass,
};

pub const BufferDesc = struct {
    size: u32,
    usage: u32,
    label: ?[]const u8 = null,
};

pub const TransferBufferDesc = struct {
    size: u32,
    upload: bool = true,
    label: ?[]const u8 = null,
};

pub const TextureDesc = struct {
    width: u32,
    height: u32,
    format: TextureFormat,
    usage: u32,
    sample_count: u32 = 1,
    label: ?[]const u8 = null,
};

pub const ClearState = struct {
    color: [4]f32 = .{ 0.07, 0.08, 0.12, 1.0 },
    depth: f32 = 1.0,
    stencil: u8 = 0,
};

pub const RuntimeInfo = struct {
    backend: GraphicsAPI = .metal,
    drawable_width: u32 = 0,
    drawable_height: u32 = 0,
    swapchain_format: TextureFormat = .unknown,
    depth_format: TextureFormat = .d32_float,
    has_depth: bool = false,
    driver_name: [64]u8 = [_]u8{0} ** 64,
    device_name: [256]u8 = [_]u8{0} ** 256,
    driver_info: [256]u8 = [_]u8{0} ** 256,

    pub fn deviceName(self: *const RuntimeInfo) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.device_name[0..], 0) orelse self.device_name.len;
        return self.device_name[0..end];
    }

    pub fn driverName(self: *const RuntimeInfo) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.driver_name[0..], 0) orelse self.driver_name.len;
        return self.driver_name[0..end];
    }

    pub fn driverInfo(self: *const RuntimeInfo) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.driver_info[0..], 0) orelse self.driver_info.len;
        return self.driver_info[0..end];
    }
};

pub fn graphicsApiName(api: GraphicsAPI) []const u8 {
    return switch (api) {
        .vulkan => "Vulkan",
        .metal => "Metal",
        .dx12 => "DirectX 12",
    };
}

// Resource pool configuration
pub const PoolConfig = struct {
    initial_capacity: usize = 8,
    max_capacity: usize = 64,
    auto_shrink: bool = true,
    shrink_threshold: f32 = 0.25, // Shrink when utilization drops below this
};

pub const PoolStats = struct {
    total_allocated: usize = 0,
    in_use: usize = 0,
    available: usize = 0,
    peak_usage: usize = 0,
    allocs: usize = 0,
    releases: usize = 0,
    cache_hits: usize = 0,
    cache_misses: usize = 0,
};

// Extended performance statistics
pub const PerformanceStats = struct {
    // Frame timing
    frame_count: u64 = 0,
    frame_time_ns: u64 = 0,
    avg_frame_time_ns: u64 = 0,
    min_frame_time_ns: u64 = std.math.maxInt(u64),
    max_frame_time_ns: u64 = 0,

    // Draw call statistics
    draw_calls: u64 = 0,
    triangles_drawn: u64 = 0,
    vertices_drawn: u64 = 0,
    instanced_draws: u64 = 0,

    // Pipeline statistics
    pipeline_binds: u64 = 0,
    bind_group_binds: u64 = 0,
    vertex_buffer_binds: u64 = 0,
    index_buffer_binds: u64 = 0,
    sampler_binds: u64 = 0,

    // Memory statistics
    buffer_count: u32 = 0,
    texture_count: u32 = 0,
    sampler_count: u32 = 0,
    pipeline_count: u32 = 0,
    total_buffer_memory_bytes: u64 = 0,
    total_texture_memory_bytes: u64 = 0,

    // Transfer statistics
    texture_uploads: u64 = 0,
    buffer_uploads: u64 = 0,
    bytes_uploaded: u64 = 0,

    // Cached bindings avoided
    redundant_pipeline_binds_avoided: u64 = 0,
    redundant_bind_group_binds_avoided: u64 = 0,
    redundant_vertex_buffer_binds_avoided: u64 = 0,
    redundant_index_buffer_binds_avoided: u64 = 0,

    pub fn reset(self: *PerformanceStats) void {
        self.* = PerformanceStats{};
    }

    pub fn recordFrame(self: *PerformanceStats, frame_time_ns: u64) void {
        self.frame_count += 1;
        self.frame_time_ns = frame_time_ns;

        // Update rolling average (exponential moving average)
        if (self.frame_count == 1) {
            self.avg_frame_time_ns = frame_time_ns;
        } else {
            self.avg_frame_time_ns = (self.avg_frame_time_ns * 7 + frame_time_ns) / 8;
        }

        self.min_frame_time_ns = @min(self.min_frame_time_ns, frame_time_ns);
        self.max_frame_time_ns = @max(self.max_frame_time_ns, frame_time_ns);
    }

    pub fn frameTimeMs(self: *const PerformanceStats) f64 {
        return @as(f64, @floatFromInt(self.frame_time_ns)) / 1_000_000.0;
    }

    pub fn avgFrameTimeMs(self: *const PerformanceStats) f64 {
        return @as(f64, @floatFromInt(self.avg_frame_time_ns)) / 1_000_000.0;
    }

    pub fn fps(self: *const PerformanceStats) f64 {
        if (self.avg_frame_time_ns == 0) return 0;
        return 1_000_000_000.0 / @as(f64, @floatFromInt(self.avg_frame_time_ns));
    }
};
