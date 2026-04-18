const std = @import("std");
const external_gfx_types = @import("guava_rhi").types;

pub const GraphicsAPI = external_gfx_types.GraphicsAPI;
pub const BackendSelectionPolicy = external_gfx_types.BackendSelectionPolicy;
pub const RuntimeInfo = external_gfx_types.RuntimeInfo;
pub const graphicsApiName = external_gfx_types.graphicsApiName;
pub const defaultPreferredBackends = external_gfx_types.defaultPreferredBackends;
pub const defaultBackendOrder = external_gfx_types.defaultBackendOrder;

pub const EditorViewportRenderMode = enum {
    textured,
    wireframe,
    unlit,
};

pub const EditorViewportPipelineMode = enum {
    raster,
    path_trace,
};

pub const EditorViewportLutPreset = enum {
    neutral,
    warm,
    cool,
    filmic,
};

pub const EditorViewportState = struct {
    pipeline_mode: EditorViewportPipelineMode = .raster,
    path_trace_samples: u32 = 4,
    path_trace_bounces: u32 = 2,
    path_trace_resolution_scale: f32 = 0.75,
    path_trace_force_cpu: bool = false,
    render_mode: EditorViewportRenderMode = .textured,
    show_grid: bool = true,
    show_bones: bool = false,
    show_collision: bool = false,
    show_collision_bvh: bool = false,
    show_constraints: bool = false,
    // 视口级曝光只影响编辑器预览，不写回场景相机资源。
    exposure_enabled: bool = false,
    exposure: f32 = 1.0,
    // Bloom 先作为视口级后处理 MVP，避免和场景相机资源耦合。
    bloom_enabled: bool = false,
    bloom_threshold: f32 = 1.0,
    bloom_intensity: f32 = 0.35,
    // SSAO 环境光遮蔽
    ssao_enabled: bool = false,
    ssao_radius: f32 = 0.5,
    ssao_bias: f32 = 0.025,
    ssao_intensity: f32 = 1.0,
    ssao_power: f32 = 2.0,
    // Contact Shadows 屏幕空间接触阴影
    contact_shadows_enabled: bool = false,
    contact_shadows_distance: f32 = 0.3,
    contact_shadows_thickness: f32 = 0.05,
    contact_shadows_intensity: f32 = 0.8,
    contact_shadows_bias: f32 = 0.01,
    contact_shadows_steps: u32 = 16,
    // SSR 屏幕空间反射
    ssr_enabled: bool = false,
    ssr_intensity: f32 = 0.5,
    ssr_ray_step: f32 = 0.1,
    ssr_ray_max_distance: f32 = 100.0,
    ssr_ray_thickness: f32 = 0.5,
    ssr_fade_distance: f32 = 10.0,
    ssr_edge_fade: f32 = 0.1,
    ssr_roughness_blur_strength: f32 = 0.0,

    // SSGI 屏幕空间全局光照
    ssgi_enabled: bool = false,
    ssgi_radius: f32 = 2.0,
    ssgi_intensity: f32 = 1.0,
    ssgi_bias: f32 = 0.05,
    ssgi_ray_count: u32 = 8,
    ssgi_step_count: u32 = 8,

    // TAA 时域抗锯齿
    taa_enabled: bool = false,
    taa_blend_factor: f32 = 0.1,
    taa_motion_blur_scale: f32 = 1.0,
    taa_feedback_min: f32 = 0.88,
    taa_feedback_max: f32 = 0.97,
    // DOF 景深
    dof_enabled: bool = false,
    dof_focus_distance: f32 = 10.0,
    dof_focus_range: f32 = 5.0,
    dof_blur_radius: f32 = 10.0,
    dof_bokeh_radius: f32 = 5.0,
    dof_near_blur: f32 = 0.0,
    dof_far_blur: f32 = 100.0,
    dof_quality: u32 = 4,
    // Omni Shadow 点光阴影
    omni_shadow_enabled: bool = false,
    omni_shadow_resolution: u32 = 512,
    omni_shadow_far_plane: f32 = 100.0,
    // Color Grading 先走参数级 MVP，LUT 后续单独补。
    color_grading_enabled: bool = false,
    color_grading_saturation: f32 = 1.0,
    color_grading_contrast: f32 = 1.0,
    color_grading_gamma: f32 = 1.0,
    fxaa_enabled: bool = false,
    // RT 增强阴影（光栅模式下用硬件 RT 替换 shadow map）
    rt_shadows_enabled: bool = false,
    rt_shadow_samples: u32 = 8,
    rt_shadow_strength: f32 = 0.85,
    rt_shadow_softness: f32 = 0.015,
    rt_shadow_resolution_scale: f32 = 1.0,
    // 体积雾
    volumetric_fog_enabled: bool = false,
    volumetric_fog_density: f32 = 0.02,
    volumetric_fog_height_falloff: f32 = 0.1,
    volumetric_fog_max_distance: f32 = 100.0,
    lut_enabled: bool = false,
    lut_intensity: f32 = 1.0,
    lut_preset: EditorViewportLutPreset = .neutral,
    // 渲染风格
    active_render_style: [64]u8 = blk: {
        var buf: [64]u8 = .{0} ** 64;
        const name = "default_pbr";
        @memcpy(buf[0..name.len], name);
        break :blk buf;
    },

    pub fn activeRenderStyleName(self: *const EditorViewportState) []const u8 {
        const len = std.mem.indexOfScalar(u8, &self.active_render_style, 0) orelse self.active_render_style.len;
        return self.active_render_style[0..len];
    }

    pub fn setActiveRenderStyle(self: *EditorViewportState, name: []const u8) void {
        @memset(&self.active_render_style, 0);
        const copy_len = @min(name.len, self.active_render_style.len);
        @memcpy(self.active_render_style[0..copy_len], name[0..copy_len]);
    }
};

pub const SceneSnapshot = struct {
    entity_count: usize = 0,
    camera_count: usize = 0,
    mesh_count: usize = 0,
    material_count: usize = 0,
    light_count: usize = 0,
};
