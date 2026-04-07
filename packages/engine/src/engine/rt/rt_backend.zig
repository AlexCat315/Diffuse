//! RT 后端公共类型定义
//!
//! 定义光线追踪后端共用的数据结构，保证 Zig ↔ C/ObjC++ 的内存布局一致。
//! 各平台后端 (Metal / Vulkan / DX12) 均实现相同接口：
//!   init() -> ?Self
//!   isSupported(*const Self) -> bool
//!   buildAccelerationStructure(*Self, []const RtTriangle) -> bool
//!   uploadTextures(*Self, []const u8, []const RtTextureMeta) -> bool
//!   uploadSamplingTables(*Self, []const u8, []const RtSamplingTableMeta) -> bool
//!   traceRays(*Self, *const RtParams, []u8) -> bool
//!   deinit(*Self) -> void

const builtin = @import("builtin");

pub const MetalRtBackend = @import("rt_metal.zig").MetalRtBackend;

/// 后端类型标识
pub const RtBackendType = enum {
    metal,
    vulkan,
    dx12,
    cpu,
};

/// 编译期根据目标平台自动选择的硬件 RT 后端。
/// macOS → Metal RT, Windows → (未来) Vulkan/DX12 RT, Linux → (未来) Vulkan RT。
/// 目前仅 macOS Metal 已实现；其他平台返回 null (回退到 CPU 路径追踪)。
pub const HardwareRtBackend = switch (builtin.os.tag) {
    .macos => MetalRtBackend,
    // TODO: .windows => VulkanRtBackend 或 Dx12RtBackend,
    // TODO: .linux   => VulkanRtBackend,
    else => MetalRtBackend, // stub — init() always returns null
};

/// 返回当前编译目标的 RT 后端名称 (用于 UI 显示)。
pub fn backendName() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "Metal RT",
        .windows => "Vulkan/DX12 RT (planned)",
        .linux => "Vulkan RT (planned)",
        else => "CPU",
    };
}

/// 纹理元数据 — 描述纹理在打包像素缓冲中的位置/尺寸
pub const RtTextureMeta = extern struct {
    offset: u32, // 字节偏移 (在打包 BGRA8 像素缓冲中)
    width: u32,
    height: u32,
    format: u32 = 0,
};

/// 采样表元数据 — 支持环境重要性数据与发光体采样表的通用上传。
pub const RtSamplingTableKind = enum(u32) {
    environment_importance = 0,
    emissive_light = 1,
};

pub const RtSamplingTableMeta = extern struct {
    offset: u32, // 字节偏移 (在打包采样表缓冲中)
    byte_size: u32,
    kind: u32,
    _pad: u32 = 0,
};

pub const max_directional_lights = 4;
pub const max_point_lights = 16;
pub const max_spot_lights = 16;

/// 光追三角形 — 与 C 桥接层 GuavaRTTriangle 完全对齐 (extern struct)。
pub const RtTriangle = extern struct {
    v0: [3]f32,
    v1: [3]f32,
    v2: [3]f32,
    n0: [3]f32,
    n1: [3]f32,
    n2: [3]f32,
    uv0: [2]f32 = .{ 0, 0 },
    uv1: [2]f32 = .{ 0, 0 },
    uv2: [2]f32 = .{ 0, 0 },
    albedo: [3]f32,
    emissive: [3]f32,
    metallic: f32,
    roughness: f32,
    transmission: f32 = 0.0,
    ior: f32 = 1.5,
    thickness: f32 = 0.0,
    base_color_texture_index: i32 = -1,
    metallic_roughness_texture_index: i32 = -1,
    normal_texture_index: i32 = -1,
    occlusion_texture_index: i32 = -1,
    emissive_texture_index: i32 = -1,
};

/// 光追渲染参数 — 与 C 桥接层 GuavaRTParams 完全对齐 (extern struct)。
pub const RtParams = extern struct {
    inv_view_projection: [16]f32,
    camera_origin: [3]f32,
    _pad0: f32 = 0,
    light_direction: [3]f32,
    /// 太阳角半径 (弧度)，控制软阴影半影宽度。0 = 硬阴影。
    sun_angular_radius: f32 = 0.0,
    width: u32,
    height: u32,
    samples: u32,
    bounces: u32,
    /// 0 = full path trace, 1 = shadow-only (输出屏幕空间阴影遮罩)
    mode: u32 = 0,
    /// shadow-only 每像素采样数 (1=硬阴影, 4+=软阴影)
    shadow_samples: u32 = 1,
    output_is_half: u32 = 0,
    environment_texture_index: i32 = -1,
    exposure_params: [4]f32 = .{ 0.0, 1.0, 0.0, 0.0 },
    color_grading_params: [4]f32 = .{ 0.0, 1.0, 1.0, 1.0 },
    directional_light_count: u32 = 0,
    point_light_count: u32 = 0,
    spot_light_count: u32 = 0,
    sampling_table_count: u32 = 0,
    directional_light_directions: [max_directional_lights][3]f32 = .{.{ 0.0, 0.0, 0.0 }} ** max_directional_lights,
    directional_light_radiance: [max_directional_lights][3]f32 = .{.{ 0.0, 0.0, 0.0 }} ** max_directional_lights,
    point_light_positions: [max_point_lights][3]f32 = .{.{ 0.0, 0.0, 0.0 }} ** max_point_lights,
    point_light_radiance: [max_point_lights][3]f32 = .{.{ 0.0, 0.0, 0.0 }} ** max_point_lights,
    point_light_ranges: [max_point_lights]f32 = .{0.0} ** max_point_lights,
    spot_light_positions: [max_spot_lights][3]f32 = .{.{ 0.0, 0.0, 0.0 }} ** max_spot_lights,
    spot_light_directions: [max_spot_lights][3]f32 = .{.{ 0.0, 0.0, -1.0 }} ** max_spot_lights,
    spot_light_radiance: [max_spot_lights][3]f32 = .{.{ 0.0, 0.0, 0.0 }} ** max_spot_lights,
    spot_light_ranges: [max_spot_lights]f32 = .{0.0} ** max_spot_lights,
    spot_light_inner_angle_cos: [max_spot_lights]f32 = .{1.0} ** max_spot_lights,
    spot_light_outer_angle_cos: [max_spot_lights]f32 = .{1.0} ** max_spot_lights,
    environment_importance_width: u32 = 0,
    environment_importance_height: u32 = 0,
    emissive_total_area: f32 = 0.0,
    /// 渐进式路径追踪帧索引（每帧递增，用于随机种子变化）
    frame_index: u32 = 0,
};

comptime {
    if (@sizeOf(RtParams) % 16 != 0) {
        @compileError("RtParams must stay 16-byte aligned for the Metal RT params buffer layout");
    }
}
