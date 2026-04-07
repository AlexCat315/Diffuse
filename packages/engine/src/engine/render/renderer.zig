//! 渲染系统核心模块
//!
//! 本模块提供完整的渲染管线实现，是 Guava Engine 渲染系统的核心。
//!
//! ## 渲染管线流程
//!
//! 1. **Depth Prepass** - 深度预通道，优化后续渲染
//! 2. **Shadow Pass** - 阴影贴图渲染
//! 3. **Base Pass** - 主渲染通道，渲染场景几何体
//! 4. **Skybox Pass** - 天空盒渲染
//! 5. **Bloom Pass** - 泛光后处理
//! 6. **FXAA Pass** - 快速近似抗锯齿
//! 7. **Tonemap Pass** - 色调映射
//! 8. **Gizmo Pass** - 编辑器 Gizmo 渲染
//! 9. **Outline Pass** - 选中物体轮廓
//! 10. **ID Pass** - 物体 ID 拾取（用于编辑器选择）
//!
//! ## 主要功能
//!
//! - **设备管理** - 创建和管理 GPU 设备
//! - **资源管理** - 纹理、缓冲区、管线等 GPU 资源
//! - **渲染图** - 自动管理渲染通道依赖
//! - **场景提取** - 视锥剔除和场景数据准备
//! - **后处理** - Bloom、FXAA、色调映射等效果
//! - **编辑器支持** - Gizmo、选择高亮、ID 拾取
//!
//! ## 使用示例
//!
//! ```zig
//! // 创建渲染器配置
//! const config = RendererConfig{
//!     .requested_backends = &.{.metal, .vulkan},
//!     .enable_validation = true,
//! };
//!
//! // 初始化渲染器
//! var renderer = try Renderer.init(allocator, config);
//! defer renderer.deinit();
//!
//! // 渲染帧
//! const report = try renderer.drawFrame(&world, viewport_state);
//! ```

const std = @import("std");
const assets_lib = @import("../assets/library.zig");
const material_ast_mod = @import("../assets/material_ast.zig");
const mesh_resource_mod = @import("../assets/mesh_resource.zig");
const handles = @import("../assets/handles.zig");
const base_pass_mod = @import("passes/base_pass.zig");
const shadow_pass_mod = @import("passes/shadow_pass.zig");
const skybox_pass_mod = @import("passes/skybox_pass.zig");
const bloom_pass_mod = @import("passes/bloom_pass.zig");
const tonemap_pass_mod = @import("passes/tonemap_pass.zig");
const depth_prepass_mod = @import("passes/depth_prepass.zig");
const velocity_pass_mod = @import("passes/velocity_pass.zig");
const id_pass_mod = @import("passes/id_pass.zig");
const gizmo_pass_mod = @import("passes/gizmo_pass.zig");
const outline_pass_mod = @import("passes/outline_pass.zig");
const volumetric_fog_pass_mod = @import("passes/volumetric_fog_pass.zig");
const ssao_compute_pass_mod = @import("passes/ssao_compute_pass_runtime.zig");
const ssgi_compute_pass_mod = @import("passes/ssgi_compute_pass.zig");
const ssgi_composite_pass_mod = @import("passes/ssgi_composite_pass.zig");
const ibl_compute_pass_mod = @import("passes/ibl_compute_pass.zig");
const contact_shadow_pass_mod = @import("passes/contact_shadow_pass.zig");
const cluster_lights_pass_mod = @import("passes/cluster_lights_pass.zig");
const taa_pass_mod = @import("passes/taa_pass.zig");
const rt_shadow_composite_pass_mod = @import("passes/rt_shadow_composite_pass.zig");
const rt_shadow_denoise_pass_mod = @import("passes/rt_shadow_denoise_pass.zig");
const path_trace_denoise = @import("path_trace/path_trace_denoise.zig");
const image_export = @import("image_export.zig");
const dof_pass_mod = @import("passes/dof_pass.zig");
const dof_runtime_pass_mod = @import("passes/dof_runtime_pass.zig");
const ssr_pass_mod = @import("passes/ssr_pass.zig");
const ssr_blur_pass_mod = @import("passes/ssr_blur_pass.zig");
const style_plugin_mod = @import("style_plugin.zig");
const plugin_mod = @import("../plugin/plugin.zig");
const loader_mod = @import("../plugin/loader.zig");
const fullscreen_post_mod = @import("passes/fullscreen_post_pass.zig");
const fxaa_pass_mod = @import("passes/fxaa_pass.zig");
const platform_mod = @import("../core/platform.zig");
const selection_history_mod = @import("selection_history.zig");
const window_mod = @import("../platform/window.zig");
const graph_mod = @import("render_graph.zig");
const mesh_pass_mod = @import("passes/mesh_pass.zig");
const scene_extraction = @import("scene_extraction.zig");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");
const rhi_api = @import("../rhi/rhi.zig");
const rhi_mock_backend_mod = @import("../rhi/metal/metal_backend.zig");
const metal_device_mod = @import("../rhi/metal/metal_device.zig");
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");
const types = @import("types.zig");
const AABB = @import("../math/aabb.zig").AABB;
const frustum_mod = @import("../math/frustum.zig");
const mat4_mod = @import("../math/mat4.zig");
const vec3 = @import("../math/vec3.zig");
const physics_mod = @import("../physics/system.zig");
const PassDescriptors = @import("render_helpers.zig").PassDescriptors;
const render_log = std.log.scoped(.viewport_render);
const rt_backend = @import("../rt/rt_backend.zig");
const renderer_environment = @import("renderer_environment.zig");
const renderer_path_trace = @import("path_trace/renderer_path_trace.zig");
const renderer_resources = @import("renderer_resources.zig");
const renderer_thumbnails = @import("renderer_thumbnails.zig");

const renderer_export = @import("renderer_export.zig");
const renderer_debug = @import("renderer_debug.zig");
const renderer_shadow_cascade = @import("renderer_shadow_cascade.zig");
const renderer_selection = @import("renderer_selection.zig");

/// 是否已记录视口后端日志
var g_logged_viewport_backend: bool = false;
/// 已记录的后处理状态
var g_logged_postfx_state: ?types.EditorViewportState = null;
/// 是否已记录场景提取剔除日志
var g_logged_scene_extraction_culling: bool = false;
/// 已记录的碰撞覆盖盒数量
var g_logged_collision_overlay_boxes: ?usize = null;
/// 是否已记录 CPU PathTrace 激活日志
var g_logged_path_trace_active: bool = false;

const CachedEnvironmentTextures = renderer_environment.CachedEnvironmentTextures;

/// 图形 API 类型
pub const GraphicsAPI = rhi_types.GraphicsAPI;
/// 运行时信息
pub const RuntimeInfo = rhi_types.RuntimeInfo;
/// 选择历史管理
pub const SelectionHistory = selection_history_mod.SelectionHistory;
/// 选择更新模式
pub const SelectionUpdateMode = selection_history_mod.SelectionUpdateMode;
pub const PathTraceRenderProgress = struct {
    active: bool = false,
    complete: bool = false,
    uses_hw_rt: bool = false,
    fraction: f32 = 0.0,
    trace_width: u32 = 0,
    trace_height: u32 = 0,
};
/// 编辑器 Gizmo 状态
pub const EditorGizmoState = gizmo_pass_mod.EditorGizmoState;
pub const EditorGizmoMode = gizmo_pass_mod.EditorGizmoMode;
pub const EditorGizmoSpace = gizmo_pass_mod.EditorGizmoSpace;
/// 编辑器视口状态
pub const EditorViewportState = types.EditorViewportState;

/// 渲染器配置
///
/// 用于初始化渲染器时指定各种参数。
pub const RendererConfig = struct {
    /// 请求的图形后端列表（按优先级排序）
    requested_backends: []const rhi_types.GraphicsAPI = &.{},
    /// 后端选择策略
    selection_policy: rhi_types.BackendSelectionPolicy = .explicit_order,
    /// 是否启用验证层（调试用）
    enable_validation: bool = true,
    /// 帧在飞数量（用于帧同步）
    frames_in_flight: u32 = 2,
};

/// 帧报告
///
/// 包含一帧渲染的统计信息，用于性能分析和调试。
pub const FrameReport = struct {
    /// 使用的图形后端
    backend: types.GraphicsAPI,
    /// 执行的渲染通道数量
    passes_executed: usize,
    /// 渲染图资源数量
    graph_resources: usize,
    /// 场景快照
    scene: types.SceneSnapshot,
    /// 运行时信息
    runtime: types.RuntimeInfo,
    /// 绘制调用次数
    draw_calls: usize = 0,
    /// 绘制的三角形数量
    triangles_drawn: usize = 0,
    /// RHI BindingSet 缓存命中次数
    binding_cache_hits: u64 = 0,
    /// RHI BindingSet 缓存未命中次数
    binding_cache_misses: u64 = 0,
    /// RHI slot-layout 校验失败数
    slot_layout_errors: usize = 0,
    /// 本帧 RHI 缓存命中增量
    binding_cache_hits_delta: u64 = 0,
    /// 本帧 RHI 缓存未命中增量
    binding_cache_misses_delta: u64 = 0,
    /// 本帧 RHI 缓存淘汰增量
    binding_cache_evictions_delta: u64 = 0,
};

const SelectionReadbackRequest = renderer_selection.SelectionReadbackRequest;
const InFlightSelectionReadback = renderer_selection.InFlightSelectionReadback;
const InFlightSelectionBatch = renderer_selection.InFlightSelectionBatch;

/// 构建场景提取视锥体
///
/// 从主相机计算视锥体，用于视锥剔除。
fn buildSceneExtractionFrustum(
    scene_cache: *mesh_pass_mod.MeshSceneCache,
    world: *const scene_mod.World,
    width: u32,
    height: u32,
) ?frustum_mod.Frustum {
    if (width == 0 or height == 0) return null;
    const camera_id = world.primaryCameraEntity() orelse return null;
    const camera_entity = world.getEntityConst(camera_id) orelse return null;
    const camera_component = camera_entity.camera orelse return null;
    const world_transform = world.worldTransformConst(camera_id) orelse camera_entity.local_transform;
    const camera_block = mesh_pass_mod.CameraBlock{
        .transform = world_transform,
        .camera = camera_component,
        .is_primary = camera_component.is_primary,
    };
    const view_projection = scene_cache.calculateViewProjection(camera_block, width, height);
    return frustum_mod.Frustum.fromViewProjection(view_projection);
}

fn previewRenderMode(render_mode: types.EditorViewportRenderMode) types.EditorViewportRenderMode {
    return render_mode;
}

fn effectiveViewportRenderMode(state: types.EditorViewportState) types.EditorViewportRenderMode {
    if (state.pipeline_mode == .path_trace) {
        // PathTrace 模式下仍返回 textured，以保持依赖渲染模式分支的代码路径稳定。
        return .textured;
    }
    return state.render_mode;
}

const PathTraceTriangle = renderer_path_trace.PathTraceTriangle;
const PathTraceTexture = renderer_path_trace.PathTraceTexture;
const PathTraceEnvironment = renderer_path_trace.PathTraceEnvironment;
const PathTraceTextureIndices = renderer_path_trace.PathTraceTextureIndices;
const PathTraceMaterialSample = renderer_path_trace.PathTraceMaterialSample;
const PathTracePrimaryRay = renderer_path_trace.PathTracePrimaryRay;
const PathTraceGuidePixel = renderer_path_trace.PathTraceGuidePixel;
const PathTraceGuideBuffers = renderer_path_trace.PathTraceGuideBuffers;
const PathTraceEnvImportance = renderer_path_trace.PathTraceEnvImportance;
const PathTraceEmissiveLight = renderer_path_trace.PathTraceEmissiveLight;
const PathTracePointLight = renderer_path_trace.PathTracePointLight;
const PathTraceSpotLight = renderer_path_trace.PathTraceSpotLight;
const PathTraceMesh = renderer_path_trace.PathTraceMesh;
const PathTraceProgressiveState = renderer_path_trace.PathTraceProgressiveState;
const path_trace_adaptive_tile_dim = renderer_path_trace.path_trace_adaptive_tile_dim;
const path_trace_adaptive_tile_capacity = renderer_path_trace.path_trace_adaptive_tile_capacity;
const PathTraceAdaptiveTileBlock = renderer_path_trace.PathTraceAdaptiveTileBlock;
const HwRtState = renderer_path_trace.HwRtState;

const resolvePathTraceEnvironment = renderer_environment.resolvePathTraceEnvironment;
const reflectVector = renderer_path_trace.reflectVector;
const computePathTraceSceneSignature = renderer_path_trace.computePathTraceSceneSignature;
const transformPoint = renderer_path_trace.transformPoint;
const transformNormal = renderer_path_trace.transformNormal;
const resolvePathTraceTextureIndices = renderer_path_trace.resolvePathTraceTextureIndices;
const buildPathTraceEmissiveLights = renderer_path_trace.buildPathTraceEmissiveLights;
const buildHwRtEmissiveLights = renderer_path_trace.buildHwRtEmissiveLights;
const buildPathTraceEnvironmentImportance = renderer_path_trace.buildPathTraceEnvironmentImportance;
const buildHwRtSamplingTables = renderer_path_trace.buildHwRtSamplingTables;
const sceneNeedsCpuPathTraceMaterialFallback = renderer_path_trace.sceneNeedsCpuPathTraceMaterialFallback;
const pathTraceAdaptiveMinSamples = renderer_path_trace.pathTraceAdaptiveMinSamples;
const pathTraceAdaptiveNoiseMetric = renderer_path_trace.pathTraceAdaptiveNoiseMetric;
const pathTraceAdaptiveTargetSamples = renderer_path_trace.pathTraceAdaptiveTargetSamples;
const pathTraceAdaptiveTileSpan = renderer_path_trace.pathTraceAdaptiveTileSpan;
const pathTraceRussianRouletteSurvivalProbability = renderer_path_trace.pathTraceRussianRouletteSurvivalProbability;
const advancePathTraceTileCursor = renderer_path_trace.advancePathTraceTileCursor;
const computePathTraceSampleStep = renderer_path_trace.computePathTraceSampleStep;
const tracePathTracePixelSample = renderer_path_trace.tracePathTracePixelSample;
const samplePathTraceGuidePixel = renderer_path_trace.samplePathTraceGuidePixel;
const luminance = renderer_path_trace.luminance;
const hashUnitFloat = renderer_path_trace.hashUnitFloat;
const sampleGGXVisibleHalfVector = renderer_path_trace.sampleGGXVisibleHalfVector;
const ggxSpecularPdf = renderer_path_trace.ggxSpecularPdf;
const samplePathTraceMaterial = renderer_path_trace.samplePathTraceMaterial;
const applyPathTraceRussianRoulette = renderer_path_trace.applyPathTraceRussianRoulette;
const makeOwnedTestAssetRecord = renderer_thumbnails.makeOwnedTestAssetRecord;

const SceneViewportState = renderer_resources.SceneViewportState;
const csm_cascade_count = renderer_resources.csm_cascade_count;
const ShadowMapState = renderer_resources.ShadowMapState;

const material_thumbnail_dimension = renderer_thumbnails.material_thumbnail_dimension;
const material_thumbnail_jobs_per_frame = renderer_thumbnails.material_thumbnail_jobs_per_frame;
const material_thumbnail_cache_limit = renderer_thumbnails.material_thumbnail_cache_limit;
const selection_readback_bytes: u32 = 4;
const material_thumbnail_clear_color = renderer_thumbnails.material_thumbnail_clear_color;
const ghost_preview_tint_color = [4]f32{ 0.72, 0.86, 0.78, 0.14 };
const ghost_preview_tint_strength: f32 = 0.12;
const thumbnail_viewport_state = renderer_thumbnails.thumbnail_viewport_state;
const MaterialThumbnailTextureFingerprint = renderer_thumbnails.MaterialThumbnailTextureFingerprint;
const MaterialThumbnailSignature = renderer_thumbnails.MaterialThumbnailSignature;
const MaterialThumbnailSource = renderer_thumbnails.MaterialThumbnailSource;
const ThumbnailRenderTarget = renderer_thumbnails.ThumbnailRenderTarget;
const MaterialThumbnailCacheEntry = renderer_thumbnails.MaterialThumbnailCacheEntry;
const MaterialThumbnailPreview = renderer_thumbnails.MaterialThumbnailPreview;
const ModelThumbnailCacheEntry = renderer_thumbnails.ModelThumbnailCacheEntry;
const makeMaterialThumbnailSourceFromAst = renderer_thumbnails.makeMaterialThumbnailSourceFromAst;
const resolveMaterialThumbnailSource = renderer_thumbnails.resolveMaterialThumbnailSource;

pub const Renderer = struct {
    /// 内存分配器
    allocator: std.mem.Allocator,
    /// 平台抽象
    platform: platform_mod.Platform,
    /// RHI 设备（GPU 资源管理）
    rhi: rhi_mod.RhiDevice,
    /// 渲染图（管理渲染通道依赖）
    graph: graph_mod.RenderGraph,
    /// 场景缓存（优化场景数据访问）
    scene_cache: mesh_pass_mod.MeshSceneCache,
    /// AI staged preview 场景缓存
    preview_scene_cache: mesh_pass_mod.MeshSceneCache,
    /// 缩略图场景缓存
    thumbnail_scene_cache: mesh_pass_mod.MeshSceneCache,
    /// 渲染世界（提取的场景数据）
    render_world: scene_extraction.RenderWorld,
    /// staged preview 渲染世界
    preview_render_world: scene_extraction.RenderWorld,
    /// 缩略图渲染世界
    thumbnail_render_world: scene_extraction.RenderWorld,
    /// ID 拾取通道（用于编辑器选择）
    id_pass: id_pass_mod.IdPass,
    /// 深度预通道（优化后续渲染）
    depth_prepass: depth_prepass_mod.DepthPrepass,
    /// Velocity 通道（TAA motion vectors）
    velocity_pass: velocity_pass_mod.VelocityPass,
    /// 阴影通道（阴影贴图渲染）
    shadow_pass: shadow_pass_mod.ShadowPass,
    /// 基础通道（主渲染）
    base_pass: base_pass_mod.BasePass,
    /// 渲染风格插件注册表
    style_registry: style_plugin_mod.StyleRegistry,
    /// 统一插件注册表（发现 + 生命周期管理）
    plugin_registry: plugin_mod.PluginRegistry,
    /// Type-erased loader dispatch table (render_style, etc.)
    typed_loader_registry: loader_mod.TypedLoaderRegistry,
    /// Plugin hot-reload manager (polls manifests for changes)
    plugin_hot_reload: plugin_mod.PluginHotReloadManager,
    /// 天空盒通道
    skybox_pass: ?skybox_pass_mod.SkyboxPass = null,
    skybox_logged: bool = false,
    skybox_log_count: u32 = 0,
    /// 轮廓通道（选中物体高亮）
    outline_pass: outline_pass_mod.OutlinePass,
    /// Gizmo 通道（编辑器可视化）
    gizmo_pass: gizmo_pass_mod.GizmoPass,
    /// SSAO Compute 通道（GPU Compute 加速）
    ssao_compute_pass: ?ssao_compute_pass_mod.SSAOComputePass = null,
    /// Clustered Forward+ 光源裁剪 Compute 通道
    cluster_lights_pass: ?cluster_lights_pass_mod.ClusterLightsPass = null,
    /// Contact Shadows 屏幕空间接触阴影通道
    contact_shadow_pass: contact_shadow_pass_mod.ContactShadowPass,
    ssgi_compute_pass: ?ssgi_compute_pass_mod.SSGIComputePass = null,
    ssgi_composite_pass: ssgi_composite_pass_mod.SSGICompositePass,
    /// RHI 设备（抽象后端）
    rhi_device: ?*rhi_api.Device = null,
    /// RHI mock 后端存储（仅测试用；生产环境使用 real Metal）
    rhi_mock_backend: ?*rhi_mock_backend_mod.MetalBackend = null,
    /// Real Metal backend device（生产环境使用）
    rhi_metal_device: ?*metal_device_mod.MetalDevice = null,
    /// Platform metal layer binding（需要在 deinit 时销毁）
    metal_layer_binding: ?window_mod.MetalLayerBinding = null,
    /// IBL Compute 通道（GPU Compute 加速 BRDF LUT + Irradiance）
    ibl_compute_pass: ?ibl_compute_pass_mod.IBLComputePass = null,
    /// GPU 生成的 BRDF LUT 纹理（256x256 RGBA16F）
    gpu_brdf_lut: ?rhi_mod.Texture = null,
    /// GPU BRDF LUT 是否已生成
    gpu_brdf_lut_generated: bool = false,
    /// TAA 抗锯齿通道
    taa_pass: taa_pass_mod.TAAPass,
    /// SSR 屏幕空间反射通道
    ssr_pass: ssr_pass_mod.SSRPass,
    /// SSR 粗糙度模糊通道
    ssr_blur_pass: ssr_blur_pass_mod.SSRBlurPass,
    /// Bloom 后处理通道
    bloom_pass: bloom_pass_mod.BloomPass,
    /// Tonemap 后处理通道
    tonemap_pass: tonemap_pass_mod.TonemapPass,
    /// DOF 景深通道（运行时实现）
    dof_runtime_pass: dof_runtime_pass_mod.DofRuntimePass,
    /// FXAA 抗锯齿通道
    fxaa_pass: fxaa_pass_mod.FxaaPass,
    /// RT 阴影合成通道
    rt_shadow_composite_pass: rt_shadow_composite_pass_mod.RtShadowCompositePass,
    /// RT 阴影双边去噪通道
    rt_shadow_denoise_pass: rt_shadow_denoise_pass_mod.RtShadowDenoisePass,
    /// SSAO 环境光遮蔽合成通道 — 将 SSAO 纹理以乘法混合叠加到 HDR 缓冲
    ssao_composite_pass: rt_shadow_composite_pass_mod.RtShadowCompositePass,
    /// Contact Shadows 合成通道 — 将接触阴影遮罩以乘法混合叠加到 HDR 缓冲
    contact_shadow_composite_pass: rt_shadow_composite_pass_mod.RtShadowCompositePass,
    /// RT 阴影遮罩纹理（屏幕分辨率，BGRA8）
    rt_shadow_mask_texture: ?rhi_mod.Texture = null,
    /// RT 阴影遮罩像素缓冲 (CPU 侧)
    rt_shadow_pixels: ?[]u8 = null,
    rt_shadow_width: u32 = 0,
    rt_shadow_height: u32 = 0,
    rt_shadow_last_vp: [16]f32 = mat4_mod.identity(),
    /// 选择历史管理
    selection_history: SelectionHistory,
    /// 选择是否已初始化
    selection_seeded: bool = false,
    /// 编辑器 Gizmo 状态
    editor_gizmo_state: EditorGizmoState = .{},
    /// RPC 设置的待消费 gizmo 模式（由 EditorLayer.refreshGizmoState 消费）
    pending_gizmo_mode: ?EditorGizmoMode = null,
    pending_gizmo_space: ?EditorGizmoSpace = null,
    /// RPC 设置的待消费相机操作（由 handleCameraControls 消费）
    pending_camera_orbit: ?[2]f32 = null, // [deltaYaw, deltaPitch]
    pending_camera_look_axis: ?[3]f32 = null, // look direction for ViewCube axis click
    /// When true, resolveSelectionReadbacks skips applying picks (gizmo drag active).
    suppress_entity_pick: bool = false,
    /// RPC 设置的待消费帧延迟（由 Application 主循环消费）。
    /// null = 不变更，0 = 不限制（VSync），>0 = 目标帧间隔毫秒数。
    pending_frame_delay_ms: ?u32 = null,
    /// 当前生效的帧延迟（由 Application 写入，供 RPC 读取）。
    current_frame_delay_ms: u32 = 16,
    /// 上一帧渲染统计（由 Application 在 drawFrame 后写入，供 RPC metrics 广播读取）。
    last_frame_report: FrameReport = .{
        .backend = .metal,
        .passes_executed = 0,
        .graph_resources = 0,
        .scene = .{},
        .runtime = .{},
    },
    /// 编辑器变换枢轴覆盖（例如 bounds center）
    editor_gizmo_transform_override: ?components.Transform = null,
    /// staged preview 的自定义 gizmo 目标
    preview_gizmo_transform: ?components.Transform = null,
    /// staged preview 根实体过滤列表
    preview_entity_filter: std.ArrayList(scene_mod.EntityId) = .empty,
    /// 编辑器视口状态
    editor_viewport_state: EditorViewportState = .{},
    /// Sequencer 相机路径预览线段（由编辑器每帧设置）
    camera_path_preview_lines: std.ArrayListUnmanaged(gizmo_pass_mod.WorldLineVertex) = .empty,
    /// Mesh edit overlay — all edges of the mesh being edited (wireframe)
    mesh_edit_wireframe_lines: std.ArrayListUnmanaged(gizmo_pass_mod.WorldLineVertex) = .empty,
    /// Mesh edit overlay — highlighted lines for selected elements
    mesh_edit_selected_lines: std.ArrayListUnmanaged(gizmo_pass_mod.WorldLineVertex) = .empty,
    /// Mesh edit overlay — vertex position markers (small crosshairs)
    mesh_edit_vertex_lines: std.ArrayListUnmanaged(gizmo_pass_mod.WorldLineVertex) = .empty,
    /// Mesh edit overlay — billboard dot for each unselected vertex / face centroid
    mesh_edit_vtx_dot_positions: std.ArrayListUnmanaged(gizmo_pass_mod.WorldLineVertex) = .empty,
    /// Mesh edit overlay — billboard dot for each selected vertex / face centroid (gold)
    mesh_edit_sel_dot_positions: std.ArrayListUnmanaged(gizmo_pass_mod.WorldLineVertex) = .empty,
    /// 前一帧视图矩阵（TAA 重投影用）
    prev_view_matrix: [16]f32 = mat4_mod.identity(),
    /// 前一帧未抖动的 view-projection（velocity / TAA history reproject）
    prev_view_projection: [16]f32 = mat4_mod.identity(),
    /// 前一帧归一化 jitter 偏移
    prev_taa_jitter: [2]f32 = .{ 0.0, 0.0 },
    /// 前一帧实体 model matrix 缓存（rigid motion vectors）
    prev_mesh_models: std.AutoHashMap(scene_mod.EntityId, [16]f32),
    /// 缓存的环境贴图纹理指针（避免每帧重新加载 IBL 数据）
    cached_env_textures: CachedEnvironmentTextures = .{},
    /// 待处理的选择回读请求
    pending_selection_readbacks: std.ArrayList(SelectionReadbackRequest) = .empty,
    /// 飞行中的选择批次
    in_flight_selection_batches: std.ArrayList(InFlightSelectionBatch) = .empty,
    /// 场景视口状态（纹理等）
    scene_viewport: SceneViewportState = .{},
    /// 阴影贴图状态
    shadow_map: ShadowMapState = .{},
    /// 材质缩略图预览
    material_thumbnail_preview: MaterialThumbnailPreview,
    /// 材质编辑器独立预览离屏目标
    material_editor_preview_target: ThumbnailRenderTarget,
    /// 材质编辑器预览签名
    material_editor_preview_signature: MaterialThumbnailSignature = .{},
    /// 材质编辑器预览图元
    material_editor_preview_primitive: components.Primitive = .sphere,
    /// 材质编辑器预览是否需要重绘
    material_editor_preview_dirty: bool = true,
    /// 材质编辑器预览贴图是否已就绪
    material_editor_preview_ready: bool = false,
    /// 本帧是否请求了材质编辑器预览
    material_editor_preview_requested: bool = false,
    /// 材质缩略图缓存
    material_thumbnail_cache: std.StringHashMap(MaterialThumbnailCacheEntry) = undefined,
    /// 材质缩略图请求队列
    material_thumbnail_requests: std.ArrayList([]u8) = .empty,
    /// 模型缩略图缓存
    model_thumbnail_cache: std.StringHashMap(ModelThumbnailCacheEntry) = undefined,
    /// 模型缩略图请求队列
    model_thumbnail_requests: std.ArrayList([]u8) = .empty,
    /// 模型缩略图场景缓存
    model_thumbnail_scene_cache: mesh_pass_mod.MeshSceneCache,
    /// 模型缩略图渲染世界
    model_thumbnail_render_world: scene_extraction.RenderWorld,
    /// 编辑器 staged preview scene
    preview_scene: ?*const scene_mod.Scene = null,
    /// AI Ghost Highlight: 实体 ID 列表（最多 16 个），显示紫色呼吸灯轮廓
    ai_focus_entity_ids: [16]scene_mod.EntityId = .{0} ** 16,
    ai_focus_entity_count: usize = 0,
    /// 渐进式 CPU 路径追踪状态
    path_trace_state: PathTraceProgressiveState = .{},
    /// 硬件 RT 渲染状态
    hw_rt_state: HwRtState = .{},
    /// 是否为编辑器模式（player 模式下禁用 debug 覆盖层）
    is_editor_mode: bool = true,

    /// 初始化渲染器
    ///
    /// ## 参数
    /// - `allocator` - 内存分配器
    /// - `platform` - 平台抽象
    /// - `window` - 窗口（用于创建交换链）
    /// - `config` - 渲染器配置
    ///
    /// ## 返回
    /// 初始化的 Renderer 实例
    ///
    /// ## 错误
    /// - `error.OutOfMemory` - 内存不足
    /// - `error.DeviceCreationFailed` - GPU 设备创建失败
    pub fn init(
        allocator: std.mem.Allocator,
        platform: platform_mod.Platform,
        window: *window_mod.Window,
        config: RendererConfig,
    ) !Renderer {
        var renderer = Renderer{
            .allocator = allocator,
            .platform = platform,
            .rhi = try rhi_mod.RhiDevice.init(
                allocator,
                platform,
                window,
                .{
                    .preferred_backends = config.requested_backends,
                    .selection_policy = config.selection_policy,
                    .enable_validation = config.enable_validation,
                    .frames_in_flight = config.frames_in_flight,
                },
            ),
            .graph = try graph_mod.RenderGraph.initDefault3D(allocator),
            .scene_cache = undefined,
            .preview_scene_cache = undefined,
            .thumbnail_scene_cache = undefined,
            .render_world = scene_extraction.RenderWorld.init(allocator),
            .preview_render_world = scene_extraction.RenderWorld.init(allocator),
            .thumbnail_render_world = scene_extraction.RenderWorld.init(allocator),
            .id_pass = undefined,
            .depth_prepass = undefined,
            .velocity_pass = undefined,
            .shadow_pass = undefined,
            .base_pass = undefined,
            .style_registry = undefined,
            .plugin_registry = undefined,
            .typed_loader_registry = undefined,
            .plugin_hot_reload = undefined,
            .skybox_pass = undefined,
            .outline_pass = undefined,
            .gizmo_pass = undefined,
            .ssao_compute_pass = null,
            .contact_shadow_pass = undefined,
            .ssgi_compute_pass = null,
            .ssgi_composite_pass = undefined,
            .ibl_compute_pass = null,
            .taa_pass = undefined,
            .ssr_pass = undefined,
            .ssr_blur_pass = undefined,
            .bloom_pass = undefined,
            .tonemap_pass = undefined,
            .dof_runtime_pass = undefined,
            .fxaa_pass = undefined,
            .rt_shadow_composite_pass = undefined,
            .rt_shadow_denoise_pass = undefined,
            .ssao_composite_pass = undefined,
            .contact_shadow_composite_pass = undefined,
            .prev_mesh_models = std.AutoHashMap(scene_mod.EntityId, [16]f32).init(allocator),
            .selection_history = SelectionHistory.init(allocator, 64),
            .material_thumbnail_cache = std.StringHashMap(MaterialThumbnailCacheEntry).init(allocator),
            .material_thumbnail_preview = undefined,
            .material_editor_preview_target = undefined,
            .model_thumbnail_cache = std.StringHashMap(ModelThumbnailCacheEntry).init(allocator),
            .model_thumbnail_scene_cache = undefined,
            .model_thumbnail_render_world = scene_extraction.RenderWorld.init(allocator),
        };
        errdefer renderer.prev_mesh_models.deinit();
        errdefer renderer.material_thumbnail_cache.deinit();
        errdefer renderer.model_thumbnail_cache.deinit();
        errdefer renderer.in_flight_selection_batches.deinit(allocator);
        errdefer renderer.pending_selection_readbacks.deinit(allocator);
        errdefer renderer.selection_history.deinit();
        errdefer renderer.graph.deinit();
        errdefer renderer.rhi.deinit();

        renderer.scene_cache = try mesh_pass_mod.MeshSceneCache.init(allocator, &renderer.rhi);
        errdefer renderer.scene_cache.deinit(&renderer.rhi);

        renderer.preview_scene_cache = try mesh_pass_mod.MeshSceneCache.init(allocator, &renderer.rhi);
        errdefer renderer.preview_scene_cache.deinit(&renderer.rhi);

        renderer.thumbnail_scene_cache = try mesh_pass_mod.MeshSceneCache.init(allocator, &renderer.rhi);
        errdefer renderer.thumbnail_scene_cache.deinit(&renderer.rhi);

        renderer.model_thumbnail_scene_cache = try mesh_pass_mod.MeshSceneCache.init(allocator, &renderer.rhi);
        errdefer renderer.model_thumbnail_scene_cache.deinit(&renderer.rhi);

        renderer.material_thumbnail_preview = try MaterialThumbnailPreview.init(allocator);
        errdefer renderer.material_thumbnail_preview.deinit();

        renderer.material_editor_preview_target = try ThumbnailRenderTarget.init(&renderer.rhi);
        errdefer renderer.material_editor_preview_target.deinit(&renderer.rhi);

        renderer.id_pass = try id_pass_mod.IdPass.init(&renderer.rhi);
        errdefer renderer.id_pass.deinit(&renderer.rhi);

        renderer.depth_prepass = try depth_prepass_mod.DepthPrepass.init(&renderer.rhi);
        errdefer renderer.depth_prepass.deinit(&renderer.rhi);

        renderer.velocity_pass = try velocity_pass_mod.VelocityPass.init(&renderer.rhi);
        errdefer renderer.velocity_pass.deinit(&renderer.rhi);

        renderer.shadow_pass = try shadow_pass_mod.ShadowPass.init(&renderer.rhi);
        errdefer renderer.shadow_pass.deinit(&renderer.rhi);

        renderer.shadow_map = try ShadowMapState.init(&renderer.rhi);
        errdefer renderer.shadow_map.deinit(&renderer.rhi);

        renderer.base_pass = try base_pass_mod.BasePass.init(&renderer.rhi);
        errdefer renderer.base_pass.deinit(&renderer.rhi);

        renderer.style_registry = style_plugin_mod.StyleRegistry.init(allocator);

        renderer.plugin_registry = try plugin_mod.PluginRegistry.init(allocator);

        renderer.typed_loader_registry = loader_mod.TypedLoaderRegistry.init(allocator);
        renderer.typed_loader_registry.register(.render_style, renderer.style_registry.pluginLoader()) catch |err| {
            render_log.err("failed to register render style loader: {s}", .{@errorName(err)});
        };

        renderer.plugin_hot_reload = plugin_mod.PluginHotReloadManager.init(allocator);

        renderer.skybox_pass = try skybox_pass_mod.SkyboxPass.init(&renderer.rhi);
        errdefer if (renderer.skybox_pass) |*pass| {
            pass.deinit(&renderer.rhi);
        };

        renderer.ssao_compute_pass = ssao_compute_pass_mod.SSAOComputePass.init(&renderer.rhi) catch |err| blk: {
            std.log.warn("SSAO compute pass init failed: {}", .{err});
            break :blk null;
        };

        renderer.cluster_lights_pass = cluster_lights_pass_mod.ClusterLightsPass.init(&renderer.rhi) catch |err| blk: {
            std.log.warn("Cluster lights pass init failed (clustered Forward+ disabled): {}", .{err});
            break :blk null;
        };

        renderer.contact_shadow_pass = try contact_shadow_pass_mod.ContactShadowPass.init(&renderer.rhi);
        errdefer renderer.contact_shadow_pass.deinit(&renderer.rhi);

        renderer.ibl_compute_pass = blk: {
            const p = ibl_compute_pass_mod.IBLComputePass.init(&renderer.rhi);
            if (!p.hasBRDF() and !p.hasIrradiance()) {
                std.log.warn("IBL compute pass: no pipelines available, GPU IBL disabled", .{});
                break :blk null;
            }
            break :blk p;
        };

        renderer.taa_pass = try taa_pass_mod.TAAPass.init(&renderer.rhi);
        errdefer renderer.taa_pass.deinit(&renderer.rhi);

        renderer.ssr_pass = try ssr_pass_mod.SSRPass.init(&renderer.rhi);
        errdefer renderer.ssr_pass.deinit(&renderer.rhi);

        renderer.ssr_blur_pass = try ssr_blur_pass_mod.SSRBlurPass.init(&renderer.rhi);
        errdefer renderer.ssr_blur_pass.deinit(&renderer.rhi);

        renderer.bloom_pass = try bloom_pass_mod.BloomPass.init(&renderer.rhi);
        errdefer renderer.bloom_pass.deinit(&renderer.rhi);

        renderer.tonemap_pass = try tonemap_pass_mod.TonemapPass.init(&renderer.rhi);
        errdefer renderer.tonemap_pass.deinit(&renderer.rhi);

        renderer.dof_runtime_pass = try dof_runtime_pass_mod.DofRuntimePass.init(&renderer.rhi);
        errdefer renderer.dof_runtime_pass.deinit(&renderer.rhi);

        renderer.fxaa_pass = try fxaa_pass_mod.FxaaPass.init(&renderer.rhi);
        errdefer renderer.fxaa_pass.deinit(&renderer.rhi);

        renderer.rt_shadow_composite_pass = try rt_shadow_composite_pass_mod.RtShadowCompositePass.init(&renderer.rhi);
        errdefer renderer.rt_shadow_composite_pass.deinit(&renderer.rhi);

        renderer.rt_shadow_denoise_pass = try rt_shadow_denoise_pass_mod.RtShadowDenoisePass.init(&renderer.rhi);
        errdefer renderer.rt_shadow_denoise_pass.deinit(&renderer.rhi);

        // SSAO 合成通道复用 RT 阴影合成的 multiply-blend 管线
        renderer.ssao_composite_pass = try rt_shadow_composite_pass_mod.RtShadowCompositePass.init(&renderer.rhi);
        errdefer renderer.ssao_composite_pass.deinit(&renderer.rhi);

        renderer.contact_shadow_composite_pass = try rt_shadow_composite_pass_mod.RtShadowCompositePass.init(&renderer.rhi);
        errdefer renderer.contact_shadow_composite_pass.deinit(&renderer.rhi);

        renderer.ssgi_compute_pass = ssgi_compute_pass_mod.SSGIComputePass.init(&renderer.rhi) catch |err| blk: {
            std.log.warn("SSGI compute pass init failed (falling back to fragment): {}", .{err});
            break :blk null;
        };
        errdefer if (renderer.ssgi_compute_pass) |*p| p.deinit(&renderer.rhi);

        renderer.ssgi_composite_pass = try ssgi_composite_pass_mod.SSGICompositePass.init(&renderer.rhi);
        errdefer renderer.ssgi_composite_pass.deinit(&renderer.rhi);

        // RHI Metal backend — real GPU via ObjC++ bridge on macOS,
        // falls back to mock MetalBackend otherwise.
        rhi_init: {
            if (comptime @import("builtin").os.tag == .macos) {
                const md_ptr = allocator.create(metal_device_mod.MetalDevice) catch break :rhi_init;
                const md = metal_device_mod.MetalDevice.init(allocator) orelse {
                    allocator.destroy(md_ptr);
                    break :rhi_init;
                };
                md_ptr.* = md;

                const metal_layer_binding = window.createMetalLayerBinding();
                if (metal_layer_binding) |binding| {
                    renderer.metal_layer_binding = binding;
                    if (binding.layer) |layer| {
                        md_ptr.setLayer(layer);
                    }
                }

                const dev_ptr = allocator.create(rhi_api.Device) catch {
                    md_ptr.deinit();
                    allocator.destroy(md_ptr);
                    break :rhi_init;
                };
                dev_ptr.* = md_ptr.createDevice();
                renderer.rhi_metal_device = md_ptr;
                renderer.rhi_device = dev_ptr;
            } else {
                // Non-macOS: use mock backend
                const backend_ptr = allocator.create(rhi_mock_backend_mod.MetalBackend) catch break :rhi_init;
                backend_ptr.* = rhi_mock_backend_mod.MetalBackend.init(allocator);
                const dev_ptr = allocator.create(rhi_api.Device) catch {
                    backend_ptr.deinit();
                    allocator.destroy(backend_ptr);
                    break :rhi_init;
                };
                dev_ptr.* = backend_ptr.createDevice();
                renderer.rhi_mock_backend = backend_ptr;
                renderer.rhi_device = dev_ptr;
            }
        }

        renderer.outline_pass = try outline_pass_mod.OutlinePass.init(&renderer.rhi);
        errdefer renderer.outline_pass.deinit(&renderer.rhi);

        renderer.gizmo_pass = try gizmo_pass_mod.GizmoPass.init(&renderer.rhi);
        renderer.graph.writeExports("dist/reports/render_graph.dot", "dist/reports/render_graph.json") catch |err| {
            std.log.warn("failed to write render graph exports: {}", .{err});
        };
        return renderer;
    }

    pub fn deinit(self: *Renderer) void {
        self.path_trace_state.deinit(self.allocator);
        self.hw_rt_state.deinit(self.allocator);
        self.releaseInFlightSelectionBatches();
        self.pending_selection_readbacks.deinit(self.allocator);
        self.selection_history.deinit();
        self.prev_mesh_models.deinit();
        self.preview_entity_filter.deinit(self.allocator);
        self.camera_path_preview_lines.deinit(self.allocator);
        self.mesh_edit_wireframe_lines.deinit(self.allocator);
        self.mesh_edit_selected_lines.deinit(self.allocator);
        self.mesh_edit_vertex_lines.deinit(self.allocator);
        self.scene_viewport.deinit(&self.rhi);
        self.releaseMaterialThumbnailRequests();
        self.releaseMaterialThumbnailCache();
        self.releaseModelThumbnailRequests();
        self.releaseModelThumbnailCache();
        self.material_thumbnail_preview.deinit();
        self.material_editor_preview_target.deinit(&self.rhi);
        self.thumbnail_scene_cache.deinit(&self.rhi);
        self.model_thumbnail_scene_cache.deinit(&self.rhi);
        self.preview_scene_cache.deinit(&self.rhi);
        if (self.skybox_pass) |*pass| {
            pass.deinit(&self.rhi);
        }
        if (self.ssao_compute_pass) |*p| p.deinit(&self.rhi);
        if (self.cluster_lights_pass) |*p| p.deinit(&self.rhi);
        self.contact_shadow_pass.deinit(&self.rhi);
        if (self.gpu_brdf_lut) |*t| self.rhi.releaseTexture(t);
        if (self.ibl_compute_pass) |*p| p.deinit(&self.rhi);
        self.taa_pass.deinit(&self.rhi);
        self.ssr_pass.deinit(&self.rhi);
        self.ssr_blur_pass.deinit(&self.rhi);
        self.bloom_pass.deinit(&self.rhi);
        self.tonemap_pass.deinit(&self.rhi);
        self.dof_runtime_pass.deinit(&self.rhi);
        self.fxaa_pass.deinit(&self.rhi);
        self.rt_shadow_composite_pass.deinit(&self.rhi);
        self.rt_shadow_denoise_pass.deinit(&self.rhi);
        self.ssao_composite_pass.deinit(&self.rhi);
        self.contact_shadow_composite_pass.deinit(&self.rhi);
        if (self.ssgi_compute_pass) |*p| p.deinit(&self.rhi);
        self.ssgi_composite_pass.deinit(&self.rhi);
        if (self.rt_shadow_mask_texture) |*t| self.rhi.releaseTexture(t);
        if (self.rt_shadow_pixels) |p| self.allocator.free(p);
        if (self.rhi_device) |dp| {
            dp.deinit();
            self.allocator.destroy(dp);
        }
        if (self.rhi_metal_device) |md| {
            md.deinit();
            self.allocator.destroy(md);
        }
        if (self.metal_layer_binding) |binding| {
            window_mod.destroyMetalLayerBinding(binding);
        }
        if (self.rhi_mock_backend) |bp| {
            bp.deinit();
            self.allocator.destroy(bp);
        }
        self.gizmo_pass.deinit(&self.rhi);
        self.outline_pass.deinit(&self.rhi);
        self.base_pass.deinit(&self.rhi);
        self.plugin_hot_reload.deinit();
        self.typed_loader_registry.deinit();
        self.style_registry.deinit();
        self.plugin_registry.deinit();
        self.shadow_map.deinit(&self.rhi);
        self.shadow_pass.deinit(&self.rhi);
        self.velocity_pass.deinit(&self.rhi);
        self.depth_prepass.deinit(&self.rhi);
        self.id_pass.deinit(&self.rhi);
        self.scene_cache.deinit(&self.rhi);
        self.thumbnail_render_world.deinit();
        self.model_thumbnail_render_world.deinit();
        self.preview_render_world.deinit();
        self.render_world.deinit();
        self.rhi.deinit();
        self.graph.deinit();
    }

    pub fn backendApi(self: *const Renderer) rhi_types.GraphicsAPI {
        return self.rhi.api;
    }

    fn cachePreviousMeshModels(self: *Renderer, prepared_scene: *const mesh_pass_mod.PreparedScene) !void {
        self.prev_mesh_models.clearRetainingCapacity();

        for (prepared_scene.opaque_meshes) |item| {
            try self.prev_mesh_models.put(item.entity_id, item.model);
        }
        for (prepared_scene.transparent_meshes) |item| {
            try self.prev_mesh_models.put(item.entity_id, item.model);
        }
    }

    pub fn runtimeInfo(self: *const Renderer) types.RuntimeInfo {
        return self.rhi.runtimeInfo();
    }

    pub fn vsyncEnabled(self: *const Renderer) bool {
        return self.rhi.vsyncEnabled();
    }

    pub fn setVSyncEnabled(self: *Renderer, enabled: bool) !void {
        try self.rhi.setVSyncEnabled(enabled);
    }

    pub fn device(self: *Renderer) *rhi_mod.RhiDevice {
        return &self.rhi;
    }

    pub fn styleRegistry(self: *Renderer) *style_plugin_mod.StyleRegistry {
        return &self.style_registry;
    }

    pub fn pluginRegistry(self: *Renderer) *plugin_mod.PluginRegistry {
        return &self.plugin_registry;
    }

    /// Unified plugin discovery entry point.
    /// 1. Calls `PluginRegistry.discover(root_path)` to find and register all
    ///    plugin manifests in `root_path`.
    /// 2. For each discovered `render_style` plugin, dispatches to
    ///    `StyleRegistry.loadFromDiscoveredPlugin()`.
    /// 3. Writes error state back to `PluginRecord` on typed-loader failure.
    pub fn discoverPlugins(self: *Renderer, root_path: []const u8) void {
        self.plugin_registry.discover(root_path) catch |err| {
            std.log.warn("Renderer: plugin discovery failed for '{s}': {s}", .{ root_path, @errorName(err) });
            return;
        };

        self.typed_loader_registry.dispatchAllDiscover(&self.plugin_registry);
    }

    // ── Plugin lifecycle orchestration ──────────────────────────────────

    /// Enable a plugin by name.  Dispatches to the appropriate typed
    /// loader (render_style, script_vm, etc.) via TypedLoaderRegistry.
    pub fn enablePlugin(self: *Renderer, name: []const u8) void {
        const record = self.plugin_registry.plugins.get(name) orelse {
            std.log.warn("Renderer: enablePlugin('{s}') — not found", .{name});
            return;
        };
        if (self.typed_loader_registry.get(record.manifest.plugin_type)) |loader| {
            loader.onEnable(record);
        }
        self.plugin_registry.enable(name) catch |err| {
            if (self.plugin_registry.plugins.getPtr(name)) |rec| {
                rec.*.setLastError(self.allocator, @errorName(err));
            }
        };
    }

    /// Disable a plugin.  Dispatches to the appropriate typed loader
    /// for subsystem-specific deactivation (e.g. rollback active style).
    pub fn disablePlugin(self: *Renderer, name: []const u8) void {
        const record = self.plugin_registry.plugins.get(name) orelse {
            std.log.warn("Renderer: disablePlugin('{s}') — not found", .{name});
            return;
        };
        if (self.typed_loader_registry.get(record.manifest.plugin_type)) |loader| {
            loader.onDisable(record);
        }
        self.plugin_registry.disable(name) catch |err| {
            if (self.plugin_registry.plugins.getPtr(name)) |rec| {
                rec.*.setLastError(self.allocator, @errorName(err));
            }
        };
    }

    /// Fully unload a plugin.  Dispatches subsystem teardown via the
    /// typed loader, then removes from PluginRegistry.
    pub fn unloadPlugin(self: *Renderer, name: []const u8) void {
        if (self.plugin_registry.plugins.get(name)) |record| {
            if (self.typed_loader_registry.get(record.manifest.plugin_type)) |loader| {
                loader.onUnload(record);
            }
        }

        self.plugin_registry.unload(name) catch |err| {
            std.log.warn("Renderer: unloadPlugin('{s}') failed: {s}", .{ name, @errorName(err) });
        };
    }

    /// Re-scan a plugin directory.  Removes plugins that disappeared from
    /// disk, discovers new ones, and dispatches to typed loaders.
    pub fn rescanPlugins(self: *Renderer, root_path: []const u8) void {
        // 1. Collect names of plugins currently registered from this root.
        var stale_names: std.ArrayListUnmanaged([]const u8) = .empty;
        defer stale_names.deinit(self.allocator);
        {
            var it = self.plugin_registry.plugins.iterator();
            while (it.next()) |entry| {
                const rec = entry.value_ptr.*;
                if (rec.manifest.path.len == 0) continue;
                if (!std.mem.startsWith(u8, rec.manifest.path, root_path)) continue;
                // Check if the manifest file still exists on disk
                std.fs.cwd().access(rec.manifest.path, .{}) catch {
                    stale_names.append(self.allocator, rec.manifest.name) catch |err| {
                        render_log.err("failed to append stale plugin name: {s}", .{@errorName(err)});
                    };
                    continue;
                };
            }
        }

        // 2. Unload stale plugins.
        for (stale_names.items) |name| {
            self.unloadPlugin(name);
        }

        // 3. Discover new plugins (already-registered ones are skipped).
        self.discoverPlugins(root_path);
    }

    /// Tick the plugin hot-reload manager.  Call once per frame.
    /// Internally throttled to 1 s.  On detected changes the plugin is
    /// unloaded and re-discovered via `rescanPlugins`.
    pub fn tickPluginHotReload(self: *Renderer) void {
        self.plugin_hot_reload.tick();
        const changes = self.plugin_hot_reload.pendingChanges();
        if (changes.len > 0) {
            // Each pending change is a directory name; unload matching plugin
            // and let rescan pick it up.  We iterate watched dirs to find the
            // root that contains this plugin directory.
            var dir_it = self.plugin_hot_reload.watched_dirs.iterator();
            while (dir_it.next()) |dir_entry| {
                self.rescanPlugins(dir_entry.key_ptr.*);
            }
        }
    }
    pub fn handleResize(self: *Renderer, width: u32, height: u32) !void {
        try self.rhi.resize(width, height);
    }

    pub fn requestSelectionReadback(
        self: *Renderer,
        pixel_x: u32,
        pixel_y: u32,
        mode: SelectionUpdateMode,
    ) !void {
        try self.pending_selection_readbacks.append(self.allocator, .{
            .pixel_x = pixel_x,
            .pixel_y = pixel_y,
            .mode = mode,
        });
        self.selection_seeded = true;
    }

    /// 设置 AI 聚焦实体（Ghost Highlight），渲染时显示紫色呼吸灯轮廓
    pub fn setAiFocusEntities(self: *Renderer, ids: []const scene_mod.EntityId) void {
        const count = @min(ids.len, self.ai_focus_entity_ids.len);
        @memcpy(self.ai_focus_entity_ids[0..count], ids[0..count]);
        self.ai_focus_entity_count = count;
    }

    /// 清除 AI 聚焦实体列表
    pub fn clearAiFocusEntities(self: *Renderer) void {
        self.ai_focus_entity_count = 0;
    }

    pub fn selectedEntity(self: *const Renderer) ?scene_mod.EntityId {
        return self.selection_history.primarySelection();
    }

    pub fn selectedEntities(self: *const Renderer) []const scene_mod.EntityId {
        return self.selection_history.currentSelection();
    }

    pub fn pathTraceRenderProgress(self: *const Renderer) PathTraceRenderProgress {
        const pt = &self.path_trace_state;
        if (pt.triangles != null) {
            const tile_span = pathTraceAdaptiveTileSpan(@max(pt.sample_step, 1));
            const total_tiles_x = @max(@as(u32, 1), (pt.trace_width + tile_span - 1) / tile_span);
            const total_tiles_y = @max(@as(u32, 1), (pt.trace_height + tile_span - 1) / tile_span);
            const total_tiles = @max(@as(u32, 1), total_tiles_x * total_tiles_y);
            const current_tile_index = if (pt.complete)
                total_tiles
            else
                @min(
                    total_tiles,
                    (pt.current_tile_y / tile_span) * total_tiles_x + (pt.current_tile_x / tile_span),
                );
            return .{
                .active = true,
                .complete = pt.complete,
                .uses_hw_rt = false,
                .fraction = if (pt.complete) 1.0 else @as(f32, @floatFromInt(current_tile_index)) / @as(f32, @floatFromInt(total_tiles)),
                .trace_width = pt.trace_width,
                .trace_height = pt.trace_height,
            };
        }

        const mrt = &self.hw_rt_state;
        if (mrt.trace_pixels != null or mrt.display_pixels != null) {
            const target_samples = std.math.clamp(self.editor_viewport_state.path_trace_samples, 1, 2048);
            const progress = if (target_samples > 0)
                @as(f32, @floatFromInt(@min(mrt.accum_frame_count, target_samples))) / @as(f32, @floatFromInt(target_samples))
            else
                1.0;
            return .{
                .active = true,
                .complete = mrt.accum_frame_count >= target_samples,
                .uses_hw_rt = true,
                .fraction = progress,
                .trace_width = mrt.trace_width,
                .trace_height = mrt.trace_height,
            };
        }

        return .{};
    }

    pub fn resetSceneState(self: *Renderer) !void {
        self.releaseInFlightSelectionBatches();
        self.in_flight_selection_batches = .empty;
        self.pending_selection_readbacks.deinit(self.allocator);
        self.pending_selection_readbacks = .empty;
        self.selection_history.deinit();
        self.selection_history = SelectionHistory.init(self.allocator, 64);
        self.selection_seeded = false;
        self.releaseMaterialThumbnailRequests();
        self.releaseMaterialThumbnailCache();
        self.thumbnail_scene_cache.invalidateMaterialResources(&self.rhi);
        self.preview_scene_cache.deinit(&self.rhi);
        self.preview_scene_cache = try mesh_pass_mod.MeshSceneCache.init(self.allocator, &self.rhi);
        self.scene_cache.deinit(&self.rhi);
        self.scene_cache = try mesh_pass_mod.MeshSceneCache.init(self.allocator, &self.rhi);
        self.cached_env_textures = .{};
        self.preview_scene = null;
        self.editor_gizmo_transform_override = null;
        self.preview_gizmo_transform = null;
        self.preview_entity_filter.clearRetainingCapacity();
    }

    pub fn replaceSelection(self: *Renderer, entity: ?scene_mod.EntityId) !void {
        _ = try self.selection_history.applyPick(entity, .replace);
        self.selection_seeded = true;
    }

    pub fn replaceSelectionMany(self: *Renderer, entities: []const scene_mod.EntityId) !void {
        _ = try self.selection_history.replaceSelection(entities);
        self.selection_seeded = true;
    }

    pub fn toggleSelection(self: *Renderer, entity: ?scene_mod.EntityId) !void {
        _ = try self.selection_history.applyPick(entity, .toggle);
        self.selection_seeded = true;
    }

    pub fn setEditorGizmoState(self: *Renderer, state: EditorGizmoState) void {
        self.editor_gizmo_state = state;
    }

    pub fn setEditorGizmoTransformOverride(self: *Renderer, transform: ?components.Transform) void {
        self.editor_gizmo_transform_override = transform;
    }

    pub fn invalidateMainWorldMeshResource(self: *Renderer, handle: handles.MeshHandle) void {
        self.scene_cache.invalidateMeshResource(&self.rhi, handle);
        self.resetPathTraceState();
    }

    pub fn setPreviewGizmoTransform(self: *Renderer, transform: ?components.Transform) void {
        self.preview_gizmo_transform = transform;
    }

    pub fn setPreviewEntityFilter(self: *Renderer, entity_ids: []const scene_mod.EntityId) !void {
        self.preview_entity_filter.clearRetainingCapacity();
        try self.preview_entity_filter.appendSlice(self.allocator, entity_ids);
    }

    pub fn clearPreviewEntityFilter(self: *Renderer) void {
        self.preview_entity_filter.clearRetainingCapacity();
    }

    /// Reset progressive path trace state so the next frame in PathTrace mode
    /// starts a fresh render.  Called on explicit Raster→PathTrace mode switch.
    pub fn resetPathTraceState(self: *Renderer) void {
        self.path_trace_state.reset(self.allocator);
        // Zero out last_view_projection so change detection triggers re-cache
        self.path_trace_state.last_view_projection = mat4_mod.identity();
        self.path_trace_state.last_samples = 0;
        self.path_trace_state.last_bounces = 0;
        self.path_trace_state.last_resolution_scale = 0.0;
        self.path_trace_state.last_environment_texture_handle = 0;
        self.path_trace_state.last_scene_signature = 0;
        // 同时重置 HW RT 状态，使 GPU 路径也从头开始
        self.hw_rt_state.reset(self.allocator);
        self.hw_rt_state.needs_retrace = true;
        self.hw_rt_state.last_view_projection = mat4_mod.identity();
        self.hw_rt_state.last_samples = 0;
        self.hw_rt_state.last_bounces = 0;
        self.hw_rt_state.last_resolution_scale = 0.0;
        self.hw_rt_state.last_scene_signature = 0;
    }

    pub fn invalidateEnvironmentState(self: *Renderer) void {
        self.cached_env_textures = .{};
        self.resetPathTraceState();
    }

    pub fn setEditorViewportState(self: *Renderer, state: EditorViewportState) void {
        if (g_logged_postfx_state == null or
            g_logged_postfx_state.?.exposure_enabled != state.exposure_enabled or
            @abs(g_logged_postfx_state.?.exposure - state.exposure) > 0.0001 or
            g_logged_postfx_state.?.bloom_enabled != state.bloom_enabled or
            @abs(g_logged_postfx_state.?.bloom_threshold - state.bloom_threshold) > 0.0001 or
            @abs(g_logged_postfx_state.?.bloom_intensity - state.bloom_intensity) > 0.0001 or
            g_logged_postfx_state.?.color_grading_enabled != state.color_grading_enabled or
            @abs(g_logged_postfx_state.?.color_grading_saturation - state.color_grading_saturation) > 0.0001 or
            @abs(g_logged_postfx_state.?.color_grading_contrast - state.color_grading_contrast) > 0.0001 or
            @abs(g_logged_postfx_state.?.color_grading_gamma - state.color_grading_gamma) > 0.0001 or
            g_logged_postfx_state.?.fxaa_enabled != state.fxaa_enabled or
            g_logged_postfx_state.?.lut_enabled != state.lut_enabled or
            @abs(g_logged_postfx_state.?.lut_intensity - state.lut_intensity) > 0.0001 or
            g_logged_postfx_state.?.lut_preset != state.lut_preset)
        {
            render_log.info(
                "viewport postfx updated exposure_enabled={} exposure={d:.2} bloom_enabled={} bloom_threshold={d:.2} bloom_intensity={d:.2} color_grading_enabled={} saturation={d:.2} contrast={d:.2} gamma={d:.2} fxaa_enabled={} lut_enabled={} lut_intensity={d:.2} lut_preset={s}",
                .{
                    state.exposure_enabled,
                    state.exposure,
                    state.bloom_enabled,
                    state.bloom_threshold,
                    state.bloom_intensity,
                    state.color_grading_enabled,
                    state.color_grading_saturation,
                    state.color_grading_contrast,
                    state.color_grading_gamma,
                    state.fxaa_enabled,
                    state.lut_enabled,
                    state.lut_intensity,
                    @tagName(state.lut_preset),
                },
            );
            g_logged_postfx_state = state;
        }
        self.editor_viewport_state = state;
    }

    pub fn setPreviewScene(self: *Renderer, scene: ?*const scene_mod.Scene) void {
        self.preview_scene = scene;
    }

    /// 设置 Sequencer 相机路径预览线段（成对顶点表示线段）。
    /// 传入 [3]f32 position 数组，长度必须为偶数。
    pub fn setCameraPathPreview(self: *Renderer, positions: []const [3]f32) void {
        self.camera_path_preview_lines.clearRetainingCapacity();
        self.camera_path_preview_lines.ensureTotalCapacity(self.allocator, positions.len) catch return;
        for (positions) |pos| {
            self.camera_path_preview_lines.appendAssumeCapacity(.{ .position = pos });
        }
    }

    /// Set mesh edit overlay lines.  Called from the editor layer when
    /// entering/exiting edit mode or when selection changes.
    /// All slices are pairs of position vertices representing line segments,
    /// except `vtx_dot_positions` and `sel_dot_positions` which are single
    /// positions used as billboard dot centers.
    pub fn setMeshEditOverlay(
        self: *Renderer,
        wireframe: []const [3]f32,
        selected: []const [3]f32,
        vertices: []const [3]f32,
        sel_dot_positions: []const [3]f32,
        vtx_dot_positions: []const [3]f32,
    ) void {
        self.setLineList(&self.mesh_edit_wireframe_lines, wireframe);
        self.setLineList(&self.mesh_edit_selected_lines, selected);
        self.setLineList(&self.mesh_edit_vertex_lines, vertices);
        self.setLineList(&self.mesh_edit_sel_dot_positions, sel_dot_positions);
        self.setLineList(&self.mesh_edit_vtx_dot_positions, vtx_dot_positions);
    }

    /// Clear all mesh edit overlay lines.
    pub fn clearMeshEditOverlay(self: *Renderer) void {
        self.mesh_edit_wireframe_lines.clearRetainingCapacity();
        self.mesh_edit_selected_lines.clearRetainingCapacity();
        self.mesh_edit_vertex_lines.clearRetainingCapacity();
        self.mesh_edit_vtx_dot_positions.clearRetainingCapacity();
        self.mesh_edit_sel_dot_positions.clearRetainingCapacity();
    }

    fn setLineList(self: *Renderer, list: *std.ArrayListUnmanaged(gizmo_pass_mod.WorldLineVertex), positions: []const [3]f32) void {
        list.clearRetainingCapacity();
        list.ensureTotalCapacity(self.allocator, positions.len) catch return;
        for (positions) |pos| {
            list.appendAssumeCapacity(.{ .position = pos });
        }
    }

    pub fn setSceneViewportSize(self: *Renderer, width: u32, height: u32) !void {
        try self.scene_viewport.ensure(&self.rhi, width, height);
    }

    pub fn sceneViewportTexture(self: *Renderer) ?*const rhi_mod.Texture {
        if (self.scene_viewport.color_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn sceneViewportSize(self: *const Renderer) [2]u32 {
        return .{ self.scene_viewport.width, self.scene_viewport.height };
    }

    pub fn passCount(self: *const Renderer) usize {
        return self.graph.passCount();
    }

    pub fn requestMaterialThumbnail(self: *Renderer, scene: *const scene_mod.Scene, asset_id: []const u8, frame_index: usize) !void {
        const source = resolveMaterialThumbnailSource(&scene.resources, asset_id) orelse {
            self.removeMaterialThumbnail(asset_id);
            return;
        };

        const entry = try self.ensureMaterialThumbnailEntry(asset_id);
        entry.last_requested_frame = frame_index;
        if (!std.meta.eql(entry.signature, source.signature)) {
            entry.signature = source.signature;
            entry.dirty = true;
        }
        if (entry.dirty and !entry.queued) {
            try self.enqueueMaterialThumbnailRequest(entry);
        }
    }

    pub fn materialThumbnailTexture(self: *const Renderer, asset_id: []const u8) ?*const rhi_mod.Texture {
        const entry = self.findMaterialThumbnailCacheIndex(asset_id) orelse return null;
        if (!entry.ready) {
            return null;
        }
        return &entry.target.color_texture;
    }

    pub fn requestModelThumbnail(self: *Renderer, model_path: []const u8, frame_index: usize) !void {
        return renderer_thumbnails.requestModelThumbnail(self, model_path, frame_index);
    }

    pub fn modelThumbnailTexture(self: *const Renderer, model_path: []const u8) ?*const rhi_mod.Texture {
        return renderer_thumbnails.modelThumbnailTexture(self, model_path);
    }

    pub fn requestMaterialEditorPreview(
        self: *Renderer,
        resources: *const assets_lib.ResourceLibrary,
        ast: *const material_ast_mod.MaterialAst,
        primitive: components.Primitive,
    ) !void {
        self.material_editor_preview_requested = true;

        const source = makeMaterialThumbnailSourceFromAst(resources, ast);
        const primitive_changed = self.material_editor_preview_primitive != primitive;
        const signature_changed = !std.meta.eql(self.material_editor_preview_signature, source.signature);
        if (!primitive_changed and !signature_changed) {
            return;
        }

        if (primitive_changed) {
            try self.material_thumbnail_preview.setPreviewPrimitive(primitive);
            self.material_editor_preview_primitive = primitive;
        }

        try self.material_thumbnail_preview.syncFromSource(source);
        self.thumbnail_scene_cache.invalidateMaterialResources(&self.rhi);
        self.material_editor_preview_signature = source.signature;
        self.material_editor_preview_dirty = true;
        self.material_editor_preview_ready = false;
    }

    pub fn materialEditorPreviewTexture(self: *const Renderer) ?*const rhi_mod.Texture {
        if (!self.material_editor_preview_ready) {
            return null;
        }
        return &self.material_editor_preview_target.color_texture;
    }

    pub fn texturePreviewTexture(
        self: *Renderer,
        world: *const scene_mod.World,
        handle: handles.TextureHandle,
    ) ?*const rhi_mod.Texture {
        return self.thumbnail_scene_cache.ensureTextureHandle(&self.rhi, world, handle) catch null;
    }

    /// Renders a complete frame: processes scene data, executes render graph passes, and returns statistics.
    ///
    /// Parameters:
    /// - `scene`: Scene snapshot containing visible entities, lights, and cameras.
    /// - `physics_state_opt`: Optional physics state for collision geometry rendering (debug visualization).
    ///
    /// Returns: FrameReport with per-pass statistics (execution time, draw calls, triangles),
    /// scene snapshot, and GPU runtime info (backend, total VRAM).
    ///
    /// Side-effects:
    /// - Submits GPU work to RHI device (non-blocking from CPU perspective).
    /// - Updates material thumbnail cache (processes material_thumbnail_jobs_per_frame thumbnails).
    /// - Processes selection readbacks from previous frame (object picking for editor).
    /// - May trigger async resource compilations (shaders, pipelines) on first use.
    ///
    /// Errors:
    /// - Most errors are logged and result in a degraded frame (e.g., failed to compile shader).
    /// - Returning error means GPU submission failed; caller should skip present or retry next frame.
    ///
    /// Thread-safety: NOT thread-safe. Must be called from render thread (typically main thread).
    /// Scene pointer must remain valid until GPU work completes (typically 1-2 frames later).
    pub fn drawFrame(self: *Renderer, scene: *scene_mod.Scene, physics_state_opt: ?*physics_mod.PhysicsState) !FrameReport {
        // 每帧主流程概览：
        // 1) 处理前一帧的 selection readbacks（用于编辑器对象拾取）
        // 2) 释放上一帧临时 GPU 资源（例如 Gizmo 的 world-line buffers）
        // 3) 分配 per-pass 统计并构建场景快照
        // 4) beginFrame -> 执行各个 render pass 并提交帧
        // 注意：此函数必须在渲染线程（主线程）调用，场景指针需保证在 GPU 完成使用前有效（延迟 1-2 帧）。
        try self.resolveSelectionReadbacks();

        // Release temporary world-line buffers from the previous frame now
        // that the GPU has finished using them.
        self.gizmo_pass.releaseWorldLineBuffers(&self.rhi);

        // 为本帧分配 RenderGraph 的统计结构，用于记录每个 pass 的耗时与绘制统计
        const pass_stats = try self.graph.allocatePassStats(self.allocator);
        defer self.allocator.free(pass_stats);

        // 构建场景快照：捕获可见实体、资源引用与当前相机/灯光状态，供后续场景提取与渲染准备使用。
        const snapshot = buildSceneSnapshot(scene);
        const result = blk: {
            // 开始 GPU 帧：从 RHI 获取命令帧并尝试获取 swapchain 图像（若存在）
            const frame = try self.rhi.beginFrame();
            // 计算清屏参数（颜色/深度），基于当前场景与渲染图的需要
            const clear = clearAndDepthForScene(snapshot, self.passCount());
            const has_swapchain = frame.swapchain_image.id != 0;

            // 如果关键的 pass 尚未准备好（例如 shader/pipeline 还在编译），则提交空白/清屏帧并提前返回。
            // 这样可以避免后续对未就绪资源的引用，并让系统在后台完成缺失资源的准备。
            if (!self.depth_prepass.isReady() or !self.base_pass.isReady()) {
                if (has_swapchain) {
                    try self.rhi.clearAndPresent(frame, clear);
                } else {
                    try self.rhi.submitFrame(frame);
                }
                break :blk FrameReport{
                    .backend = self.rhi.api,
                    .passes_executed = self.passCount(),
                    .graph_resources = self.graph.resourceCount(),
                    .scene = snapshot,
                    .runtime = self.runtimeInfo(),
                };
            }

            const viewport_active = self.scene_viewport.active();
            const can_render_scene = viewport_active or has_swapchain;

            // ── Double-buffered pipeline: wait for PREVIOUS frame's GPU work ──
            // By deferring the wait to the start of the NEXT frame, the GPU
            // had the entire frame-delay sleep + CPU prep time to finish.
            // For a typical 120fps scene the GPU is done long before we arrive
            // here, making waitForPreviousFrame() nearly instant (~0µs).
            //
            // After the wait, the previous frame's color_texture has stable
            // pixels.  We submit an async blit to copy them to the staging
            // IOSurface so the addon can read them at any time.  The blit
            // runs on the same GPU queue and completes before THIS frame's
            // render commands start (Metal FIFO guarantee).
            if (viewport_active and self.scene_viewport.use_iosurface) {
                self.rhi.waitForPreviousFrame();
                if (self.scene_viewport.color_texture) |tex| {
                    const staging_id = self.rhi.blitSharedTexture(tex);
                    if (staging_id != 0) {
                        self.scene_viewport.staging_iosurface_id = staging_id;
                    }
                }
            }

            const render_width = if (viewport_active) self.scene_viewport.width else frame.swapchain_image.width;
            const render_height = if (viewport_active) self.scene_viewport.height else frame.swapchain_image.height;
            var draw_stats = mesh_pass_mod.DrawStats{};

            if (can_render_scene) {
                if (!g_logged_viewport_backend) {
                    render_log.info(
                        "draw frame backend={s} viewport_active={} swapchain={} rhi_device={} skybox_ready={}",
                        .{
                            @tagName(self.rhi.api),
                            viewport_active,
                            has_swapchain,
                            self.rhi_device != null,
                            if (self.skybox_pass) |*pass| pass.isReady() else false,
                        },
                    );
                    g_logged_viewport_backend = true;
                }
                const extraction_frustum = buildSceneExtractionFrustum(&self.scene_cache, scene, render_width, render_height);
                const extraction_stats = try scene_extraction.extractWorld(
                    scene,
                    &self.render_world,
                    self.selection_history.primarySelection(),
                    self.selection_history.currentSelection(),
                    extraction_frustum,
                );
                if (extraction_frustum != null and !g_logged_scene_extraction_culling) {
                    render_log.info(
                        "scene extraction culling active candidates={} meshes={}/{} culled={} vfx={}/{} culled={}",
                        .{
                            extraction_stats.frustum_candidates,
                            extraction_stats.extracted_meshes,
                            extraction_stats.total_meshes,
                            extraction_stats.culledMeshes(),
                            extraction_stats.extracted_vfxs,
                            extraction_stats.total_vfxs,
                            extraction_stats.culledVfxs(),
                        },
                    );
                    g_logged_scene_extraction_culling = true;
                }

                // 场景准备（prepareScene）：执行视锥剔除、构建 DrawItem 列表，并确保所需的 GPU 资源（纹理/mesh）已就绪或已上传。
                var prepared_scene = try self.scene_cache.prepareScene(
                    &self.rhi,
                    scene,
                    &self.render_world,
                    render_width,
                    render_height,
                );
                defer prepared_scene.deinit();

                // 确保选择系统有一个初始选中项（用于编辑器交互）
                if (self.is_editor_mode and !self.selection_seeded) {
                    _ = try self.selection_history.applyPick(
                        self.scene_cache.defaultSelectionEntity(scene),
                        .replace,
                    );
                    self.selection_seeded = true;
                }

                // ID pass：渲染物体 ID 到独立纹理，用于编辑器的物体拾取（selection）。先确保目标纹理尺寸正确。
                try self.id_pass.ensureTargetSize(&self.rhi, render_width, render_height);

                // 计算级联阴影贴图 (CSM) 的 light-space 矩阵：为每个 cascade 生成光照空间投影矩阵并写入 shadow_map
                const light_space_matrix = blk_lsm: {
                    const main_light = if (prepared_scene.lights.directional_lights.len > 0)
                        prepared_scene.lights.directional_lights[0]
                    else
                        mesh_pass_mod.DirectionalLightBlock{ .direction = vec3.normalize(.{ 0.3, -0.9, -0.2 }), .color = .{ 1.0, 0.98, 0.92 }, .intensity = 1.6 };

                    const light_dir = vec3.normalize(main_light.direction);

                    // Camera near/far from projection
                    const cam_proj = prepared_scene.camera.camera.projection;
                    const cam_near = switch (cam_proj) {
                        .perspective => |p| p.near_clip,
                        .orthographic => |o| o.near_clip,
                    };
                    const cam_far = switch (cam_proj) {
                        .perspective => |p| p.far_clip,
                        .orthographic => |o| o.far_clip,
                    };

                    // Inverse VP for extracting frustum corners
                    const inv_vp = mat4_mod.inverse(prepared_scene.view_projection) orelse mat4_mod.identity();
                    const texel_size = @as(f32, @floatFromInt(self.shadow_map.size));

                    // Compute cascade splits (practical-split-scheme, lambda=0.7)
                    const splits = renderer_shadow_cascade.computeCascadeSplits(cam_near, cam_far, renderer_resources.csm_cascade_count, 0.82);
                    self.shadow_map.cascade_splits = splits;

                    // Compute per-cascade matrices
                    var first_mat: [16]f32 = mat4_mod.identity();
                    for (0..csm_cascade_count) |ci| {
                        const split_near = if (ci == 0) cam_near else splits[ci - 1];
                        const split_far = splits[ci];
                        const cascade_mat = renderer_shadow_cascade.computeCascadeMatrix(inv_vp, split_near, split_far, cam_near, cam_far, light_dir, texel_size);
                        self.shadow_map.cascade_matrices[ci] = cascade_mat;
                        if (ci == 0) first_mat = cascade_mat;
                    }

                    // Legacy: keep first cascade as the main light_space_matrix for backward compat
                    break :blk_lsm first_mat;
                };
                prepared_scene.light_space_matrix = light_space_matrix;
                prepared_scene.cascade_matrices = self.shadow_map.cascade_matrices;
                prepared_scene.cascade_splits = self.shadow_map.cascade_splits;
                for (0..csm_cascade_count) |ci| {
                    prepared_scene.shadow_maps[ci] = &self.shadow_map.depth_textures[ci].?;
                }
                prepared_scene.shadow_sampler = &self.shadow_map.sampler.?;

                // Generate GPU BRDF LUT once via compute shader (high quality, environment-independent)
                if (!self.gpu_brdf_lut_generated) {
                    self.gpu_brdf_lut_generated = true;
                    if (self.ibl_compute_pass) |*ibl_pass| {
                        if (ibl_pass.hasBRDF()) {
                            const brdf_size: u32 = 256;
                            self.gpu_brdf_lut = self.rhi.createTexture(.{
                                .width = brdf_size,
                                .height = brdf_size,
                                .format = .rgba16_float,
                                .usage = rhi_types.TextureUsage.sampler | rhi_types.TextureUsage.compute_storage_write,
                            }) catch null;
                            if (self.gpu_brdf_lut) |*lut| {
                                ibl_pass.generateBRDFLUT(&self.rhi, frame, lut, brdf_size, 1024) catch |err| {
                                    render_log.warn("GPU BRDF LUT generation failed: {s}", .{@errorName(err)});
                                    self.rhi.releaseTexture(lut);
                                    self.gpu_brdf_lut = null;
                                };
                                if (self.gpu_brdf_lut != null) {
                                    render_log.info("GPU BRDF LUT generated ({}x{}, 1024 samples)", .{ brdf_size, brdf_size });
                                }
                            }
                        }
                    }
                }

                // Sync Sky component FIRST so scene_environment_asset_id is up-to-date
                // before resolveEnvironmentTextures reads it.
                syncSkyComponent(scene, &prepared_scene);
                resolveEnvironmentTextures(self, scene, &prepared_scene) catch |err| {
                    render_log.warn("resolveEnvironmentTextures failed: {s}; using fallback", .{@errorName(err)});
                };

                var prepared_preview_scene: mesh_pass_mod.PreparedScene = undefined;
                var has_prepared_preview_scene = false;
                defer if (has_prepared_preview_scene) {
                    prepared_preview_scene.deinit();
                };
                const preview_active = self.preview_gizmo_transform != null or self.editor_gizmo_transform_override != null;
                if (viewport_active and preview_active and self.preview_scene != null and self.preview_entity_filter.items.len > 0) {
                    const preview_frustum = frustum_mod.Frustum.fromViewProjection(prepared_scene.view_projection);
                    _ = try scene_extraction.extractWorld(
                        @constCast(self.preview_scene.?),
                        &self.preview_render_world,
                        null,
                        &.{},
                        preview_frustum,
                    );
                    prepared_preview_scene = try self.preview_scene_cache.preparePreviewScene(
                        &self.rhi,
                        self.preview_scene.?,
                        &self.preview_render_world,
                        &prepared_scene,
                        self.preview_entity_filter.items,
                    );
                    has_prepared_preview_scene = true;
                }

                const path_trace_viewport = viewport_active and self.editor_viewport_state.pipeline_mode == .path_trace;

                const do_path_trace = path_trace_viewport;

                // scene_color_target 在所有模式下都需要（用于 overlay passes: gizmo, outline, debug）
                const scene_color_target: rhi_mod.ColorTarget = if (viewport_active)
                    .{ .texture = self.scene_viewport.color().? }
                else
                    .swapchain;

                const scene_depth_target: ?rhi_mod.DepthAttachmentDesc = blk_depth: {
                    const depth_texture = if (viewport_active)
                        self.scene_viewport.depth().?
                    else
                        self.rhi.depthTexture() orelse break :blk_depth null;
                    break :blk_depth .{
                        .texture = depth_texture,
                        .clear_depth = 1.0,
                        .clear_stencil = 0,
                        .load_op = .clear,
                        .store_op = if (viewport_active) .store else .dont_care,
                        .stencil_load_op = .dont_care,
                        .stencil_store_op = .dont_care,
                    };
                };

                if (self.id_pass.isReady()) {
                    const id_texture = self.id_pass.texture().?;
                    const id_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.idPass(id_texture, scene_depth_target));
                    const start = std.time.nanoTimestamp();
                    const id_stats = self.id_pass.draw(&self.rhi, frame, id_render_pass, &prepared_scene);
                    self.graph.recordPassStat(pass_stats, .id_pass, durationNs(start, std.time.nanoTimestamp()), id_stats.draw_calls, id_stats.triangles_drawn);
                    draw_stats.add(id_stats);
                    self.rhi.endRenderPass(id_render_pass);
                }

                var current_unjittered_view_projection = prepared_scene.view_projection;
                var current_taa_jitter_uv = [2]f32{ 0.0, 0.0 };

                if (do_path_trace) {
                    const path_trace_start = std.time.nanoTimestamp();
                    try self.renderPathTraceViewport(&prepared_scene, scene);
                    const path_trace_end = std.time.nanoTimestamp();
                    self.graph.recordPassStat(pass_stats, .base_pass, durationNs(path_trace_start, path_trace_end), 0, 0);

                    const bloom_enabled = self.editor_viewport_state.bloom_enabled and self.scene_viewport.bloom() != null;
                    const fxaa_enabled = self.editor_viewport_state.fxaa_enabled and self.scene_viewport.fxaa() != null;

                    if (bloom_enabled) {
                        try self.bloom_pass.syncTexture(&self.rhi, self.scene_viewport.hdrColor().?);
                        const bloom_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.bloom().? }));
                        const bloom_start = std.time.nanoTimestamp();
                        const bloom_stats = self.bloom_pass.draw(&self.rhi, frame, bloom_render_pass, .{
                            .threshold_params = .{
                                self.editor_viewport_state.bloom_threshold,
                                0.5,
                                0.0,
                                0.0,
                            },
                        });
                        draw_stats.add(bloom_stats);
                        self.graph.recordPassStat(pass_stats, .post_process, durationNs(bloom_start, std.time.nanoTimestamp()), bloom_stats.draw_calls, bloom_stats.triangles_drawn);
                        self.rhi.endRenderPass(bloom_render_pass);
                    }

                    try self.tonemap_pass.syncTextures(
                        &self.rhi,
                        self.scene_viewport.hdrColor().?,
                        if (bloom_enabled) self.scene_viewport.bloom().? else null,
                        null,
                    );
                    const tm_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.color().? }));
                    const tm_start = std.time.nanoTimestamp();
                    const tonemap_stats = self.tonemap_pass.draw(&self.rhi, frame, tm_render_pass, .{
                        .exposure_params = .{
                            @as(f32, if (self.editor_viewport_state.exposure_enabled) 1.0 else 0.0),
                            self.editor_viewport_state.exposure,
                            0.0,
                            0.0,
                        },
                        .bloom_params = .{
                            @as(f32, if (bloom_enabled) 1.0 else 0.0),
                            self.editor_viewport_state.bloom_intensity,
                            0.0,
                            0.0,
                        },
                        .color_grading_params = .{
                            @as(f32, if (self.editor_viewport_state.color_grading_enabled) 1.0 else 0.0),
                            self.editor_viewport_state.color_grading_saturation,
                            self.editor_viewport_state.color_grading_contrast,
                            self.editor_viewport_state.color_grading_gamma,
                        },
                        .lut_params = .{
                            0.0,
                            self.editor_viewport_state.lut_intensity,
                            0.0,
                            0.0,
                        },
                    });
                    draw_stats.add(tonemap_stats);
                    self.graph.recordPassStat(pass_stats, .tonemap_pass, durationNs(tm_start, std.time.nanoTimestamp()), tonemap_stats.draw_calls, tonemap_stats.triangles_drawn);
                    self.rhi.endRenderPass(tm_render_pass);

                    if (fxaa_enabled) {
                        const fxaa_start = std.time.nanoTimestamp();
                        try self.fxaa_pass.syncTexture(&self.rhi, self.scene_viewport.color().?);
                        const fxaa_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.fxaa().? }));
                        const fxaa_stats = self.fxaa_pass.draw(&self.rhi, frame, fxaa_render_pass);
                        draw_stats.add(fxaa_stats);
                        self.graph.recordPassStat(pass_stats, .post_process, durationNs(fxaa_start, std.time.nanoTimestamp()), fxaa_stats.draw_calls, fxaa_stats.triangles_drawn);
                        self.rhi.endRenderPass(fxaa_render_pass);
                    }
                } else {
                    const scene_hdr_color_target: rhi_mod.ColorTarget = if (viewport_active)
                        .{ .texture = self.scene_viewport.hdrColor().? }
                    else
                        scene_color_target;

                    // RT Shadows: 当 rt_shadows_enabled 且硬件 RT 可用时，
                    // 用 RT 阴影遮罩替换 shadow map，跳过常规阴影渲染。
                    const rt_shadows_active = viewport_active and
                        self.editor_viewport_state.rt_shadows_enabled and
                        self.tryRenderRtShadows(&prepared_scene, scene, self.scene_viewport.width, self.scene_viewport.height);

                    if (rt_shadows_active) {
                        prepared_scene.rt_shadow_mask = if (self.rt_shadow_mask_texture) |*mask| mask else null;
                        prepared_scene.rt_shadow_strength = self.editor_viewport_state.rt_shadow_strength;
                        prepared_scene.rt_shadow_ambient_floor = 0.12;
                    } else {
                        prepared_scene.rt_shadow_mask = null;
                        prepared_scene.rt_shadow_strength = 1.0;
                        prepared_scene.rt_shadow_ambient_floor = 0.12;
                    }

                    if (self.shadow_pass.isReady()) {
                        if (rt_shadows_active) {
                            // RT shadows 激活：首次清除 depth=1.0（mesh shader 得到 shadow=1.0），
                            // 后续帧完全跳过 shadow pass
                            if (!self.shadow_map.cleared_for_rt) {
                                for (0..csm_cascade_count) |ci| {
                                    const rp = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.shadowOnly(&self.shadow_map.depth_textures[ci].?));
                                    self.rhi.endRenderPass(rp);
                                }
                                self.shadow_map.cleared_for_rt = true;
                            }
                        } else {
                            self.shadow_map.cleared_for_rt = false;
                            const shadow_start = std.time.nanoTimestamp();
                            var cascade_stats = mesh_pass_mod.DrawStats{};
                            for (0..csm_cascade_count) |ci| {
                                const shadow_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.shadowOnly(&self.shadow_map.depth_textures[ci].?));
                                const cs = self.shadow_pass.draw(&self.rhi, frame, shadow_render_pass, &prepared_scene, self.shadow_map.cascade_matrices[ci]);
                                cascade_stats.add(cs);
                                self.rhi.endRenderPass(shadow_render_pass);
                            }
                            self.graph.recordPassStat(pass_stats, .shadow_map, durationNs(shadow_start, std.time.nanoTimestamp()), cascade_stats.draw_calls, cascade_stats.triangles_drawn);
                            draw_stats.add(cascade_stats);
                        }
                    }

                    const base_pass_target = if (viewport_active) scene_hdr_color_target else scene_color_target;
                    const run_rt_shadow_denoise = rt_shadows_active and
                        viewport_active and
                        self.rt_shadow_mask_texture != null and
                        self.rt_shadow_denoise_pass.isReady() and
                        self.scene_viewport.rtShadowDenoised() != null and
                        self.scene_viewport.depth() != null;

                    // TAA jitter: apply subpixel offset to projection matrix before rendering
                    const taa_enabled = viewport_active and self.editor_viewport_state.taa_enabled and self.taa_pass.isReady() and self.scene_viewport.taa() != null;
                    const unjittered_projection = prepared_scene.projection_matrix;
                    current_unjittered_view_projection = prepared_scene.view_projection;
                    if (taa_enabled) {
                        const jitter = self.taa_pass.getJitter();
                        const jx = jitter[0] / @as(f32, @floatFromInt(self.scene_viewport.width));
                        const jy = jitter[1] / @as(f32, @floatFromInt(self.scene_viewport.height));
                        current_taa_jitter_uv = .{ jx, jy };
                        // Offset the projection matrix translation column (indices 12,13 in row-major = [3][0],[3][1] in col-major)
                        prepared_scene.projection_matrix[8] += jx * 2.0;
                        prepared_scene.projection_matrix[9] += jy * 2.0;
                        prepared_scene.view_projection = mat4_mod.mul(prepared_scene.projection_matrix, prepared_scene.view_matrix);
                    }

                    const active_render_mode = effectiveViewportRenderMode(self.editor_viewport_state);
                    const scene_clear_color = if (active_render_mode == .wireframe)
                        [4]f32{ 0.055, 0.055, 0.060, 1.0 }
                    else
                        clear.color;
                    const velocity_enabled = taa_enabled and
                        scene_depth_target != null and
                        self.scene_viewport.velocity() != null and
                        active_render_mode != .wireframe and
                        self.velocity_pass.isReady();
                    // ── Clustered Forward+: light culling compute pass ──────────
                    // MUST run BEFORE the scene render pass begins because
                    // Metal compute dispatch ends the current render encoder.
                    // Placing it between beginRenderPass and draw commands
                    // silently kills renderEnc → all subsequent draws are
                    // dropped on Metal.
                    if (self.cluster_lights_pass) |*cluster_pass| {
                        if (cluster_pass.isReady()) {
                            const mat4_cluster = @import("../math/mat4.zig");
                            const inv_proj = mat4_cluster.inverse(prepared_scene.projection_matrix) orelse mat4_cluster.identity();

                            const camera_near = switch (prepared_scene.camera.camera.projection) {
                                .perspective => |p| p.near_clip,
                                .orthographic => |o| o.near_clip,
                            };
                            const camera_far = switch (prepared_scene.camera.camera.projection) {
                                .perspective => |p| p.far_clip,
                                .orthographic => |o| o.far_clip,
                            };
                            const vp_w: f32 = @floatFromInt(self.scene_viewport.width);
                            const vp_h: f32 = @floatFromInt(self.scene_viewport.height);

                            var cluster_uniforms = cluster_lights_pass_mod.ClusterLightsUniforms{
                                .inv_projection = inv_proj,
                                .view = prepared_scene.view_matrix,
                                .near = camera_near,
                                .far = camera_far,
                                .viewport_w = vp_w,
                                .viewport_h = vp_h,
                                .point_count = @intCast(@min(prepared_scene.lights.point_lights.len, cluster_lights_pass_mod.max_point_lights)),
                            };
                            const pt_count = cluster_uniforms.point_count;
                            for (0..pt_count) |i| {
                                const pl = prepared_scene.lights.point_lights[i];
                                cluster_uniforms.lights[i] = .{
                                    .position_range = .{ pl.position[0], pl.position[1], pl.position[2], pl.range },
                                    .color_intensity = .{ pl.color[0], pl.color[1], pl.color[2], pl.intensity },
                                };
                            }

                            cluster_pass.dispatch(&self.rhi, frame, cluster_uniforms);

                            prepared_scene.cluster_count_texture = if (cluster_pass.cluster_count_texture) |*t| t else null;
                            prepared_scene.cluster_indices_texture = if (cluster_pass.cluster_indices_texture) |*t| t else null;
                            prepared_scene.cluster_nearest_sampler = if (cluster_pass.nearest_sampler) |*s| s else null;
                            prepared_scene.cluster_params = .{ camera_near, camera_far, vp_w, vp_h };
                        }
                    }

                    var scene_pass: rhi_mod.RenderPass = undefined;
                    if (run_rt_shadow_denoise) {
                        const depth_prepass_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.depthOnly(scene_depth_target.?));
                        const depth_start = std.time.nanoTimestamp();
                        const depth_stats = self.depth_prepass.draw(&self.rhi, frame, depth_prepass_pass, &prepared_scene);
                        self.graph.recordPassStat(pass_stats, .depth_prepass, durationNs(depth_start, std.time.nanoTimestamp()), depth_stats.draw_calls, depth_stats.triangles_drawn);
                        draw_stats.add(depth_stats);
                        self.rhi.endRenderPass(depth_prepass_pass);

                        if (velocity_enabled) {
                            const velocity_render_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
                                .color = .{
                                    .target = .{ .texture = self.scene_viewport.velocity().? },
                                    .clear_color = .{ 0.0, 0.0, 0.0, 1.0 },
                                    .load_op = .clear,
                                    .store_op = .store,
                                },
                                .depth = .{
                                    .texture = scene_depth_target.?.texture,
                                    .clear_depth = scene_depth_target.?.clear_depth,
                                    .clear_stencil = scene_depth_target.?.clear_stencil,
                                    .load_op = .load,
                                    .store_op = .store,
                                    .stencil_load_op = scene_depth_target.?.stencil_load_op,
                                    .stencil_store_op = scene_depth_target.?.stencil_store_op,
                                },
                            });
                            const velocity_start = std.time.nanoTimestamp();
                            const velocity_stats = self.velocity_pass.draw(
                                &self.rhi,
                                frame,
                                velocity_render_pass,
                                &prepared_scene,
                                current_unjittered_view_projection,
                                self.prev_view_projection,
                                &self.prev_mesh_models,
                            );
                            self.graph.recordPassStat(pass_stats, .post_process, durationNs(velocity_start, std.time.nanoTimestamp()), velocity_stats.draw_calls, velocity_stats.triangles_drawn);
                            draw_stats.add(velocity_stats);
                            self.rhi.endRenderPass(velocity_render_pass);
                        }

                        try self.rt_shadow_denoise_pass.syncTextures(&self.rhi, &self.rt_shadow_mask_texture.?, self.scene_viewport.depth().?);
                        const denoise_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.rtShadowDenoised().? }));
                        const denoise_start = std.time.nanoTimestamp();
                        const denoise_stats = self.rt_shadow_denoise_pass.draw(&self.rhi, frame, denoise_render_pass, .{
                            .resolution = .{ @floatFromInt(self.scene_viewport.width), @floatFromInt(self.scene_viewport.height) },
                            .inv_resolution = .{
                                1.0 / @as(f32, @floatFromInt(self.scene_viewport.width)),
                                1.0 / @as(f32, @floatFromInt(self.scene_viewport.height)),
                            },
                            .filter_params = .{ 2.0, 140.0, 2.0, 0.0 },
                        });
                        self.graph.recordPassStat(pass_stats, .post_process, durationNs(denoise_start, std.time.nanoTimestamp()), denoise_stats.draw_calls, denoise_stats.triangles_drawn);
                        draw_stats.add(denoise_stats);
                        self.rhi.endRenderPass(denoise_render_pass);

                        prepared_scene.rt_shadow_mask = self.scene_viewport.rtShadowDenoised().?;

                        const loaded_depth_target: rhi_mod.DepthAttachmentDesc = .{
                            .texture = scene_depth_target.?.texture,
                            .clear_depth = scene_depth_target.?.clear_depth,
                            .clear_stencil = scene_depth_target.?.clear_stencil,
                            .load_op = .load,
                            .store_op = .store,
                            .stencil_load_op = scene_depth_target.?.stencil_load_op,
                            .stencil_store_op = scene_depth_target.?.stencil_store_op,
                        };
                        scene_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
                            .color = .{
                                .target = base_pass_target,
                                .clear_color = scene_clear_color,
                                .load_op = if (active_render_mode == .wireframe) .clear else .load,
                                .store_op = .store,
                            },
                            .depth = loaded_depth_target,
                        });
                    } else {
                        if (scene_depth_target != null) {
                            const depth_prepass_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.depthOnly(scene_depth_target.?));
                            const depth_start = std.time.nanoTimestamp();
                            const depth_stats = self.depth_prepass.draw(&self.rhi, frame, depth_prepass_pass, &prepared_scene);
                            self.graph.recordPassStat(pass_stats, .depth_prepass, durationNs(depth_start, std.time.nanoTimestamp()), depth_stats.draw_calls, depth_stats.triangles_drawn);
                            draw_stats.add(depth_stats);
                            self.rhi.endRenderPass(depth_prepass_pass);

                            if (velocity_enabled) {
                                const velocity_render_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
                                    .color = .{
                                        .target = .{ .texture = self.scene_viewport.velocity().? },
                                        .clear_color = .{ 0.0, 0.0, 0.0, 1.0 },
                                        .load_op = .clear,
                                        .store_op = .store,
                                    },
                                    .depth = .{
                                        .texture = scene_depth_target.?.texture,
                                        .clear_depth = scene_depth_target.?.clear_depth,
                                        .clear_stencil = scene_depth_target.?.clear_stencil,
                                        .load_op = .load,
                                        .store_op = .store,
                                        .stencil_load_op = scene_depth_target.?.stencil_load_op,
                                        .stencil_store_op = scene_depth_target.?.stencil_store_op,
                                    },
                                });
                                const velocity_start = std.time.nanoTimestamp();
                                const velocity_stats = self.velocity_pass.draw(
                                    &self.rhi,
                                    frame,
                                    velocity_render_pass,
                                    &prepared_scene,
                                    current_unjittered_view_projection,
                                    self.prev_view_projection,
                                    &self.prev_mesh_models,
                                );
                                self.graph.recordPassStat(pass_stats, .post_process, durationNs(velocity_start, std.time.nanoTimestamp()), velocity_stats.draw_calls, velocity_stats.triangles_drawn);
                                draw_stats.add(velocity_stats);
                                self.rhi.endRenderPass(velocity_render_pass);
                            }

                            const loaded_depth_target: rhi_mod.DepthAttachmentDesc = .{
                                .texture = scene_depth_target.?.texture,
                                .clear_depth = scene_depth_target.?.clear_depth,
                                .clear_stencil = scene_depth_target.?.clear_stencil,
                                .load_op = .load,
                                .store_op = .store,
                                .stencil_load_op = scene_depth_target.?.stencil_load_op,
                                .stencil_store_op = scene_depth_target.?.stencil_store_op,
                            };
                            scene_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
                                .color = .{
                                    .target = base_pass_target,
                                    .clear_color = scene_clear_color,
                                    .load_op = .clear,
                                    .store_op = .store,
                                },
                                .depth = loaded_depth_target,
                            });
                        } else {
                            scene_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.colorWithDepth(base_pass_target, scene_clear_color, scene_depth_target));
                        }
                    }

                    // 渲染主几何（Opaque）：调用 BasePass.draw 来绘制不透明物体（会遍历 DrawItem 列表并发出 draw 调用）
                    const opaque_start = std.time.nanoTimestamp();
                    const opaque_stats = try self.base_pass.draw(&self.rhi, frame, scene_pass, &prepared_scene, .{
                        .render_mode = active_render_mode,
                        .target = if (viewport_active) .hdr else .ldr,
                        .phase = .opaque_pass,
                    });
                    self.graph.recordPassStat(pass_stats, .base_pass, durationNs(opaque_start, std.time.nanoTimestamp()), opaque_stats.draw_calls, opaque_stats.triangles_drawn);
                    draw_stats.add(opaque_stats);

                    if (self.skybox_pass) |*skybox_pass| {
                        if (active_render_mode != .wireframe and skybox_pass.isReady() and prepared_scene.environment_map != null and prepared_scene.sky_enabled) {
                            if (self.skybox_log_count < 5) {
                                self.skybox_log_count += 1;
                                const env_tex = prepared_scene.environment_map.?;
                                render_log.info("skybox draw #{d}: env_map {d}x{d} intensity={d:.3} gpu_id={d} viewport_active={} target={s}", .{
                                    self.skybox_log_count,                 env_tex.desc.width, env_tex.desc.height, prepared_scene.sky_intensity, env_tex.id, viewport_active,
                                    if (viewport_active) "hdr" else "ldr",
                                });
                            }
                            const skybox_start = std.time.nanoTimestamp();
                            skybox_pass.draw(&self.rhi, frame, scene_pass, &prepared_scene, prepared_scene.environment_map.?, if (viewport_active) .hdr else .ldr, prepared_scene.sky_intensity);
                            self.graph.recordPassStat(pass_stats, .skybox_pass, durationNs(skybox_start, std.time.nanoTimestamp()), 1, 1);
                            draw_stats.draw_calls += 1;
                            draw_stats.triangles_drawn += 1;
                        }
                    }

                    if (has_prepared_preview_scene) {
                        prepared_preview_scene.rt_shadow_mask = prepared_scene.rt_shadow_mask;
                        prepared_preview_scene.rt_shadow_strength = prepared_scene.rt_shadow_strength;
                        prepared_preview_scene.rt_shadow_ambient_floor = prepared_scene.rt_shadow_ambient_floor;
                        const preview_opaque_start = std.time.nanoTimestamp();
                        const preview_opaque_stats = try self.base_pass.draw(&self.rhi, frame, scene_pass, &prepared_preview_scene, .{
                            .render_mode = previewRenderMode(active_render_mode),
                            .target = if (viewport_active) .hdr else .ldr,
                            .phase = .opaque_pass,
                            .blend_opaque = true,
                            .alpha_multiplier = ghost_preview_tint_color[3],
                            .preview_tint_strength = ghost_preview_tint_strength,
                        });
                        self.graph.recordPassStat(pass_stats, .base_pass, durationNs(preview_opaque_start, std.time.nanoTimestamp()), preview_opaque_stats.draw_calls, preview_opaque_stats.triangles_drawn);
                        draw_stats.add(preview_opaque_stats);
                    }

                    // 渲染透明物体：切换到透明通道（可能使用不同的 pipeline / 混合设置）
                    const transparent_start = std.time.nanoTimestamp();
                    const transparent_stats = try self.base_pass.draw(&self.rhi, frame, scene_pass, &prepared_scene, .{
                        .render_mode = active_render_mode,
                        .target = if (viewport_active) .hdr else .ldr,
                        .phase = .transparent_pass,
                    });
                    self.graph.recordPassStat(pass_stats, .transparent, durationNs(transparent_start, std.time.nanoTimestamp()), transparent_stats.draw_calls, transparent_stats.triangles_drawn);
                    draw_stats.add(transparent_stats);

                    if (has_prepared_preview_scene) {
                        const preview_transparent_start = std.time.nanoTimestamp();
                        const preview_transparent_stats = try self.base_pass.draw(&self.rhi, frame, scene_pass, &prepared_preview_scene, .{
                            .render_mode = previewRenderMode(active_render_mode),
                            .target = if (viewport_active) .hdr else .ldr,
                            .phase = .transparent_pass,
                            .alpha_multiplier = ghost_preview_tint_color[3],
                            .preview_tint_strength = ghost_preview_tint_strength,
                        });
                        self.graph.recordPassStat(pass_stats, .transparent, durationNs(preview_transparent_start, std.time.nanoTimestamp()), preview_transparent_stats.draw_calls, preview_transparent_stats.triangles_drawn);
                        draw_stats.add(preview_transparent_stats);
                    }

                    // 结束主 scene render pass
                    self.rhi.endRenderPass(scene_pass);

                    // 如果正在渲染到 viewport（编辑器视口），执行后处理与 overlay 流程
                    if (viewport_active) {

                        // Volumetric fog: composite onto HDR color before bloom/tonemap
                        const fog_enabled = self.editor_viewport_state.volumetric_fog_enabled and self.scene_viewport.hdrColor() != null;
                        if (fog_enabled) {
                            if (self.rhi_device) |dev| {
                                const inv_vp_fog = mat4_mod.inverse(prepared_scene.view_projection) orelse mat4_mod.identity();
                                var fog_light_dir = [4]f32{ 0.0, -1.0, 0.0, 0.0 };
                                var fog_light_col = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
                                if (prepared_scene.lights.directional_lights.len > 0) {
                                    const ml = prepared_scene.lights.directional_lights[0];
                                    fog_light_dir = .{ ml.direction[0], ml.direction[1], ml.direction[2], 0.0 };
                                    fog_light_col = .{ ml.color[0], ml.color[1], ml.color[2], ml.intensity };
                                }
                                const fog_start = std.time.nanoTimestamp();
                                volumetric_fog_pass_mod.VolumetricFogPass.execute(
                                    self.allocator,
                                    dev,
                                    null,
                                    0,
                                    0,
                                    .{
                                        .inv_view_projection = inv_vp_fog,
                                        .light_space_matrix = prepared_scene.light_space_matrix,
                                        .camera_position = prepared_scene.camera_world_position,
                                        .light_direction = fog_light_dir,
                                        .light_color = fog_light_col,
                                        .fog_params = .{
                                            self.editor_viewport_state.volumetric_fog_density,
                                            self.editor_viewport_state.volumetric_fog_height_falloff,
                                            self.editor_viewport_state.volumetric_fog_max_distance,
                                            32.0,
                                        },
                                    },
                                ) catch |err| {
                                    render_log.err("volumetric fog pass execution failed: {s}", .{@errorName(err)});
                                };
                                self.graph.recordPassStat(pass_stats, .post_process, durationNs(fog_start, std.time.nanoTimestamp()), 1, 1);
                            }
                        }

                        const bloom_enabled = self.editor_viewport_state.bloom_enabled and self.scene_viewport.bloom() != null;
                        const fxaa_enabled = self.editor_viewport_state.fxaa_enabled and self.scene_viewport.fxaa() != null;

                        // SSAO: render ambient occlusion to ssao_texture
                        const ssao_enabled = self.editor_viewport_state.ssao_enabled and self.scene_viewport.ssao() != null and self.scene_viewport.depth() != null;
                        if (ssao_enabled) {
                            const mat4_ssao = @import("../math/mat4.zig");
                            const inv_proj = mat4_ssao.inverse(prepared_scene.projection_matrix) orelse mat4_ssao.identity();
                            const inv_view = mat4_ssao.inverse(prepared_scene.view_matrix) orelse mat4_ssao.identity();

                            const ssao_uniforms = ssao_compute_pass_mod.SSAOUniforms{
                                .projection = prepared_scene.projection_matrix,
                                .inv_projection = inv_proj,
                                .view = prepared_scene.view_matrix,
                                .inv_view = inv_view,
                                .resolution = .{ @floatFromInt(self.scene_viewport.width), @floatFromInt(self.scene_viewport.height) },
                                .radius = self.editor_viewport_state.ssao_radius,
                                .bias = self.editor_viewport_state.ssao_bias,
                                .intensity = self.editor_viewport_state.ssao_intensity,
                                .power = self.editor_viewport_state.ssao_power,
                                .kernel_size = 16,
                                .noise_scale = .{
                                    @as(f32, @floatFromInt(self.scene_viewport.width)) / 4.0,
                                    @as(f32, @floatFromInt(self.scene_viewport.height)) / 4.0,
                                },
                            };

                            if (self.ssao_compute_pass) |*compute_pass| {
                                if (compute_pass.isReady()) {
                                    compute_pass.dispatch(
                                        &self.rhi,
                                        frame,
                                        self.scene_viewport.depth().?,
                                        self.scene_viewport.ssao().?,
                                        ssao_uniforms,
                                    );
                                }
                            }

                            // SSAO 合成: 将 SSAO 纹理以乘法混合叠加到颜色缓冲，
                            // 使遮蔽区域（角落/缝隙）自然变暗，增强场景接地感。
                            if (self.ssao_composite_pass.isReady() and self.scene_viewport.hdrColor() != null) {
                                try self.ssao_composite_pass.syncTexture(&self.rhi, self.scene_viewport.ssao().?);
                                const ssao_composite_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.overlay(.{ .texture = self.scene_viewport.hdrColor().? }));
                                const ssao_composite_stats = self.ssao_composite_pass.draw(&self.rhi, frame, ssao_composite_render_pass, self.editor_viewport_state.ssao_intensity);
                                draw_stats.add(ssao_composite_stats);
                                self.rhi.endRenderPass(ssao_composite_render_pass);
                            }

                            // SSGI (Screen Space Global Illumination)
                            if (self.editor_viewport_state.ssgi_enabled and self.scene_viewport.ssgi() != null and self.scene_viewport.depth() != null and self.scene_viewport.hdrColor() != null) {
                                if (self.ssgi_compute_pass) |*ssgi_compute| {
                                    if (ssgi_compute.isReady()) {
                                        const mat4_ssgi = @import("../math/mat4.zig");
                                        const inv_proj_ssgi = mat4_ssgi.inverse(prepared_scene.projection_matrix) orelse mat4_ssgi.identity();
                                        const inv_view_ssgi = mat4_ssgi.inverse(prepared_scene.view_matrix) orelse mat4_ssgi.identity();

                                        const ssgi_uniforms = ssgi_compute_pass_mod.SSGIUniforms{
                                            .projection = mat4_ssgi.transpose(prepared_scene.projection_matrix),
                                            .inv_projection = mat4_ssgi.transpose(inv_proj_ssgi),
                                            .view = mat4_ssgi.transpose(prepared_scene.view_matrix),
                                            .inv_view = mat4_ssgi.transpose(inv_view_ssgi),
                                            .resolution = .{ @floatFromInt(self.scene_viewport.width), @floatFromInt(self.scene_viewport.height) },
                                            .radius = self.editor_viewport_state.ssgi_radius,
                                            .intensity = self.editor_viewport_state.ssgi_intensity,
                                            .bias = self.editor_viewport_state.ssgi_bias,
                                            .ray_count = self.editor_viewport_state.ssgi_ray_count,
                                            .step_count = self.editor_viewport_state.ssgi_step_count,
                                        };

                                        ssgi_compute.execute(
                                            &self.rhi,
                                            frame,
                                            self.scene_viewport.ssgi().?,
                                            self.scene_viewport.depth().?,
                                            self.scene_viewport.hdrColor().?,
                                            ssgi_uniforms,
                                        );

                                        // SSGI 合成 (Additive blend to HDR color)
                                        if (self.ssgi_composite_pass.isReady()) {
                                            try self.ssgi_composite_pass.syncTexture(&self.rhi, self.scene_viewport.ssgi().?);
                                            const ssgi_composite_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.overlay(.{ .texture = self.scene_viewport.hdrColor().? }));
                                            const ssgi_composite_stats = self.ssgi_composite_pass.draw(&self.rhi, frame, ssgi_composite_render_pass, 1.0);
                                            draw_stats.add(ssgi_composite_stats);
                                            self.rhi.endRenderPass(ssgi_composite_render_pass);
                                        }
                                    }
                                }
                            }
                        }

                        // Contact Shadows: screen-space ray march for small-scale occlusion
                        const cs_enabled = self.editor_viewport_state.contact_shadows_enabled and
                            self.scene_viewport.contactShadow() != null and
                            self.scene_viewport.depth() != null and
                            self.scene_viewport.hdrColor() != null;
                        if (cs_enabled) {
                            const mat4_cs = @import("../math/mat4.zig");
                            const inv_proj_cs = mat4_cs.inverse(prepared_scene.projection_matrix) orelse mat4_cs.identity();
                            const cs_light_dir: [4]f32 = if (prepared_scene.lights.directional_lights.len > 0) cs_ld: {
                                const dl = prepared_scene.lights.directional_lights[0];
                                break :cs_ld .{ dl.direction[0], dl.direction[1], dl.direction[2], 0.0 };
                            } else .{ 0.3, -0.9, -0.2, 0.0 };

                            const cs_start = std.time.nanoTimestamp();
                            try self.contact_shadow_pass.syncTexture(&self.rhi, self.scene_viewport.depth().?);
                            const cs_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.contactShadow().? }));
                            const cs_stats = self.contact_shadow_pass.draw(&self.rhi, frame, cs_render_pass, .{
                                .projection = prepared_scene.projection_matrix,
                                .inv_projection = inv_proj_cs,
                                .view = prepared_scene.view_matrix,
                                .light_direction = cs_light_dir,
                                .resolution = .{ @floatFromInt(self.scene_viewport.width), @floatFromInt(self.scene_viewport.height) },
                                .max_distance = self.editor_viewport_state.contact_shadows_distance,
                                .thickness = self.editor_viewport_state.contact_shadows_thickness,
                                .intensity = self.editor_viewport_state.contact_shadows_intensity,
                                .bias = self.editor_viewport_state.contact_shadows_bias,
                                .num_steps = @intCast(self.editor_viewport_state.contact_shadows_steps),
                            });
                            draw_stats.add(cs_stats);
                            self.rhi.endRenderPass(cs_render_pass);

                            var cs_composite_draw_calls: usize = 0;
                            var cs_composite_triangles: usize = 0;
                            if (self.contact_shadow_composite_pass.isReady()) {
                                try self.contact_shadow_composite_pass.syncTexture(&self.rhi, self.scene_viewport.contactShadow().?);
                                const cs_composite_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.overlay(.{ .texture = self.scene_viewport.hdrColor().? }));
                                const cs_composite_stats = self.contact_shadow_composite_pass.draw(&self.rhi, frame, cs_composite_pass, 1.0);
                                draw_stats.add(cs_composite_stats);
                                cs_composite_draw_calls = cs_composite_stats.draw_calls;
                                cs_composite_triangles = cs_composite_stats.triangles_drawn;
                                self.rhi.endRenderPass(cs_composite_pass);
                            }

                            self.graph.recordPassStat(
                                pass_stats,
                                .post_process,
                                durationNs(cs_start, std.time.nanoTimestamp()),
                                cs_stats.draw_calls + cs_composite_draw_calls,
                                cs_stats.triangles_drawn + cs_composite_triangles,
                            );
                        }

                        // SSR dispatch
                        if (self.editor_viewport_state.ssr_enabled and
                            self.scene_viewport.ssr() != null and
                            self.scene_viewport.depth() != null and
                            self.scene_viewport.hdrColor() != null and
                            self.ssr_pass.isReady())
                        {
                            const mat4_ssr = @import("../math/mat4.zig");
                            const inv_proj_ssr = mat4_ssr.inverse(prepared_scene.projection_matrix) orelse mat4_ssr.identity();
                            const inv_view_ssr = mat4_ssr.inverse(prepared_scene.view_matrix) orelse mat4_ssr.identity();
                            const ssr_start = std.time.nanoTimestamp();

                            try self.ssr_pass.syncTextures(&self.rhi, self.scene_viewport.hdrColor().?, self.scene_viewport.depth().?);
                            const ssr_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.ssr().? }));
                            const ssr_stats = self.ssr_pass.draw(&self.rhi, frame, ssr_render_pass, .{
                                .projection = prepared_scene.projection_matrix,
                                .inv_projection = inv_proj_ssr,
                                .view = prepared_scene.view_matrix,
                                .inv_view = inv_view_ssr,
                                .resolution = .{ @floatFromInt(self.scene_viewport.width), @floatFromInt(self.scene_viewport.height) },
                                .ray_step = self.editor_viewport_state.ssr_ray_step,
                                .ray_max_distance = self.editor_viewport_state.ssr_ray_max_distance,
                                .ray_thickness = self.editor_viewport_state.ssr_ray_thickness,
                                .intensity = self.editor_viewport_state.ssr_intensity,
                                .fade_distance = self.editor_viewport_state.ssr_fade_distance,
                                .edge_fade = self.editor_viewport_state.ssr_edge_fade,
                            });
                            draw_stats.add(ssr_stats);
                            self.rhi.endRenderPass(ssr_render_pass);

                            // SSR roughness blur: 2-pass separable bilateral Gaussian
                            if (self.editor_viewport_state.ssr_roughness_blur_strength > 0.001 and
                                self.ssr_blur_pass.isReady() and
                                self.scene_viewport.ssrBlur() != null)
                            {
                                const blur_strength = self.editor_viewport_state.ssr_roughness_blur_strength;

                                // Horizontal pass: ssr_texture → ssr_blur_texture
                                try self.ssr_blur_pass.syncTextures(&self.rhi, self.scene_viewport.ssr().?, self.scene_viewport.depth().?);
                                const h_blur_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.ssrBlur().? }));
                                _ = self.ssr_blur_pass.draw(&self.rhi, frame, h_blur_pass, .{
                                    .direction = .{ 1.0, 0.0 },
                                    .blur_strength = blur_strength,
                                    .depth_threshold = 0.01,
                                });
                                self.rhi.endRenderPass(h_blur_pass);

                                // Vertical pass: ssr_blur_texture → ssr_texture
                                try self.ssr_blur_pass.syncTextures(&self.rhi, self.scene_viewport.ssrBlur().?, self.scene_viewport.depth().?);
                                const v_blur_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.ssr().? }));
                                _ = self.ssr_blur_pass.draw(&self.rhi, frame, v_blur_pass, .{
                                    .direction = .{ 0.0, 1.0 },
                                    .blur_strength = blur_strength,
                                    .depth_threshold = 0.01,
                                });
                                self.rhi.endRenderPass(v_blur_pass);
                            }

                            var ssr_composite_draw_calls: usize = 0;
                            var ssr_composite_triangles: usize = 0;
                            if (self.ssgi_composite_pass.isReady()) {
                                try self.ssgi_composite_pass.syncTexture(&self.rhi, self.scene_viewport.ssr().?);
                                const ssr_composite_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.overlay(.{ .texture = self.scene_viewport.hdrColor().? }));
                                const ssr_composite_stats = self.ssgi_composite_pass.draw(&self.rhi, frame, ssr_composite_pass, 1.0);
                                draw_stats.add(ssr_composite_stats);
                                ssr_composite_draw_calls = ssr_composite_stats.draw_calls;
                                ssr_composite_triangles = ssr_composite_stats.triangles_drawn;
                                self.rhi.endRenderPass(ssr_composite_pass);
                            }

                            self.graph.recordPassStat(
                                pass_stats,
                                .post_process,
                                durationNs(ssr_start, std.time.nanoTimestamp()),
                                ssr_stats.draw_calls + ssr_composite_draw_calls,
                                ssr_stats.triangles_drawn + ssr_composite_triangles,
                            );
                        }

                        // TAA resolve: blend current frame with history
                        var taa_resolved = false;
                        if (taa_enabled) {
                            try self.taa_pass.ensureHistoryTexture(&self.rhi, self.scene_viewport.width, self.scene_viewport.height);
                            const taa_requires_seed = !self.taa_pass.hasValidHistory();

                            if (taa_requires_seed) {
                                self.rhi.blitTexture(frame, self.scene_viewport.hdrColor().?, &self.scene_viewport.taa_texture.?);
                                self.rhi.blitTexture(frame, self.scene_viewport.hdrColor().?, &self.taa_pass.history_texture.?);
                                self.taa_pass.markHistoryValid();
                                taa_resolved = true;
                            } else {
                                try self.taa_pass.syncTextures(&self.rhi, self.scene_viewport.hdrColor().?, self.scene_viewport.velocity(), self.scene_viewport.depth());
                                const taa_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.taa().? }));

                                const inv_proj_taa = mat4_mod.inverse(unjittered_projection) orelse mat4_mod.identity();
                                const jitter_history_delta = [2]f32{
                                    self.prev_taa_jitter[0] - current_taa_jitter_uv[0],
                                    self.prev_taa_jitter[1] - current_taa_jitter_uv[1],
                                };

                                const taa_uniforms = taa_pass_mod.TAAUniforms{
                                    .projection = unjittered_projection,
                                    .inv_projection = inv_proj_taa,
                                    .view = prepared_scene.view_matrix,
                                    .prev_view = self.prev_view_matrix,
                                    .resolution = .{ @floatFromInt(self.scene_viewport.width), @floatFromInt(self.scene_viewport.height) },
                                    .jitter = jitter_history_delta,
                                    .blend_factor = self.editor_viewport_state.taa_blend_factor,
                                    .motion_blur_scale = self.editor_viewport_state.taa_motion_blur_scale,
                                    .feedback_min = self.editor_viewport_state.taa_feedback_min,
                                    .feedback_max = self.editor_viewport_state.taa_feedback_max,
                                };
                                const taa_stats = self.taa_pass.draw(&self.rhi, frame, taa_render_pass, taa_uniforms);
                                draw_stats.add(taa_stats);
                                self.rhi.endRenderPass(taa_render_pass);

                                self.rhi.blitTexture(frame, self.scene_viewport.taa().?, &self.taa_pass.history_texture.?);
                                self.taa_pass.markHistoryValid();
                                taa_resolved = true;
                            }

                            self.taa_pass.advanceFrame();
                        } else {
                            self.taa_pass.invalidateHistory();
                        }

                        // Select input for bloom/tonemap: use TAA output if resolved, otherwise HDR scene color.
                        var hdr_input_for_post = if (taa_resolved) self.scene_viewport.taa().? else self.scene_viewport.hdrColor().?;

                        if (bloom_enabled) {
                            try self.bloom_pass.syncTexture(&self.rhi, hdr_input_for_post);
                            const bloom_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.bloom().? }));
                            const bloom_start = std.time.nanoTimestamp();
                            const bloom_stats = self.bloom_pass.draw(&self.rhi, frame, bloom_render_pass, .{
                                .threshold_params = .{
                                    self.editor_viewport_state.bloom_threshold,
                                    0.5,
                                    0.0,
                                    0.0,
                                },
                            });
                            draw_stats.add(bloom_stats);
                            self.graph.recordPassStat(pass_stats, .post_process, durationNs(bloom_start, std.time.nanoTimestamp()), bloom_stats.draw_calls, bloom_stats.triangles_drawn);
                            self.rhi.endRenderPass(bloom_render_pass);
                        }

                        // DOF dispatch — 3-subpass pipeline: CoC → Blur → Composite
                        if (self.editor_viewport_state.dof_enabled and self.dof_runtime_pass.isReady()) {
                            if (self.scene_viewport.depth()) |depth_tex| {
                                const dof_start = std.time.nanoTimestamp();
                                const dof_w = self.scene_viewport.width;
                                const dof_h = self.scene_viewport.height;

                                const inv_proj_dof = mat4_mod.inverse(unjittered_projection) orelse mat4_mod.identity();
                                const dof_uniforms = dof_runtime_pass_mod.DofUniforms{
                                    .projection = unjittered_projection,
                                    .inv_projection = inv_proj_dof,
                                    .resolution = .{ @floatFromInt(dof_w), @floatFromInt(dof_h) },
                                    .focus_distance = self.editor_viewport_state.dof_focus_distance,
                                    .focus_range = self.editor_viewport_state.dof_focus_range,
                                    .blur_radius = self.editor_viewport_state.dof_blur_radius,
                                    .bokeh_radius = self.editor_viewport_state.dof_bokeh_radius,
                                    .near_blur = self.editor_viewport_state.dof_near_blur,
                                    .far_blur = self.editor_viewport_state.dof_far_blur,
                                    .quality = self.editor_viewport_state.dof_quality,
                                };

                                self.dof_runtime_pass.ensureIntermediateTextures(&self.rhi, dof_w, dof_h) catch |err| {
                                    render_log.err("failed to ensure DoF intermediate textures: {s}", .{@errorName(err)});
                                };

                                if (self.dof_runtime_pass.coc_texture != null and
                                    self.dof_runtime_pass.blur_texture != null and
                                    self.dof_runtime_pass.output_texture != null)
                                {
                                    var dof_total_stats = mesh_pass_mod.DrawStats{};

                                    // Subpass 0: CoC generation (reads color + depth)
                                    self.dof_runtime_pass.syncCocBindGroup(&self.rhi, hdr_input_for_post, depth_tex) catch |err| {
                                        render_log.err("failed to sync DoF CoC bind group: {s}", .{@errorName(err)});
                                    };
                                    const coc_render_pass = self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = &self.dof_runtime_pass.coc_texture.? })) catch null;
                                    if (coc_render_pass) |coc_rp| {
                                        dof_total_stats.add(self.dof_runtime_pass.drawCoc(&self.rhi, frame, coc_rp, dof_uniforms));
                                        self.rhi.endRenderPass(coc_rp);
                                    }

                                    // Subpass 1: Blur (reads color + CoC)
                                    self.dof_runtime_pass.syncBlurBindGroup(&self.rhi, hdr_input_for_post) catch |err| {
                                        render_log.err("failed to sync DoF blur bind group: {s}", .{@errorName(err)});
                                    };
                                    const blur_render_pass = self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = &self.dof_runtime_pass.blur_texture.? })) catch null;
                                    if (blur_render_pass) |blur_rp| {
                                        dof_total_stats.add(self.dof_runtime_pass.drawBlur(&self.rhi, frame, blur_rp, dof_uniforms));
                                        self.rhi.endRenderPass(blur_rp);
                                    }

                                    // Subpass 2: Composite (reads color + blur + CoC → output)
                                    self.dof_runtime_pass.syncCompositeBindGroup(&self.rhi, hdr_input_for_post) catch |err| {
                                        render_log.err("failed to sync DoF composite bind group: {s}", .{@errorName(err)});
                                    };
                                    const composite_render_pass = self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = &self.dof_runtime_pass.output_texture.? })) catch null;
                                    if (composite_render_pass) |comp_rp| {
                                        dof_total_stats.add(self.dof_runtime_pass.drawComposite(&self.rhi, frame, comp_rp, dof_uniforms));
                                        self.rhi.endRenderPass(comp_rp);
                                    }

                                    // Swap tonemap input to DOF output
                                    if (self.dof_runtime_pass.output()) |dof_out| {
                                        hdr_input_for_post = dof_out;
                                    }

                                    self.graph.recordPassStat(pass_stats, .post_process, durationNs(dof_start, std.time.nanoTimestamp()), dof_total_stats.draw_calls, dof_total_stats.triangles_drawn);
                                }
                            }
                        }

                        try self.tonemap_pass.syncTextures(
                            &self.rhi,
                            hdr_input_for_post,
                            if (bloom_enabled) self.scene_viewport.bloom().? else null,
                            null,
                        );
                        const tm_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.color().? }));
                        const tm_start = std.time.nanoTimestamp();
                        const tonemap_stats = self.tonemap_pass.draw(&self.rhi, frame, tm_render_pass, .{
                            .exposure_params = .{
                                @as(f32, if (self.editor_viewport_state.exposure_enabled) 1.0 else 0.0),
                                self.editor_viewport_state.exposure,
                                0.0,
                                0.0,
                            },
                            .bloom_params = .{
                                @as(f32, if (bloom_enabled) 1.0 else 0.0),
                                self.editor_viewport_state.bloom_intensity,
                                0.0,
                                0.0,
                            },
                            .color_grading_params = .{
                                @as(f32, if (self.editor_viewport_state.color_grading_enabled) 1.0 else 0.0),
                                self.editor_viewport_state.color_grading_saturation,
                                self.editor_viewport_state.color_grading_contrast,
                                self.editor_viewport_state.color_grading_gamma,
                            },
                            .lut_params = .{
                                0.0,
                                self.editor_viewport_state.lut_intensity,
                                0.0,
                                0.0,
                            },
                        });
                        draw_stats.add(tonemap_stats);
                        self.graph.recordPassStat(pass_stats, .tonemap_pass, durationNs(tm_start, std.time.nanoTimestamp()), tonemap_stats.draw_calls, tonemap_stats.triangles_drawn);
                        self.rhi.endRenderPass(tm_render_pass);

                        if (fxaa_enabled) {
                            const fxaa_start = std.time.nanoTimestamp();
                            try self.fxaa_pass.syncTexture(&self.rhi, self.scene_viewport.color().?);
                            const fxaa_render_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.postProcess(.{ .texture = self.scene_viewport.fxaa().? }));
                            const fxaa_stats = self.fxaa_pass.draw(&self.rhi, frame, fxaa_render_pass);
                            draw_stats.add(fxaa_stats);
                            self.graph.recordPassStat(pass_stats, .post_process, durationNs(fxaa_start, std.time.nanoTimestamp()), fxaa_stats.draw_calls, fxaa_stats.triangles_drawn);
                            self.rhi.endRenderPass(fxaa_render_pass);
                        }
                    }
                }

                // --- 公共 overlay passes：所有模式（Raster/PathTrace/HW RT）都运行 ---
                const selected_entities = self.selection_history.currentSelection();
                const ai_focus_entities = self.ai_focus_entity_ids[0..self.ai_focus_entity_count];
                if (self.outline_pass.isReady() and self.id_pass.texture() != null and (selected_entities.len > 0 or ai_focus_entities.len > 0)) {
                    try self.outline_pass.syncTexture(&self.rhi, self.id_pass.texture().?);
                    const outline_pass = try self.rhi.beginRenderPassWithDesc(frame, PassDescriptors.overlay(scene_color_target));
                    const outline_start = std.time.nanoTimestamp();
                    var outline_stats = mesh_pass_mod.DrawStats{};
                    if (selected_entities.len > 0) {
                        outline_stats.add(self.outline_pass.draw(&self.rhi, frame, outline_pass, selected_entities));
                    }
                    if (ai_focus_entities.len > 0) {
                        const pulse = 0.65 + 0.35 * @sin(@as(f32, @floatCast(@as(f64, @floatFromInt(std.time.milliTimestamp())) / 220.0)));
                        outline_stats.add(self.outline_pass.drawWithColor(
                            &self.rhi,
                            frame,
                            outline_pass,
                            ai_focus_entities,
                            .{ 0.70, 0.35, 1.0, pulse },
                        ));
                    }
                    self.graph.recordPassStat(pass_stats, .outline_pass, durationNs(outline_start, std.time.nanoTimestamp()), outline_stats.draw_calls, outline_stats.triangles_drawn);
                    draw_stats.add(outline_stats);
                    self.rhi.endRenderPass(outline_pass);
                }

                if (self.gizmoPassRequired(scene)) {
                    const gizmo_pass_desc = if (scene_depth_target) |depth_target|
                        PassDescriptors.overlayWithDepth(scene_color_target, .{
                            .texture = depth_target.texture,
                            .clear_depth = depth_target.clear_depth,
                            .clear_stencil = depth_target.clear_stencil,
                            .load_op = .load,
                            .store_op = .store,
                            .stencil_load_op = depth_target.stencil_load_op,
                            .stencil_store_op = depth_target.stencil_store_op,
                        })
                    else
                        PassDescriptors.overlay(scene_color_target);
                    const gizmo_pass = try self.rhi.beginRenderPassWithDesc(frame, gizmo_pass_desc);
                    const gizmo_start = std.time.nanoTimestamp();
                    var gizmo_overlay_stats = mesh_pass_mod.DrawStats{};
                    const gizmo_target_transform = if (self.editor_gizmo_transform_override) |override_transform|
                        override_transform
                    else if (self.preview_gizmo_transform) |preview_transform|
                        preview_transform
                    else if (self.selection_history.primarySelection()) |selected_entity_id|
                        scene.worldTransformConst(selected_entity_id)
                    else
                        null;
                    if (gizmo_target_transform) |selected_transform| {
                        const gizmo_stats = self.gizmo_pass.draw(
                            &self.rhi,
                            frame,
                            gizmo_pass,
                            &prepared_scene,
                            selected_transform,
                            self.editor_gizmo_state,
                        );
                        gizmo_overlay_stats.add(gizmo_stats);
                        draw_stats.add(gizmo_stats);
                    }

                    const debug_stats = try self.drawViewportDebugOverlays(frame, gizmo_pass, scene, &prepared_scene, physics_state_opt);
                    gizmo_overlay_stats.add(debug_stats);
                    draw_stats.add(debug_stats);
                    self.graph.recordPassStat(pass_stats, .gizmo_overlay, durationNs(gizmo_start, std.time.nanoTimestamp()), gizmo_overlay_stats.draw_calls, gizmo_overlay_stats.triangles_drawn);
                    self.rhi.endRenderPass(gizmo_pass);
                }

                // Store previous-frame camera/object state for TAA reprojection and velocity.
                self.prev_view_matrix = prepared_scene.view_matrix;
                self.prev_view_projection = current_unjittered_view_projection;
                self.prev_taa_jitter = current_taa_jitter_uv;
                try self.cachePreviousMeshModels(&prepared_scene);
            }

            const material_editor_preview_stats = try self.processMaterialEditorPreview(frame);
            draw_stats.add(material_editor_preview_stats);

            const thumbnail_stats = try self.processMaterialThumbnailRequests(frame, scene);
            draw_stats.add(thumbnail_stats);

            const model_thumbnail_stats = try self.processModelThumbnailRequests(frame);
            draw_stats.add(model_thumbnail_stats);

            if (has_swapchain) {
                const ui_cmd = self.rhi.activeCommandBuffer() orelse return error.CommandBufferAcquireFailed;
                const ui_pass = try self.rhi.beginRenderPassWithDesc(frame, .{
                    .color = .{
                        .target = .swapchain,
                        .clear_color = clear.color,
                        .load_op = if (viewport_active) .clear else .load,
                        .store_op = .store,
                    },
                    .depth = null,
                });
                const ui_start = std.time.nanoTimestamp();
                _ = ui_cmd;
                self.graph.recordPassStat(pass_stats, .ui_overlay, durationNs(ui_start, std.time.nanoTimestamp()), 0, 0);
                self.rhi.endRenderPass(ui_pass);
            }

            if (self.pending_selection_readbacks.items.len > 0) {
                const id_pick_available = can_render_scene and self.id_pass.texture() != null;
                if (id_pick_available) {
                    const id_texture = self.id_pass.texture().?;
                    try self.enqueueSelectionReadbacks(frame, id_texture);
                } else {
                    try self.rhi.submitFrame(frame);
                    try self.applyPendingSelectionMisses();
                }
            } else {
                try self.rhi.submitFrame(frame);
            }
            try self.resolveSelectionReadbacks();

            // Blit is now done at the TOP of the next frame (double-buffered
            // pipeline).  See the waitForPreviousFrame + blitSharedTexture
            // block near the start of drawFrame.
            // On Vulkan, the blit is still synchronous inside blitSharedTexture.
            if (viewport_active and self.scene_viewport.use_iosurface and self.rhi.api == .vulkan) {
                if (self.scene_viewport.color_texture) |tex| {
                    _ = self.rhi.blitSharedTexture(tex);
                }
            }

            // Collect RHI stats
            var cache_hits: u64 = 0;
            var cache_misses: u64 = 0;
            var delta_hits: u64 = 0;
            var delta_misses: u64 = 0;
            var delta_evictions: u64 = 0;
            var slot_errors: usize = 0;
            if (self.rhi_device) |dev| {
                const cs = dev.bindingSetCacheStats();
                cache_hits = cs.hits;
                cache_misses = cs.misses;
                const frame_delta = dev.snapshotFrameStats();
                delta_hits = frame_delta.hits;
                delta_misses = frame_delta.misses;
                delta_evictions = frame_delta.evictions;

                // Slot-layout consistency validation against compiled graph
                const errs = self.graph.validateSlotLayoutConstraints(self.allocator, dev) catch &.{};
                slot_errors = errs.len;
                if (errs.len > 0) {
                    for (errs) |se| {
                        std.log.warn("slot-layout mismatch: pass={s} slot={} expected_layout={}", .{ se.pass_name, se.slot, se.expected_layout_id });
                    }
                    self.allocator.free(errs);
                }
            }

            break :blk FrameReport{
                .backend = self.rhi.api,
                .passes_executed = self.passCount(),
                .graph_resources = self.graph.resourceCount(),
                .scene = snapshot,
                .runtime = self.runtimeInfo(),
                .draw_calls = draw_stats.draw_calls,
                .triangles_drawn = draw_stats.triangles_drawn,
                .binding_cache_hits = cache_hits,
                .binding_cache_misses = cache_misses,
                .slot_layout_errors = slot_errors,
                .binding_cache_hits_delta = delta_hits,
                .binding_cache_misses_delta = delta_misses,
                .binding_cache_evictions_delta = delta_evictions,
            };
        };

        // Only write frame report on first frame to avoid per-frame disk I/O
        if (!g_logged_viewport_backend) {
            const entry_count: u32 = if (self.rhi_device) |dev| dev.bindingSetCacheEntryCount() else 0;
            self.graph.writeFrameReportWithCacheStats(
                self.allocator,
                "dist/reports/latest_frame_report.json",
                rhi_types.graphicsApiName(self.rhi.api),
                result.draw_calls,
                result.triangles_drawn,
                pass_stats,
                .{ .hits = result.binding_cache_hits, .misses = result.binding_cache_misses, .entries = entry_count },
            ) catch |err| {
                std.log.warn("failed to write frame report: {}", .{err});
            };
        }
        return result;
    }

    fn populatePathTraceSceneState(
        self: *Renderer,
        pt: *PathTraceProgressiveState,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        scene: *scene_mod.Scene,
        path_trace_environment: PathTraceEnvironment,
    ) !void {
        if (pt.triangles != null) return;

        var triangle_list = std.ArrayList(PathTraceTriangle).empty;
        defer triangle_list.deinit(self.allocator);
        var mesh_list = std.ArrayList(PathTraceMesh).empty;
        defer mesh_list.deinit(self.allocator);
        var texture_list = std.ArrayList(PathTraceTexture).empty;
        defer texture_list.deinit(self.allocator);
        var texture_index_map = std.AutoHashMap(u32, i32).init(self.allocator);
        defer texture_index_map.deinit();

        const draw_batches = [_]struct {
            items: []const mesh_pass_mod.DrawItem,
            is_transparent: bool,
        }{
            .{ .items = prepared_scene.opaque_meshes, .is_transparent = false },
            .{ .items = prepared_scene.transparent_meshes, .is_transparent = true },
        };
        for (draw_batches) |batch| {
            for (batch.items) |item| {
                const mesh_res = if (handles.isValid(item.mesh_handle))
                    scene.resources.mesh(item.mesh_handle)
                else
                    null;

                if (mesh_res) |mesh| {
                    const entity = scene.getEntityConst(item.entity_id);
                    const mat_comp = if (entity) |resolved_entity| resolved_entity.material else null;
                    const mat_res = blk_mat: {
                        const resolved_comp = mat_comp orelse break :blk_mat null;
                        const mat_handle = resolved_comp.handle orelse break :blk_mat null;
                        break :blk_mat scene.resources.material(mat_handle);
                    };

                    var shading: components.ShadingModel = if (mat_comp) |resolved_comp|
                        resolved_comp.shading
                    else
                        .pbr_metallic_roughness;
                    var alpha_cutoff = std.math.clamp(item.pbr_factors[2], 0.0, 1.0);
                    if (mat_res) |material| {
                        shading = material.shading;
                        alpha_cutoff = std.math.clamp(material.alpha_cutoff, 0.0, 1.0);
                    }

                    const opacity = std.math.clamp(item.base_color_factor[3] * item.pbr_factors[3], 0.0, 1.0);
                    if (batch.is_transparent and (opacity <= 0.001 or opacity < alpha_cutoff)) {
                        continue;
                    }

                    var albedo = [3]f32{
                        std.math.clamp(item.base_color_factor[0], 0.0, 1.0),
                        std.math.clamp(item.base_color_factor[1], 0.0, 1.0),
                        std.math.clamp(item.base_color_factor[2], 0.0, 1.0),
                    };
                    var emissive = [3]f32{
                        item.emissive_factor[0] * item.emissive_factor[3],
                        item.emissive_factor[1] * item.emissive_factor[3],
                        item.emissive_factor[2] * item.emissive_factor[3],
                    };
                    var metallic = std.math.clamp(item.pbr_factors[0], 0.0, 1.0);
                    var roughness = std.math.clamp(item.pbr_factors[1], 0.04, 1.0);
                    var transmission = std.math.clamp(1.0 - opacity, 0.0, 0.96);
                    var ior: f32 = 1.5;
                    var thickness: f32 = std.math.clamp((1.0 - opacity) * 0.75 + 0.05, 0.01, 2.0);

                    if (batch.is_transparent) {
                        albedo = vec3.scale(albedo, opacity);
                        roughness = std.math.clamp(roughness + (1.0 - opacity) * 0.35, 0.04, 1.0);
                    } else {
                        albedo = .{
                            std.math.clamp(albedo[0], 0.02, 1.0),
                            std.math.clamp(albedo[1], 0.02, 1.0),
                            std.math.clamp(albedo[2], 0.02, 1.0),
                        };
                    }

                    switch (shading) {
                        .unlit => {
                            emissive = vec3.add(emissive, vec3.scale(albedo, 1.2));
                            albedo = vec3.scale(albedo, 0.06);
                            metallic = 0.0;
                            roughness = 1.0;
                            transmission = 0.0;
                            thickness = 0.0;
                        },
                        .lambert => {
                            metallic = 0.0;
                            roughness = @max(roughness, 0.65);
                            ior = 1.45;
                            thickness = std.math.clamp(thickness * 0.5, 0.0, 1.0);
                        },
                        .pbr_metallic_roughness => {
                            ior = 1.52;
                        },
                    }

                    const texture_indices = try resolvePathTraceTextureIndices(
                        self.allocator,
                        &texture_list,
                        &texture_index_map,
                        &scene.resources,
                        mat_res,
                        item.has_textures,
                    );

                    const tri_start: u32 = @intCast(triangle_list.items.len);
                    const indices = mesh.indices;
                    const vertices = mesh.vertices;
                    var aabb = AABB.empty();
                    var i: usize = 0;
                    while (i + 2 < indices.len) : (i += 3) {
                        const idx0 = indices[i];
                        const idx1 = indices[i + 1];
                        const idx2 = indices[i + 2];
                        if (idx0 >= vertices.len or idx1 >= vertices.len or idx2 >= vertices.len) continue;

                        const v0 = transformPoint(item.model, vertices[idx0].position);
                        const v1 = transformPoint(item.model, vertices[idx1].position);
                        const v2 = transformPoint(item.model, vertices[idx2].position);
                        const n0 = transformNormal(item.model, vertices[idx0].normal);
                        const n1 = transformNormal(item.model, vertices[idx1].normal);
                        const n2 = transformNormal(item.model, vertices[idx2].normal);

                        aabb.expand(v0);
                        aabb.expand(v1);
                        aabb.expand(v2);

                        try triangle_list.append(self.allocator, .{
                            .v0 = v0,
                            .v1 = v1,
                            .v2 = v2,
                            .n0 = n0,
                            .n1 = n1,
                            .n2 = n2,
                            .uv0 = vertices[idx0].uv,
                            .uv1 = vertices[idx1].uv,
                            .uv2 = vertices[idx2].uv,
                            .albedo = albedo,
                            .emissive = emissive,
                            .metallic = metallic,
                            .roughness = roughness,
                            .transmission = transmission,
                            .ior = ior,
                            .thickness = thickness,
                            .base_color_texture_index = texture_indices.base_color,
                            .metallic_roughness_texture_index = texture_indices.metallic_roughness,
                            .normal_texture_index = texture_indices.normal,
                            .occlusion_texture_index = texture_indices.occlusion,
                            .emissive_texture_index = texture_indices.emissive,
                        });
                    }

                    const tri_count: u32 = @intCast(triangle_list.items.len - tri_start);
                    if (tri_count > 0) {
                        try mesh_list.append(self.allocator, .{
                            .aabb = aabb,
                            .tri_start = tri_start,
                            .tri_count = tri_count,
                        });
                    }
                }
            }
        }

        if (triangle_list.items.len == 0) {
            try triangle_list.append(self.allocator, .{
                .v0 = .{ -5.0, 0.0, -5.0 },
                .v1 = .{ 5.0, 0.0, -5.0 },
                .v2 = .{ 5.0, 0.0, 5.0 },
                .n0 = .{ 0.0, 1.0, 0.0 },
                .n1 = .{ 0.0, 1.0, 0.0 },
                .n2 = .{ 0.0, 1.0, 0.0 },
                .uv0 = .{ 0.0, 0.0 },
                .uv1 = .{ 1.0, 0.0 },
                .uv2 = .{ 1.0, 1.0 },
                .albedo = .{ 0.6, 0.6, 0.6 },
                .emissive = .{ 0.0, 0.0, 0.0 },
                .metallic = 0.0,
                .roughness = 0.8,
                .transmission = 0.0,
                .ior = 1.5,
                .thickness = 0.0,
            });
            try triangle_list.append(self.allocator, .{
                .v0 = .{ -5.0, 0.0, -5.0 },
                .v1 = .{ 5.0, 0.0, 5.0 },
                .v2 = .{ -5.0, 0.0, 5.0 },
                .n0 = .{ 0.0, 1.0, 0.0 },
                .n1 = .{ 0.0, 1.0, 0.0 },
                .n2 = .{ 0.0, 1.0, 0.0 },
                .uv0 = .{ 0.0, 0.0 },
                .uv1 = .{ 1.0, 1.0 },
                .uv2 = .{ 0.0, 1.0 },
                .albedo = .{ 0.6, 0.6, 0.6 },
                .emissive = .{ 0.0, 0.0, 0.0 },
                .metallic = 0.0,
                .roughness = 0.8,
                .transmission = 0.0,
                .ior = 1.5,
                .thickness = 0.0,
            });
            try mesh_list.append(self.allocator, .{
                .aabb = .{ .min = .{ -5.0, -0.01, -5.0 }, .max = .{ 5.0, 0.01, 5.0 } },
                .tri_start = 0,
                .tri_count = 2,
            });
        }

        pt.triangles = try self.allocator.dupe(PathTraceTriangle, triangle_list.items);
        pt.meshes = try self.allocator.dupe(PathTraceMesh, mesh_list.items);
        pt.textures = try self.allocator.dupe(PathTraceTexture, texture_list.items);
        const built_emissive_lights = try buildPathTraceEmissiveLights(self.allocator, pt.triangles.?);
        errdefer if (built_emissive_lights.items) |items| self.allocator.free(items);
        pt.emissive_lights = built_emissive_lights.items;
        pt.emissive_total_area = built_emissive_lights.total_area;
        if (prepared_scene.lights.point_lights.len > 0) {
            var point_lights = try self.allocator.alloc(PathTracePointLight, prepared_scene.lights.point_lights.len);
            for (prepared_scene.lights.point_lights, 0..) |light, index| {
                point_lights[index] = .{
                    .position = light.position,
                    .color = light.color,
                    .intensity = light.intensity,
                    .range = light.range,
                };
            }
            pt.point_lights = point_lights;
        } else {
            pt.point_lights = null;
        }
        if (prepared_scene.lights.spot_lights.len > 0) {
            var spot_lights = try self.allocator.alloc(PathTraceSpotLight, prepared_scene.lights.spot_lights.len);
            for (prepared_scene.lights.spot_lights, 0..) |light, index| {
                spot_lights[index] = .{
                    .position = light.position,
                    .direction = light.direction,
                    .color = light.color,
                    .intensity = light.intensity,
                    .range = light.range,
                    .inner_angle_cos = light.inner_angle_cos,
                    .outer_angle_cos = light.outer_angle_cos,
                };
            }
            pt.spot_lights = spot_lights;
        } else {
            pt.spot_lights = null;
        }
        const built_environment_importance = try buildPathTraceEnvironmentImportance(self.allocator, path_trace_environment.texture);
        errdefer if (built_environment_importance.items) |items| self.allocator.free(items);
        pt.environment_importance = built_environment_importance.items;
        pt.environment_importance_width = built_environment_importance.width;
        pt.environment_importance_height = built_environment_importance.height;
        pt.inv_view_projection = mat4_mod.inverse(prepared_scene.view_projection) orelse mat4_mod.identity();
        pt.camera_origin = .{
            prepared_scene.camera_world_position[0],
            prepared_scene.camera_world_position[1],
            prepared_scene.camera_world_position[2],
        };
        if (prepared_scene.lights.directional_lights.len > 0) {
            const light = prepared_scene.lights.directional_lights[0];
            pt.light_direction = vec3.normalize(vec3.scale(light.direction, -1.0));
            pt.light_radiance = vec3.scale(light.color, light.intensity);
        } else {
            pt.light_direction = vec3.normalize(.{ 0.38, 0.82, 0.42 });
            pt.light_radiance = .{ 0.0, 0.0, 0.0 };
        }
        pt.environment_texture = path_trace_environment.texture;
    }

    fn ensurePathTraceBuffers(
        self: *Renderer,
        pt: *PathTraceProgressiveState,
        trace_width: u32,
        trace_height: u32,
        target_width: u32,
        target_height: u32,
    ) !void {
        if (pt.trace_linear_rgb == null) {
            pt.trace_linear_rgb = try self.allocator.alloc(f32, @as(usize, trace_width) * @as(usize, trace_height) * 3);
            @memset(pt.trace_linear_rgb.?, 0);
            pt.trace_width = trace_width;
            pt.trace_height = trace_height;
        }
        if (pt.display_pixels == null) {
            pt.display_pixels = try self.allocator.alloc(u8, @as(usize, target_width) * @as(usize, target_height) * 8);
            @memset(pt.display_pixels.?, 0);
            pt.target_width = target_width;
            pt.target_height = target_height;
        }
    }

    fn buildOfflinePathTraceExportState(
        self: *Renderer,
        scene: *scene_mod.Scene,
        width: u32,
        height: u32,
        samples: u32,
        bounces: u32,
        render_beauty: bool,
    ) !PathTraceProgressiveState {
        const extraction_frustum = buildSceneExtractionFrustum(&self.scene_cache, scene, width, height);
        _ = try scene_extraction.extractWorld(
            scene,
            &self.render_world,
            self.selection_history.primarySelection(),
            self.selection_history.currentSelection(),
            extraction_frustum,
        );

        var prepared_scene = try self.scene_cache.prepareScene(
            &self.rhi,
            scene,
            &self.render_world,
            width,
            height,
        );
        defer prepared_scene.deinit();

        var pt = PathTraceProgressiveState{
            .trace_width = width,
            .trace_height = height,
            .target_width = width,
            .target_height = height,
            .cached_samples = samples,
            .cached_bounces = bounces,
            .sample_step = computePathTraceSampleStep(width, height),
        };
        errdefer pt.deinit(self.allocator);

        try self.populatePathTraceSceneState(&pt, &prepared_scene, scene, resolvePathTraceEnvironment(self, scene));
        if (render_beauty) {
            try self.ensurePathTraceBuffers(&pt, width, height, width, height);
            renderer_path_trace.renderCpuPathTraceTiles(&pt, false, 0);
            renderer_path_trace.resolvePathTraceDisplayPixels(&pt);
        }
        return pt;
    }

    fn renderPathTraceViewport(self: *Renderer, prepared_scene: *const mesh_pass_mod.PreparedScene, scene: *scene_mod.Scene) !void {
        const target = self.scene_viewport.hdrColor() orelse return;
        const width = target.desc.width;
        const height = target.desc.height;
        if (width == 0 or height == 0) return;

        const path_trace_environment = resolvePathTraceEnvironment(self, scene);
        const scene_signature = computePathTraceSceneSignature(prepared_scene, scene, path_trace_environment);

        const samples = std.math.clamp(self.editor_viewport_state.path_trace_samples, 1, 2048);
        const bounces = std.math.clamp(self.editor_viewport_state.path_trace_bounces, 1, 12);
        const resolution_scale = std.math.clamp(self.editor_viewport_state.path_trace_resolution_scale, 0.25, 1.0);
        const trace_width = @max(@as(u32, 1), @as(u32, @intFromFloat(@as(f32, @floatFromInt(width)) * resolution_scale)));
        const trace_height = @max(@as(u32, 1), @as(u32, @intFromFloat(@as(f32, @floatFromInt(height)) * resolution_scale)));

        // 默认优先尝试与 CPU Phase 5 积分器对齐后的 Metal RT 路径。
        if (!self.editor_viewport_state.path_trace_force_cpu) {
            if (self.tryRenderHwRtPath(prepared_scene, scene, target, width, height, trace_width, trace_height, samples, bounces, resolution_scale)) {
                return;
            }
        }

        if (!g_logged_path_trace_active) {
            render_log.info("CPU path trace viewport active (progressive)", .{});
            g_logged_path_trace_active = true;
        }

        var pt = &self.path_trace_state;

        // --- 检测变化，需要时重置 ---
        const vp_changed = !std.mem.eql(u8, std.mem.asBytes(&prepared_scene.view_projection), std.mem.asBytes(&pt.last_view_projection));
        const size_changed = trace_width != pt.trace_width or trace_height != pt.trace_height or width != pt.target_width or height != pt.target_height;
        const params_changed = samples != pt.last_samples or bounces != pt.last_bounces or resolution_scale != pt.last_resolution_scale;
        const environment_changed = path_trace_environment.handle != pt.last_environment_texture_handle;
        const scene_changed = scene_signature != pt.last_scene_signature;

        if (vp_changed or params_changed or environment_changed or scene_changed) {
            pt.reset(self.allocator);
            if (pt.trace_linear_rgb) |buffer| @memset(buffer, 0);
            if (pt.display_pixels) |buffer| @memset(buffer, 0);
        }

        if (size_changed) {
            pt.reset(self.allocator);
            if (pt.trace_linear_rgb) |p| self.allocator.free(p);
            if (pt.display_pixels) |p| self.allocator.free(p);
            pt.trace_linear_rgb = null;
            pt.display_pixels = null;
        }

        // 更新变化检测用的缓存值
        pt.last_view_projection = prepared_scene.view_projection;
        pt.last_samples = samples;
        pt.last_bounces = bounces;
        pt.last_resolution_scale = resolution_scale;
        pt.last_environment_texture_handle = path_trace_environment.handle;
        pt.last_scene_signature = scene_signature;
        pt.environment_texture = path_trace_environment.texture;

        try self.ensurePathTraceBuffers(pt, trace_width, trace_height, width, height);

        // 如果已经渲染完成，直接上传缓存结果
        if (pt.complete) {
            try self.rhi.uploadTextureData(target, pt.display_pixels.?, width, height);
            return;
        }

        try self.populatePathTraceSceneState(pt, prepared_scene, scene, path_trace_environment);
        pt.cached_samples = samples;
        pt.cached_bounces = bounces;
        pt.environment_texture = path_trace_environment.texture;
        pt.sample_step = computePathTraceSampleStep(trace_width, trace_height);

        renderer_path_trace.renderCpuPathTraceTiles(pt, !self.editor_viewport_state.path_trace_force_cpu, 8_000_000);
        renderer_path_trace.resolvePathTraceDisplayPixels(pt);
        try self.rhi.uploadTextureData(target, pt.display_pixels.?, width, height);
    }

    // ==================================================================
    // RT Shadows — 光栅模式下的硬件 RT 阴影遮罩
    // ==================================================================

    /// 尝试渲染 RT 阴影遮罩用于光栅模式。成功返回 true，遮罩纹理可用于合成。
    fn tryRenderRtShadows(
        self: *Renderer,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        scene: *scene_mod.Scene,
        width: u32,
        height: u32,
    ) bool {
        if (width == 0 or height == 0) return false;

        // 懒初始化硬件 RT 后端
        switch (self.rhi.ensureRtDevice()) {
            .ready, .initialized => {},
            .unavailable => return false,
        }
        var mrt = &self.hw_rt_state;

        // --- 变化检测 ---
        const vp_changed = !std.mem.eql(u8, std.mem.asBytes(&prepared_scene.view_projection), std.mem.asBytes(&self.rt_shadow_last_vp));
        if (vp_changed) {
            self.rt_shadow_last_vp = prepared_scene.view_projection;
        } else if (self.rt_shadow_mask_texture != null and self.rt_shadow_width == width and self.rt_shadow_height == height) {
            return true; // 已缓存的遮罩仍然有效
        }

        // --- 构建三角形数据 (复用 hw_rt_state) ---
        if (mrt.triangles == null) {
            var triangle_list: std.ArrayListUnmanaged(rt_backend.RtTriangle) = .empty;
            defer triangle_list.deinit(self.allocator);

            var texture_list = std.ArrayList(struct { pixels: []const u8, width: u32, height: u32, format: rhi_types.TextureFormat }).empty;
            defer texture_list.deinit(self.allocator);
            var texture_index_map = std.AutoHashMap(u32, i32).init(self.allocator);
            defer texture_index_map.deinit();

            for (prepared_scene.opaque_meshes) |item| {
                const mesh_res = if (handles.isValid(item.mesh_handle))
                    scene.resources.mesh(item.mesh_handle)
                else
                    null;
                if (mesh_res) |mesh| {
                    const indices = mesh.indices;
                    const vertices = mesh.vertices;
                    const albedo = [3]f32{
                        std.math.clamp(item.base_color_factor[0], 0.02, 1.0),
                        std.math.clamp(item.base_color_factor[1], 0.02, 1.0),
                        std.math.clamp(item.base_color_factor[2], 0.02, 1.0),
                    };
                    const emissive = [3]f32{
                        item.emissive_factor[0] * item.emissive_factor[3],
                        item.emissive_factor[1] * item.emissive_factor[3],
                        item.emissive_factor[2] * item.emissive_factor[3],
                    };
                    const metallic = std.math.clamp(item.pbr_factors[0], 0.0, 1.0);
                    const roughness = std.math.clamp(item.pbr_factors[1], 0.04, 1.0);

                    const tex_idx: i32 = blk_tex: {
                        if (item.has_textures[0] == 0) break :blk_tex @as(i32, -1);
                        const entity = scene.getEntityConst(item.entity_id) orelse break :blk_tex @as(i32, -1);
                        const mat_comp = entity.material orelse break :blk_tex @as(i32, -1);
                        const mat_handle = mat_comp.handle orelse break :blk_tex @as(i32, -1);
                        const mat_res = scene.resources.material(mat_handle) orelse break :blk_tex @as(i32, -1);
                        const tex_handle = mat_res.base_color_texture orelse break :blk_tex @as(i32, -1);
                        const tex_key = @intFromEnum(tex_handle);
                        if (texture_index_map.get(tex_key)) |existing| break :blk_tex existing;
                        const tex_res = scene.resources.texture(tex_handle) orelse break :blk_tex @as(i32, -1);
                        if (tex_res.pixels.len == 0 or tex_res.width == 0 or tex_res.height == 0) break :blk_tex @as(i32, -1);
                        const idx_i32: i32 = @intCast(texture_list.items.len);
                        texture_list.append(self.allocator, .{
                            .pixels = tex_res.pixels,
                            .width = tex_res.width,
                            .height = tex_res.height,
                            .format = tex_res.format,
                        }) catch break :blk_tex @as(i32, -1);
                        texture_index_map.put(tex_key, idx_i32) catch break :blk_tex @as(i32, -1);
                        break :blk_tex idx_i32;
                    };

                    var i: usize = 0;
                    while (i + 2 < indices.len) : (i += 3) {
                        const idx0 = indices[i];
                        const idx1 = indices[i + 1];
                        const idx2 = indices[i + 2];
                        if (idx0 >= vertices.len or idx1 >= vertices.len or idx2 >= vertices.len) continue;

                        triangle_list.append(self.allocator, .{
                            .v0 = transformPoint(item.model, vertices[idx0].position),
                            .v1 = transformPoint(item.model, vertices[idx1].position),
                            .v2 = transformPoint(item.model, vertices[idx2].position),
                            .n0 = transformNormal(item.model, vertices[idx0].normal),
                            .n1 = transformNormal(item.model, vertices[idx1].normal),
                            .n2 = transformNormal(item.model, vertices[idx2].normal),
                            .uv0 = vertices[idx0].uv,
                            .uv1 = vertices[idx1].uv,
                            .uv2 = vertices[idx2].uv,
                            .albedo = albedo,
                            .emissive = emissive,
                            .metallic = metallic,
                            .roughness = roughness,
                            .base_color_texture_index = tex_idx,
                        }) catch return false;
                    }
                }
            }

            if (triangle_list.items.len == 0) return false;

            mrt.triangles = self.allocator.dupe(rt_backend.RtTriangle, triangle_list.items) catch return false;
            mrt.accel_built = false;

            // 打包纹理图集
            if (texture_list.items.len > 0) {
                var total_size: usize = 0;
                for (texture_list.items) |tex| total_size += tex.pixels.len;
                const atlas = self.allocator.alloc(u8, total_size) catch return false;
                const meta = self.allocator.alloc(rt_backend.RtTextureMeta, texture_list.items.len) catch {
                    self.allocator.free(atlas);
                    return false;
                };
                var offset: u32 = 0;
                for (texture_list.items, 0..) |tex, ti| {
                    @memcpy(atlas[offset..][0..tex.pixels.len], tex.pixels);
                    meta[ti] = .{ .offset = offset, .width = tex.width, .height = tex.height };
                    offset += @intCast(tex.pixels.len);
                }
                mrt.texture_atlas = atlas;
                mrt.texture_meta = meta;
            }
            mrt.textures_uploaded = false;
        }

        // --- 构建加速结构 ---
        if (!mrt.accel_built) {
            if (!self.rhi.rtBuildAccelerationStructure(mrt.triangles.?)) return false;
            mrt.accel_built = true;
        }

        // --- 上传纹理图集到 GPU ---
        if (!mrt.textures_uploaded) {
            if (mrt.texture_atlas != null and mrt.texture_meta != null) {
                if (!self.rhi.rtUploadTextures(mrt.texture_atlas.?, mrt.texture_meta.?)) {
                    render_log.err("{s} texture upload failed for RT shadows", .{self.rhi.rtBackendName()});
                    return false;
                }
            } else {
                if (!self.rhi.rtUploadTextures(&.{}, &.{})) {
                    render_log.err("{s} empty texture upload failed for RT shadows", .{self.rhi.rtBackendName()});
                    return false;
                }
            }
            mrt.textures_uploaded = true;
        }

        // --- 分辨率缩放 ---
        const scale = std.math.clamp(self.editor_viewport_state.rt_shadow_resolution_scale, 0.25, 1.0);
        const trace_w: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(width)) * scale)));
        const trace_h: u32 = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(height)) * scale)));

        // --- 分配像素缓冲 (trace 尺寸) ---
        const trace_needed = @as(usize, trace_w) * trace_h * 4;
        if (self.rt_shadow_pixels == null or self.rt_shadow_width != trace_w or self.rt_shadow_height != trace_h) {
            if (self.rt_shadow_pixels) |p| self.allocator.free(p);
            self.rt_shadow_pixels = self.allocator.alloc(u8, trace_needed) catch return false;
            self.rt_shadow_width = trace_w;
            self.rt_shadow_height = trace_h;
        }

        // --- 光线追踪 (shadow only) ---
        const light_dir: [3]f32 = if (prepared_scene.lights.directional_lights.len > 0)
            vec3.normalize(vec3.scale(prepared_scene.lights.directional_lights[0].direction, -1.0))
        else
            vec3.normalize(.{ 0.38, 0.82, 0.42 });

        var params = rt_backend.RtParams{
            .inv_view_projection = mat4_mod.inverse(prepared_scene.view_projection) orelse mat4_mod.identity(),
            .camera_origin = .{
                prepared_scene.camera_world_position[0],
                prepared_scene.camera_world_position[1],
                prepared_scene.camera_world_position[2],
            },
            .light_direction = light_dir,
            .sun_angular_radius = self.editor_viewport_state.rt_shadow_softness,
            .width = trace_w,
            .height = trace_h,
            .samples = 1,
            .bounces = 1,
            .mode = 1, // shadow-only
            .shadow_samples = self.editor_viewport_state.rt_shadow_samples,
        };

        if (!self.rhi.rtTraceRays(&params, self.rt_shadow_pixels.?)) return false;

        // --- 上采样 (如果 trace 分辨率 < 输出分辨率) ---
        const upload_pixels: []u8 = if (trace_w == width and trace_h == height)
            self.rt_shadow_pixels.?
        else blk: {
            const full_size = @as(usize, width) * height * 4;
            const upscaled = self.allocator.alloc(u8, full_size) catch return false;
            // 双线性插值上采样
            const tw_f: f32 = @floatFromInt(trace_w);
            const th_f: f32 = @floatFromInt(trace_h);
            const src = self.rt_shadow_pixels.?;
            for (0..height) |y| {
                const sy = @as(f32, @floatFromInt(y)) * th_f / @as(f32, @floatFromInt(height));
                const y0: u32 = @intFromFloat(@floor(sy));
                const y1: u32 = @min(y0 + 1, trace_h - 1);
                const fy = sy - @floor(sy);
                for (0..width) |x| {
                    const sx = @as(f32, @floatFromInt(x)) * tw_f / @as(f32, @floatFromInt(width));
                    const x0: u32 = @intFromFloat(@floor(sx));
                    const x1: u32 = @min(x0 + 1, trace_w - 1);
                    const fx = sx - @floor(sx);
                    const dst_off = (y * width + x) * 4;
                    inline for (0..4) |ch| {
                        const c00: f32 = @floatFromInt(src[(@as(usize, y0) * trace_w + x0) * 4 + ch]);
                        const c10: f32 = @floatFromInt(src[(@as(usize, y0) * trace_w + x1) * 4 + ch]);
                        const c01: f32 = @floatFromInt(src[(@as(usize, y1) * trace_w + x0) * 4 + ch]);
                        const c11: f32 = @floatFromInt(src[(@as(usize, y1) * trace_w + x1) * 4 + ch]);
                        const top = c00 + (c10 - c00) * fx;
                        const bot = c01 + (c11 - c01) * fx;
                        upscaled[dst_off + ch] = @intFromFloat(std.math.clamp(top + (bot - top) * fy, 0, 255));
                    }
                }
            }
            break :blk upscaled;
        };
        defer if (trace_w != width or trace_h != height) self.allocator.free(upload_pixels);

        // --- 管理 GPU 纹理 ---
        if (self.rt_shadow_mask_texture == null or
            self.rt_shadow_mask_texture.?.desc.width != width or
            self.rt_shadow_mask_texture.?.desc.height != height)
        {
            if (self.rt_shadow_mask_texture) |*t| self.rhi.releaseTexture(t);
            self.rt_shadow_mask_texture = self.rhi.createTexture(.{
                .width = width,
                .height = height,
                .format = .bgra8_unorm,
                .usage = rhi_types.TextureUsage.sampler,
            }) catch return false;
        }

        self.rhi.uploadTextureData(&self.rt_shadow_mask_texture.?, upload_pixels, width, height) catch return false;
        return true;
    }

    // ==================================================================
    // Hardware RT — GPU 硬件加速路径追踪内部调度（自动集成在 PathTrace 模式中）
    // ==================================================================

    /// 尝试使用 GPU 硬件加速路径追踪。成功返回 true，不可用返回 false。
    fn tryRenderHwRtPath(
        self: *Renderer,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        scene: *scene_mod.Scene,
        target: anytype,
        width: u32,
        height: u32,
        trace_width: u32,
        trace_height: u32,
        samples: u32,
        bounces: u32,
        resolution_scale: f32,
    ) bool {
        if (sceneNeedsCpuPathTraceMaterialFallback(prepared_scene, scene)) {
            return false;
        }

        switch (self.rhi.ensureRtDevice()) {
            .unavailable => {
                if (!g_logged_path_trace_active) {
                    render_log.info("{s} not available, using CPU path trace", .{self.rhi.rtBackendName()});
                }
                return false;
            },
            .initialized, .ready => {
                if (!g_logged_path_trace_active) {
                    render_log.info("{s} backend initialized — GPU path trace active", .{self.rhi.rtBackendName()});
                    g_logged_path_trace_active = true;
                }
            },
        }
        var mrt = &self.hw_rt_state;
        const path_trace_environment = resolvePathTraceEnvironment(self, scene);
        const scene_signature = computePathTraceSceneSignature(prepared_scene, scene, path_trace_environment);

        // --- 变化检测 ---
        const vp_changed = !std.mem.eql(u8, std.mem.asBytes(&prepared_scene.view_projection), std.mem.asBytes(&mrt.last_view_projection));
        const size_changed = trace_width != mrt.trace_width or trace_height != mrt.trace_height or width != mrt.target_width or height != mrt.target_height;
        const params_changed = samples != mrt.last_samples or bounces != mrt.last_bounces or resolution_scale != mrt.last_resolution_scale;
        const scene_changed = scene_signature != mrt.last_scene_signature;

        // 相机/场景/参数变化检测
        const is_interactive_frame = vp_changed;

        // 相机/参数变化：重置累积计数（交互帧跳过昂贵的 memset）
        if (vp_changed or params_changed) {
            mrt.accum_frame_count = 0;
            if (!is_interactive_frame) {
                if (mrt.accum_pixels) |accum| @memset(accum, 0.0);
            }
            mrt.needs_retrace = true;
        }
        // 场景变化：完全重建
        if (scene_changed) {
            mrt.reset(self.allocator);
        }
        if (size_changed) {
            mrt.reset(self.allocator);
            if (mrt.trace_pixels) |p| self.allocator.free(p);
            if (mrt.display_pixels) |p| self.allocator.free(p);
            if (mrt.accum_pixels) |p| self.allocator.free(p);
            mrt.trace_pixels = null;
            mrt.display_pixels = null;
            mrt.accum_pixels = null;
        }

        mrt.last_view_projection = prepared_scene.view_projection;
        mrt.last_samples = samples;
        mrt.last_bounces = bounces;
        mrt.last_resolution_scale = resolution_scale;
        mrt.last_scene_signature = scene_signature;

        // --- 分配缓冲区 ---
        mrt.trace_pixels = mrt.trace_pixels orelse self.allocator.alloc(u8, @as(usize, trace_width) * trace_height * 8) catch return false;
        if (mrt.trace_width != trace_width or mrt.trace_height != trace_height) {
            @memset(mrt.trace_pixels.?, 0);
            mrt.trace_width = trace_width;
            mrt.trace_height = trace_height;
        }
        mrt.display_pixels = mrt.display_pixels orelse self.allocator.alloc(u8, @as(usize, width) * height * 8) catch return false;
        if (mrt.target_width != width or mrt.target_height != height) {
            @memset(mrt.display_pixels.?, 0);
            mrt.target_width = width;
            mrt.target_height = height;
        }
        // 累积缓冲区（float32 RGB，trace 分辨率）
        if (mrt.accum_pixels == null) {
            mrt.accum_pixels = self.allocator.alloc(f32, @as(usize, trace_width) * trace_height * 3) catch return false;
            @memset(mrt.accum_pixels.?, 0.0);
            mrt.accum_frame_count = 0;
        }

        // 渐进式累积完成 → 直接上传缓存
        if (mrt.accum_frame_count >= samples and mrt.accel_built) {
            self.rhi.uploadTextureData(target, mrt.display_pixels.?, width, height) catch return false;
            return true;
        }

        // --- 构建/重建三角形数据 ---
        if (mrt.triangles == null) {
            var triangle_list: std.ArrayListUnmanaged(rt_backend.RtTriangle) = .empty;
            defer triangle_list.deinit(self.allocator);

            var texture_list = std.ArrayList(struct { pixels: []const u8, width: u32, height: u32, format: rhi_types.TextureFormat }).empty;
            defer texture_list.deinit(self.allocator);
            var texture_index_map = std.AutoHashMap(u32, i32).init(self.allocator);
            defer texture_index_map.deinit();
            mrt.environment_texture_index = -1;

            const draw_batches = [_]struct {
                items: []const mesh_pass_mod.DrawItem,
                is_transparent: bool,
            }{
                .{ .items = prepared_scene.opaque_meshes, .is_transparent = false },
                .{ .items = prepared_scene.transparent_meshes, .is_transparent = true },
            };
            for (draw_batches) |batch| {
                for (batch.items) |item| {
                    const mesh_res = if (handles.isValid(item.mesh_handle))
                        scene.resources.mesh(item.mesh_handle)
                    else
                        null;
                    if (mesh_res) |mesh| {
                        const entity = scene.getEntityConst(item.entity_id);
                        const mat_comp = if (entity) |resolved_entity| resolved_entity.material else null;
                        const mat_res = blk_mat: {
                            const resolved_comp = mat_comp orelse break :blk_mat null;
                            const mat_handle = resolved_comp.handle orelse break :blk_mat null;
                            break :blk_mat scene.resources.material(mat_handle);
                        };

                        var shading: components.ShadingModel = if (mat_comp) |resolved_comp|
                            resolved_comp.shading
                        else
                            .pbr_metallic_roughness;
                        var alpha_cutoff = std.math.clamp(item.pbr_factors[2], 0.0, 1.0);
                        if (mat_res) |material| {
                            shading = material.shading;
                            alpha_cutoff = std.math.clamp(material.alpha_cutoff, 0.0, 1.0);
                        }

                        const opacity = std.math.clamp(item.base_color_factor[3] * item.pbr_factors[3], 0.0, 1.0);
                        if (batch.is_transparent and (opacity <= 0.001 or opacity < alpha_cutoff)) {
                            continue;
                        }

                        var albedo = [3]f32{
                            std.math.clamp(item.base_color_factor[0], 0.0, 1.0),
                            std.math.clamp(item.base_color_factor[1], 0.0, 1.0),
                            std.math.clamp(item.base_color_factor[2], 0.0, 1.0),
                        };
                        var emissive = [3]f32{
                            item.emissive_factor[0] * item.emissive_factor[3],
                            item.emissive_factor[1] * item.emissive_factor[3],
                            item.emissive_factor[2] * item.emissive_factor[3],
                        };
                        var metallic = std.math.clamp(item.pbr_factors[0], 0.0, 1.0);
                        var roughness = std.math.clamp(item.pbr_factors[1], 0.04, 1.0);
                        var transmission = std.math.clamp(1.0 - opacity, 0.0, 0.96);
                        var ior: f32 = 1.5;
                        var thickness: f32 = std.math.clamp((1.0 - opacity) * 0.75 + 0.05, 0.01, 2.0);

                        if (batch.is_transparent) {
                            albedo = vec3.scale(albedo, opacity);
                            roughness = std.math.clamp(roughness + (1.0 - opacity) * 0.35, 0.04, 1.0);
                        } else {
                            albedo = .{
                                std.math.clamp(albedo[0], 0.02, 1.0),
                                std.math.clamp(albedo[1], 0.02, 1.0),
                                std.math.clamp(albedo[2], 0.02, 1.0),
                            };
                        }

                        switch (shading) {
                            .unlit => {
                                emissive = vec3.add(emissive, vec3.scale(albedo, 1.2));
                                albedo = vec3.scale(albedo, 0.06);
                                metallic = 0.0;
                                roughness = 1.0;
                                transmission = 0.0;
                                thickness = 0.0;
                            },
                            .lambert => {
                                metallic = 0.0;
                                roughness = @max(roughness, 0.65);
                                ior = 1.45;
                                thickness = std.math.clamp(thickness * 0.5, 0.0, 1.0);
                            },
                            .pbr_metallic_roughness => {
                                ior = 1.52;
                            },
                        }

                        const texture_indices = resolvePathTraceTextureIndices(
                            self.allocator,
                            &texture_list,
                            &texture_index_map,
                            &scene.resources,
                            mat_res,
                            item.has_textures,
                        ) catch return false;

                        const indices = mesh.indices;
                        const vertices = mesh.vertices;
                        var i: usize = 0;
                        while (i + 2 < indices.len) : (i += 3) {
                            const idx0 = indices[i];
                            const idx1 = indices[i + 1];
                            const idx2 = indices[i + 2];
                            if (idx0 >= vertices.len or idx1 >= vertices.len or idx2 >= vertices.len) continue;

                            triangle_list.append(self.allocator, .{
                                .v0 = transformPoint(item.model, vertices[idx0].position),
                                .v1 = transformPoint(item.model, vertices[idx1].position),
                                .v2 = transformPoint(item.model, vertices[idx2].position),
                                .n0 = transformNormal(item.model, vertices[idx0].normal),
                                .n1 = transformNormal(item.model, vertices[idx1].normal),
                                .n2 = transformNormal(item.model, vertices[idx2].normal),
                                .uv0 = vertices[idx0].uv,
                                .uv1 = vertices[idx1].uv,
                                .uv2 = vertices[idx2].uv,
                                .albedo = albedo,
                                .emissive = emissive,
                                .metallic = metallic,
                                .roughness = roughness,
                                .transmission = transmission,
                                .ior = ior,
                                .thickness = thickness,
                                .base_color_texture_index = texture_indices.base_color,
                                .metallic_roughness_texture_index = texture_indices.metallic_roughness,
                                .normal_texture_index = texture_indices.normal,
                                .occlusion_texture_index = texture_indices.occlusion,
                                .emissive_texture_index = texture_indices.emissive,
                            }) catch return false;
                        }
                    }
                }
            }

            // 无网格时显示地面平面
            if (triangle_list.items.len == 0) {
                triangle_list.append(self.allocator, .{
                    .v0 = .{ -5.0, 0.0, -5.0 },
                    .v1 = .{ 5.0, 0.0, -5.0 },
                    .v2 = .{ 5.0, 0.0, 5.0 },
                    .n0 = .{ 0.0, 1.0, 0.0 },
                    .n1 = .{ 0.0, 1.0, 0.0 },
                    .n2 = .{ 0.0, 1.0, 0.0 },
                    .albedo = .{ 0.6, 0.6, 0.6 },
                    .emissive = .{ 0.0, 0.0, 0.0 },
                    .metallic = 0.0,
                    .roughness = 0.8,
                    .transmission = 0.0,
                    .ior = 1.5,
                    .thickness = 0.0,
                }) catch return false;
                triangle_list.append(self.allocator, .{
                    .v0 = .{ -5.0, 0.0, -5.0 },
                    .v1 = .{ 5.0, 0.0, 5.0 },
                    .v2 = .{ -5.0, 0.0, 5.0 },
                    .n0 = .{ 0.0, 1.0, 0.0 },
                    .n1 = .{ 0.0, 1.0, 0.0 },
                    .n2 = .{ 0.0, 1.0, 0.0 },
                    .albedo = .{ 0.6, 0.6, 0.6 },
                    .emissive = .{ 0.0, 0.0, 0.0 },
                    .metallic = 0.0,
                    .roughness = 0.8,
                    .transmission = 0.0,
                    .ior = 1.5,
                    .thickness = 0.0,
                }) catch return false;
            }

            if (path_trace_environment.texture) |environment_texture| {
                mrt.environment_texture_index = @intCast(texture_list.items.len);
                texture_list.append(self.allocator, .{
                    .pixels = environment_texture.pixels,
                    .width = environment_texture.width,
                    .height = environment_texture.height,
                    .format = environment_texture.format,
                }) catch return false;
            }

            mrt.triangles = self.allocator.dupe(rt_backend.RtTriangle, triangle_list.items) catch return false;
            const built_emissive_lights = buildHwRtEmissiveLights(self.allocator, triangle_list.items) catch return false;
            errdefer if (built_emissive_lights.items) |items| self.allocator.free(items);
            mrt.emissive_lights = built_emissive_lights.items;
            mrt.emissive_total_area = built_emissive_lights.total_area;

            const built_environment_importance = buildPathTraceEnvironmentImportance(self.allocator, path_trace_environment.texture) catch return false;
            errdefer if (built_environment_importance.items) |items| self.allocator.free(items);
            mrt.environment_importance = built_environment_importance.items;
            mrt.environment_importance_width = built_environment_importance.width;
            mrt.environment_importance_height = built_environment_importance.height;

            const built_sampling_tables = buildHwRtSamplingTables(
                self.allocator,
                mrt.environment_importance,
                mrt.emissive_lights,
            ) catch return false;
            errdefer if (built_sampling_tables.data) |data| self.allocator.free(data);
            errdefer if (built_sampling_tables.meta) |meta| self.allocator.free(meta);
            mrt.sampling_table_data = built_sampling_tables.data;
            mrt.sampling_table_meta = built_sampling_tables.meta;
            mrt.accel_built = false;

            // 打包纹理图集
            if (texture_list.items.len > 0) {
                var total_size: usize = 0;
                for (texture_list.items) |tex| total_size += tex.pixels.len;
                const atlas = self.allocator.alloc(u8, total_size) catch return false;
                const meta = self.allocator.alloc(rt_backend.RtTextureMeta, texture_list.items.len) catch {
                    self.allocator.free(atlas);
                    return false;
                };
                var offset: u32 = 0;
                for (texture_list.items, 0..) |tex, ti| {
                    @memcpy(atlas[offset..][0..tex.pixels.len], tex.pixels);
                    meta[ti] = .{
                        .offset = offset,
                        .width = tex.width,
                        .height = tex.height,
                        .format = @intFromEnum(tex.format),
                    };
                    offset += @intCast(tex.pixels.len);
                }
                mrt.texture_atlas = atlas;
                mrt.texture_meta = meta;
            }
            if (prepared_scene.lights.directional_lights.len > 0) {
                const light = prepared_scene.lights.directional_lights[0];
                mrt.light_radiance = vec3.scale(light.color, light.intensity);
            } else {
                mrt.light_radiance = .{ 0.0, 0.0, 0.0 };
            }
            mrt.textures_uploaded = false;
            mrt.sampling_tables_uploaded = false;
        }

        // --- 构建加速结构 ---
        if (!mrt.accel_built) {
            if (!self.rhi.rtBuildAccelerationStructure(mrt.triangles.?)) {
                render_log.err("{s} acceleration structure build failed", .{self.rhi.rtBackendName()});
                return false;
            }
            mrt.accel_built = true;
        }

        // --- 上传纹理图集到 GPU ---
        if (!mrt.textures_uploaded) {
            if (mrt.texture_atlas != null and mrt.texture_meta != null) {
                if (!self.rhi.rtUploadTextures(mrt.texture_atlas.?, mrt.texture_meta.?)) {
                    render_log.err("{s} texture atlas upload failed", .{self.rhi.rtBackendName()});
                    return false;
                }
            } else {
                if (!self.rhi.rtUploadTextures(&.{}, &.{})) {
                    render_log.err("{s} empty texture atlas upload failed", .{self.rhi.rtBackendName()});
                    return false;
                }
            }
            mrt.textures_uploaded = true;
        }

        if (!mrt.sampling_tables_uploaded) {
            if (mrt.sampling_table_data != null and mrt.sampling_table_meta != null) {
                if (!self.rhi.rtUploadSamplingTables(mrt.sampling_table_data.?, mrt.sampling_table_meta.?)) {
                    render_log.err("{s} sampling-table upload failed", .{self.rhi.rtBackendName()});
                    return false;
                }
            } else {
                if (!self.rhi.rtUploadSamplingTables(&.{}, &.{})) {
                    render_log.err("{s} empty sampling-table upload failed", .{self.rhi.rtBackendName()});
                    return false;
                }
            }
            mrt.sampling_tables_uploaded = true;
        }

        // --- 光线追踪（渐进式：每帧 1 spp） ---
        const light_dir: [3]f32 = if (prepared_scene.lights.directional_lights.len > 0)
            vec3.normalize(vec3.scale(prepared_scene.lights.directional_lights[0].direction, -1.0))
        else
            vec3.normalize(.{ 0.38, 0.82, 0.42 });

        var params = rt_backend.RtParams{
            .inv_view_projection = mat4_mod.inverse(prepared_scene.view_projection) orelse mat4_mod.identity(),
            .camera_origin = .{
                prepared_scene.camera_world_position[0],
                prepared_scene.camera_world_position[1],
                prepared_scene.camera_world_position[2],
            },
            .light_direction = light_dir,
            .width = trace_width,
            .height = trace_height,
            .samples = 1, // 渐进式：每帧 GPU 只追踪 1 个采样
            .bounces = bounces,
            .output_is_half = 1,
            .environment_texture_index = mrt.environment_texture_index,
            .sampling_table_count = if (mrt.sampling_table_meta) |meta| @intCast(meta.len) else 0,
            .environment_importance_width = mrt.environment_importance_width,
            .environment_importance_height = mrt.environment_importance_height,
            .emissive_total_area = mrt.emissive_total_area,
            .frame_index = mrt.accum_frame_count, // 渐进式：当前累积帧号作为随机种子
        };

        const directional_count = @min(prepared_scene.lights.directional_lights.len, rt_backend.max_directional_lights);
        params.directional_light_count = @intCast(directional_count);
        for (prepared_scene.lights.directional_lights[0..directional_count], 0..) |light, index| {
            params.directional_light_directions[index] = vec3.normalize(vec3.scale(light.direction, -1.0));
            params.directional_light_radiance[index] = vec3.scale(light.color, light.intensity);
        }

        const point_count = @min(prepared_scene.lights.point_lights.len, rt_backend.max_point_lights);
        params.point_light_count = @intCast(point_count);
        for (prepared_scene.lights.point_lights[0..point_count], 0..) |light, index| {
            params.point_light_positions[index] = light.position;
            params.point_light_radiance[index] = vec3.scale(light.color, light.intensity);
            params.point_light_ranges[index] = light.range;
        }

        const spot_count = @min(prepared_scene.lights.spot_lights.len, rt_backend.max_spot_lights);
        params.spot_light_count = @intCast(spot_count);
        for (prepared_scene.lights.spot_lights[0..spot_count], 0..) |light, index| {
            params.spot_light_positions[index] = light.position;
            params.spot_light_directions[index] = vec3.normalize(light.direction);
            params.spot_light_radiance[index] = vec3.scale(light.color, light.intensity);
            params.spot_light_ranges[index] = light.range;
            params.spot_light_inner_angle_cos[index] = light.inner_angle_cos;
            params.spot_light_outer_angle_cos[index] = light.outer_angle_cos;
        }

        const display_pixels = mrt.display_pixels.?;

        const trace_pixels = mrt.trace_pixels.?;

        if (is_interactive_frame) {
            // 交互帧：异步 GPU 调度，显示上一帧结果，不阻塞 CPU
            // 1. 检查上一次异步 trace 是否完成 → 取回结果并上采样
            if (self.rhi.rtIsTraceComplete()) {
                if (self.rhi.rtGetTraceResult(trace_pixels)) {
                    const trace_half: [*]const f16 = @ptrCast(@alignCast(trace_pixels.ptr));
                    const display_half: [*]f16 = @ptrCast(@alignCast(display_pixels.ptr));
                    var out_y: u32 = 0;
                    while (out_y < height) : (out_y += 1) {
                        const src_y: u32 = @min(trace_height - 1, @as(u32, @intCast((@as(u64, out_y) * @as(u64, trace_height)) / @as(u64, height))));
                        var out_x: u32 = 0;
                        while (out_x < width) : (out_x += 1) {
                            const src_x: u32 = @min(trace_width - 1, @as(u32, @intCast((@as(u64, out_x) * @as(u64, trace_width)) / @as(u64, width))));
                            const src_base: usize = (@as(usize, src_y) * @as(usize, trace_width) + @as(usize, src_x)) * 4;
                            const dst_base: usize = (@as(usize, out_y) * @as(usize, width) + @as(usize, out_x)) * 4;
                            display_half[dst_base + 0] = trace_half[src_base + 0];
                            display_half[dst_base + 1] = trace_half[src_base + 1];
                            display_half[dst_base + 2] = trace_half[src_base + 2];
                            display_half[dst_base + 3] = @as(f16, 1.0);
                        }
                    }
                }
            }
            // else: display_pixels 保留上一帧的有效画面（收敛帧或上一次 async 结果）

            // 2. 发射新的异步 trace（不等待 GPU）
            _ = self.rhi.rtTraceRaysAsync(&params);
            mrt.accum_frame_count = 0;
        } else {
            // 静态帧：同步 trace + 渐进式 f32 累积
            if (!self.rhi.rtTraceRays(&params, trace_pixels)) {
                render_log.err("{s} trace failed", .{self.rhi.rtBackendName()});
                return false;
            }

            const accum = mrt.accum_pixels.?;
            const pixel_count = @as(usize, trace_width) * @as(usize, trace_height);
            if (mrt.accum_frame_count == 0) {
                @memset(accum, 0.0);
            }
            const trace_half: [*]const f16 = @ptrCast(@alignCast(trace_pixels.ptr));
            for (0..pixel_count) |i| {
                const src_base = i * 4;
                const dst_base = i * 3;
                accum[dst_base + 0] += @floatCast(trace_half[src_base + 0]);
                accum[dst_base + 1] += @floatCast(trace_half[src_base + 1]);
                accum[dst_base + 2] += @floatCast(trace_half[src_base + 2]);
            }
            mrt.accum_frame_count += 1;

            const inv_count: f32 = 1.0 / @as(f32, @floatFromInt(mrt.accum_frame_count));
            const display_half: [*]f16 = @ptrCast(@alignCast(display_pixels.ptr));
            var out_y: u32 = 0;
            while (out_y < height) : (out_y += 1) {
                const src_y: u32 = @min(trace_height - 1, @as(u32, @intCast((@as(u64, out_y) * @as(u64, trace_height)) / @as(u64, height))));
                var out_x: u32 = 0;
                while (out_x < width) : (out_x += 1) {
                    const src_x: u32 = @min(trace_width - 1, @as(u32, @intCast((@as(u64, out_x) * @as(u64, trace_width)) / @as(u64, width))));
                    const src_base: usize = (@as(usize, src_y) * @as(usize, trace_width) + @as(usize, src_x)) * 3;
                    const dst_base_px: usize = (@as(usize, out_y) * @as(usize, width) + @as(usize, out_x)) * 4;
                    display_half[dst_base_px + 0] = @floatCast(accum[src_base + 0] * inv_count);
                    display_half[dst_base_px + 1] = @floatCast(accum[src_base + 1] * inv_count);
                    display_half[dst_base_px + 2] = @floatCast(accum[src_base + 2] * inv_count);
                    display_half[dst_base_px + 3] = @as(f16, 1.0);
                }
            }
        }

        self.rhi.uploadTextureData(target, display_pixels, width, height) catch return false;

        return true;
    }

    /// Downloads the final rendered frame from GPU to CPU as RGBA8 pixels.
    ///
    /// Parameters:
    /// - `allocator`: Allocator for returned pixel buffer. Caller owns and must free the slice.
    ///
    /// Returns: []u8 pixel data in RGBA8 format (4 bytes per pixel), row-major layout.
    /// Slice length = (width * height * 4) bytes. Caller must call allocator.free(result).
    ///
    /// Errors:
    /// - error.TextureNotFound: No offscreen render target (viewport not yet rendered).
    /// - error.CommandBufferAcquireFailed: GPU submission failed (GPU device lost?).
    /// - error.OutOfMemory: Allocation failed.
    ///
    /// Performance: Blocks CPU waiting for GPU readback. Do NOT call every frame in tight loops.
    /// Typical use: Screenshot export, video recording (async), debugging visualization.
    /// GPU-CPU sync point: GPU must complete rendering before transfer buffer becomes visible.
    ///
    /// Thread-safety: NOT thread-safe. Must be called from render thread.
    pub fn downloadFinalFrameAlloc(self: *Renderer, allocator: std.mem.Allocator) ![]u8 {
        return renderer_export.downloadFinalFrameAlloc(&self.rhi, self.scene_viewport.color_texture, allocator);
    }

    /// Download final frame pixels as raw BGRA byte data from the LDR color texture.
    /// Returns allocated byte slice (caller owns memory).
    pub fn downloadFramePixelsAlloc(self: *Renderer, allocator: std.mem.Allocator) !FramePixels {
        return renderer_export.downloadFramePixelsAlloc(&self.rhi, self.scene_viewport.color_texture, allocator);
    }

    fn copyHalfTracePixelsToRgbAlloc(
        alloc2: std.mem.Allocator,
        pixels: []const u8,
        width: u32,
        height: u32,
    ) ![]f32 {
        return renderer_export.copyHalfTracePixelsToRgbAlloc(alloc2, pixels, width, height);
    }

    pub fn downloadHdrFramePixelsAlloc(self: *Renderer, allocator: std.mem.Allocator) !HdrFramePixels {
        return renderer_export.downloadHdrFramePixelsAlloc(&self.rhi, self.scene_viewport.hdr_color_texture, allocator);
    }

    pub fn downloadHdrFrameExrAlloc(self: *Renderer, allocator: std.mem.Allocator) ![]u8 {
        return renderer_export.downloadHdrFrameExrAlloc(&self.rhi, self.scene_viewport.hdr_color_texture, allocator);
    }

    pub fn exportFramePng(self: *Renderer, allocator: std.mem.Allocator, out_path: []const u8) !void {
        return renderer_export.exportFramePng(&self.rhi, self.scene_viewport.color_texture, allocator, out_path);
    }

    pub fn exportFrameExr(self: *Renderer, allocator: std.mem.Allocator, out_path: []const u8) !void {
        return renderer_export.exportFrameExr(&self.rhi, self.scene_viewport.hdr_color_texture, allocator, out_path);
    }

    pub const FramePixels = renderer_export.FramePixels;
    pub const HdrFramePixels = renderer_export.HdrFramePixels;
    pub const PathTracePngExportOptions = renderer_export.PathTracePngExportOptions;
    pub const PathTraceExrExportOptions = renderer_export.PathTraceExrExportOptions;

    fn exportableHwRtTraceBeauty(self: *Renderer, viewport_size: [2]u32) ?struct {
        pixels: []const u8,
        width: u32,
        height: u32,
    } {
        const mrt = &self.hw_rt_state;
        // 渐进式：至少有 1 帧累积才可导出
        if (mrt.accum_frame_count == 0 or mrt.trace_pixels == null) return null;
        if (mrt.trace_width != viewport_size[0] or mrt.trace_height != viewport_size[1]) return null;
        return .{
            .pixels = mrt.trace_pixels.?,
            .width = mrt.trace_width,
            .height = mrt.trace_height,
        };
    }

    /// Export path-traced PNG with optional albedo/normal sidecars and AOV-guided denoise.
    pub fn exportPathTraceFramePng(
        self: *Renderer,
        allocator: std.mem.Allocator,
        scene: *scene_mod.Scene,
        out_path: []const u8,
        options: PathTracePngExportOptions,
    ) !void {
        const viewport_size = self.sceneViewportSize();
        if (viewport_size[0] == 0 or viewport_size[1] == 0) return error.InvalidDimensions;

        const samples = std.math.clamp(self.editor_viewport_state.path_trace_samples, 1, 4096);
        const bounces = std.math.clamp(self.editor_viewport_state.path_trace_bounces, 1, 12);

        var beauty_rgb: []f32 = undefined;
        defer allocator.free(beauty_rgb);

        var guides: ?PathTraceGuideBuffers = null;
        defer if (guides) |*value| value.deinit(allocator);

        const use_existing_cpu_path = self.path_trace_state.triangles != null and
            self.path_trace_state.trace_width == viewport_size[0] and
            self.path_trace_state.trace_height == viewport_size[1];

        if (use_existing_cpu_path) {
            var pt = &self.path_trace_state;
            pt.cached_samples = samples;
            pt.cached_bounces = bounces;
            if (pt.sample_step == 0) {
                pt.sample_step = computePathTraceSampleStep(pt.trace_width, pt.trace_height);
            }
            if (!pt.complete) {
                renderer_path_trace.renderCpuPathTraceTiles(pt, false, 0);
                renderer_path_trace.resolvePathTraceDisplayPixels(pt);
            }
            beauty_rgb = try allocator.dupe(f32, pt.trace_linear_rgb.?);
            if (options.denoise or options.write_aov_sidecars) {
                guides = try path_trace_denoise.captureGuideBuffersAlloc(allocator, pt, samplePathTraceGuidePixel);
            }
        } else if (self.exportableHwRtTraceBeauty(viewport_size)) |hw_trace| {
            beauty_rgb = try copyHalfTracePixelsToRgbAlloc(allocator, hw_trace.pixels, hw_trace.width, hw_trace.height);

            if (options.denoise or options.write_aov_sidecars) {
                var guide_pt = try self.buildOfflinePathTraceExportState(
                    scene,
                    hw_trace.width,
                    hw_trace.height,
                    samples,
                    bounces,
                    false,
                );
                defer guide_pt.deinit(self.allocator);
                guides = try path_trace_denoise.captureGuideBuffersAlloc(allocator, &guide_pt, samplePathTraceGuidePixel);
            }
        } else {
            const hdr = try self.downloadHdrFramePixelsAlloc(allocator);
            defer allocator.free(hdr.data);
            beauty_rgb = try image_export.copyHdrRgbaToRgbAlloc(allocator, hdr.data, hdr.width, hdr.height);

            if (options.denoise or options.write_aov_sidecars) {
                var guide_pt = try self.buildOfflinePathTraceExportState(
                    scene,
                    hdr.width,
                    hdr.height,
                    samples,
                    bounces,
                    false,
                );
                defer guide_pt.deinit(self.allocator);
                guides = try path_trace_denoise.captureGuideBuffersAlloc(allocator, &guide_pt, samplePathTraceGuidePixel);
            }
        }

        var final_beauty = beauty_rgb;
        var denoised_rgb: ?[]f32 = null;
        defer if (denoised_rgb) |rgb| allocator.free(rgb);
        if (options.denoise) {
            const guide_buffers = guides orelse return error.PathTraceGuidesUnavailable;
            const denoise_result = try path_trace_denoise.denoiseAlloc(allocator, beauty_rgb, guide_buffers.width, guide_buffers.height, guide_buffers);
            denoised_rgb = denoise_result.rgb;
            final_beauty = denoise_result.rgb;
            if (denoise_result.fallback_used) {
                render_log.warn("path trace export denoise requested backend fell back to {s}", .{path_trace_denoise.backendLabel(denoise_result.backend)});
            } else {
                render_log.info("path trace export denoise backend: {s}", .{path_trace_denoise.backendLabel(denoise_result.backend)});
            }
        }

        const output_width = if (guides) |value| value.width else viewport_size[0];
        const output_height = if (guides) |value| value.height else viewport_size[1];
        const beauty_rgba = try image_export.tonemapHdrToRgba8Alloc(allocator, final_beauty, output_width, output_height, self.editor_viewport_state);
        defer allocator.free(beauty_rgba);
        const beauty_png = try image_export.encodePngAlloc(allocator, beauty_rgba, output_width, output_height);
        defer allocator.free(beauty_png);
        try image_export.writeFileEnsuringParent(out_path, beauty_png);

        if (options.write_aov_sidecars) {
            const guide_buffers = guides orelse return error.PathTraceGuidesUnavailable;
            const albedo_rgba = try image_export.encodeGuideToRgba8Alloc(allocator, guide_buffers.albedo, guide_buffers.width, guide_buffers.height, false);
            defer allocator.free(albedo_rgba);
            const albedo_png = try image_export.encodePngAlloc(allocator, albedo_rgba, guide_buffers.width, guide_buffers.height);
            defer allocator.free(albedo_png);
            const albedo_path = try image_export.allocSidecarPath(allocator, out_path, "_albedo");
            defer allocator.free(albedo_path);
            try image_export.writeFileEnsuringParent(albedo_path, albedo_png);

            const normal_rgba = try image_export.encodeGuideToRgba8Alloc(allocator, guide_buffers.normal, guide_buffers.width, guide_buffers.height, true);
            defer allocator.free(normal_rgba);
            const normal_png = try image_export.encodePngAlloc(allocator, normal_rgba, guide_buffers.width, guide_buffers.height);
            defer allocator.free(normal_png);
            const normal_path = try image_export.allocSidecarPath(allocator, out_path, "_normal");
            defer allocator.free(normal_path);
            try image_export.writeFileEnsuringParent(normal_path, normal_png);
        }
    }

    /// Export path-traced linear beauty to OpenEXR with optional denoise and AOV layers.
    pub fn exportPathTraceFrameExr(
        self: *Renderer,
        allocator: std.mem.Allocator,
        scene: *scene_mod.Scene,
        out_path: []const u8,
        options: PathTraceExrExportOptions,
    ) !void {
        const viewport_size = self.sceneViewportSize();
        if (viewport_size[0] == 0 or viewport_size[1] == 0) return error.InvalidDimensions;

        const samples = std.math.clamp(self.editor_viewport_state.path_trace_samples, 1, 4096);
        const bounces = std.math.clamp(self.editor_viewport_state.path_trace_bounces, 1, 12);

        var beauty_rgb: []f32 = undefined;
        defer allocator.free(beauty_rgb);

        var guides: ?PathTraceGuideBuffers = null;
        defer if (guides) |*value| value.deinit(allocator);

        var beauty_width = viewport_size[0];
        var beauty_height = viewport_size[1];

        const need_guides = options.denoise or options.write_aov_layers;

        const use_existing_cpu_path = self.path_trace_state.triangles != null and
            self.path_trace_state.trace_width == viewport_size[0] and
            self.path_trace_state.trace_height == viewport_size[1];

        if (use_existing_cpu_path) {
            var pt = &self.path_trace_state;
            pt.cached_samples = samples;
            pt.cached_bounces = bounces;
            if (pt.sample_step == 0) {
                pt.sample_step = computePathTraceSampleStep(pt.trace_width, pt.trace_height);
            }
            if (!pt.complete) {
                renderer_path_trace.renderCpuPathTraceTiles(pt, false, 0);
                renderer_path_trace.resolvePathTraceDisplayPixels(pt);
            }
            beauty_rgb = try allocator.dupe(f32, pt.trace_linear_rgb.?);
            beauty_width = pt.trace_width;
            beauty_height = pt.trace_height;
            if (need_guides) {
                guides = try path_trace_denoise.captureGuideBuffersAlloc(allocator, pt, samplePathTraceGuidePixel);
            }
        } else if (self.exportableHwRtTraceBeauty(viewport_size)) |hw_trace| {
            beauty_rgb = try copyHalfTracePixelsToRgbAlloc(allocator, hw_trace.pixels, hw_trace.width, hw_trace.height);
            beauty_width = hw_trace.width;
            beauty_height = hw_trace.height;
            if (need_guides) {
                var guide_pt = try self.buildOfflinePathTraceExportState(
                    scene,
                    hw_trace.width,
                    hw_trace.height,
                    samples,
                    bounces,
                    false,
                );
                defer guide_pt.deinit(self.allocator);
                guides = try path_trace_denoise.captureGuideBuffersAlloc(allocator, &guide_pt, samplePathTraceGuidePixel);
            }
        } else {
            const hdr = try self.downloadHdrFramePixelsAlloc(allocator);
            defer allocator.free(hdr.data);
            beauty_rgb = try image_export.copyHdrRgbaToRgbAlloc(allocator, hdr.data, hdr.width, hdr.height);
            beauty_width = hdr.width;
            beauty_height = hdr.height;
            if (need_guides) {
                var guide_pt = try self.buildOfflinePathTraceExportState(
                    scene,
                    hdr.width,
                    hdr.height,
                    samples,
                    bounces,
                    false,
                );
                defer guide_pt.deinit(self.allocator);
                guides = try path_trace_denoise.captureGuideBuffersAlloc(allocator, &guide_pt, samplePathTraceGuidePixel);
            }
        }

        // Optional denoise
        var final_beauty = beauty_rgb;
        var denoised_rgb: ?[]f32 = null;
        defer if (denoised_rgb) |rgb| allocator.free(rgb);
        if (options.denoise) {
            const guide_buffers = guides orelse return error.PathTraceGuidesUnavailable;
            const denoise_result = try path_trace_denoise.denoiseAlloc(allocator, beauty_rgb, guide_buffers.width, guide_buffers.height, guide_buffers);
            denoised_rgb = denoise_result.rgb;
            final_beauty = denoise_result.rgb;
            if (denoise_result.fallback_used) {
                render_log.warn("path trace EXR export denoise fell back to {s}", .{path_trace_denoise.backendLabel(denoise_result.backend)});
            }
        }

        const beauty_rgba = try image_export.copyHdrRgbToRgbaAlloc(allocator, final_beauty, beauty_width, beauty_height);
        defer allocator.free(beauty_rgba);

        // Build AOV struct for multi-layer encoding
        var aov = image_export.ExrAovLayers{};
        if (options.write_aov_layers) {
            if (guides) |g| {
                aov.albedo = g.albedo;
                aov.normal = g.normal;
            }
        }

        const exr = try image_export.encodeExrMultiLayerAlloc(allocator, beauty_rgba, beauty_width, beauty_height, aov);
        defer allocator.free(exr);
        try image_export.writeFileEnsuringParent(out_path, exr);
    }

    fn buildSceneSnapshot(scene: *const scene_mod.Scene) types.SceneSnapshot {
        const summary = scene.summary();
        return .{
            .entity_count = summary.entity_count,
            .camera_count = summary.camera_count,
            .mesh_count = summary.mesh_count,
            .material_count = summary.material_count,
            .light_count = summary.light_count,
        };
    }

    fn clearAndDepthForScene(snapshot: types.SceneSnapshot, pass_count: usize) rhi_types.ClearState {
        const mesh_bias = @as(f32, @floatFromInt(@min(snapshot.mesh_count, 12))) * 0.01;
        const light_bias = @as(f32, @floatFromInt(@min(snapshot.light_count, 4))) * 0.02;
        const pass_bias = @as(f32, @floatFromInt(@min(pass_count, 8))) * 0.005;

        return .{
            .color = .{
                0.05 + mesh_bias,
                0.06 + light_bias,
                0.1 + pass_bias,
                1.0,
            },
            .depth = 1.0,
        };
    }

    pub fn processMaterialThumbnailRequests(
        self: *Renderer,
        frame: rhi_mod.Frame,
        scene: *const scene_mod.Scene,
    ) !mesh_pass_mod.DrawStats {
        return renderer_thumbnails.processMaterialThumbnailRequests(self, frame, scene);
    }

    pub fn processModelThumbnailRequests(
        self: *Renderer,
        frame: rhi_mod.Frame,
    ) !mesh_pass_mod.DrawStats {
        return renderer_thumbnails.processModelThumbnailRequests(self, frame);
    }

    pub fn processMaterialEditorPreview(self: *Renderer, frame: rhi_mod.Frame) !mesh_pass_mod.DrawStats {
        defer self.material_editor_preview_requested = false;

        if (!self.material_editor_preview_requested or !self.material_editor_preview_dirty) {
            return .{};
        }
        if (!self.depth_prepass.isReady() or !self.base_pass.isReady()) {
            return .{};
        }

        const stats = try renderer_thumbnails.renderMaterialPreviewTarget(self, frame, &self.material_editor_preview_target);
        self.material_editor_preview_dirty = false;
        self.material_editor_preview_ready = true;
        return stats;
    }

    pub fn findMaterialThumbnailCacheIndex(self: *const Renderer, asset_id: []const u8) ?*MaterialThumbnailCacheEntry {
        return renderer_thumbnails.findMaterialThumbnailCacheIndex(self, asset_id);
    }

    pub fn ensureMaterialThumbnailEntry(self: *Renderer, asset_id: []const u8) !*MaterialThumbnailCacheEntry {
        return renderer_thumbnails.ensureMaterialThumbnailEntry(self, asset_id);
    }

    pub fn enqueueMaterialThumbnailRequest(self: *Renderer, entry: *MaterialThumbnailCacheEntry) !void {
        return renderer_thumbnails.enqueueMaterialThumbnailRequest(self, entry);
    }

    pub fn evictMaterialThumbnailEntry(self: *Renderer, keep_asset_id: []const u8) void {
        return renderer_thumbnails.evictMaterialThumbnailEntry(self, keep_asset_id);
    }

    pub fn removeMaterialThumbnail(self: *Renderer, asset_id: []const u8) void {
        return renderer_thumbnails.removeMaterialThumbnail(self, asset_id);
    }

    pub fn releaseMaterialThumbnailCache(self: *Renderer) void {
        return renderer_thumbnails.releaseMaterialThumbnailCache(self);
    }

    pub fn releaseMaterialThumbnailRequests(self: *Renderer) void {
        return renderer_thumbnails.releaseMaterialThumbnailRequests(self);
    }

    pub fn releaseModelThumbnailCache(self: *Renderer) void {
        return renderer_thumbnails.releaseModelThumbnailCache(self);
    }

    pub fn releaseModelThumbnailRequests(self: *Renderer) void {
        return renderer_thumbnails.releaseModelThumbnailRequests(self);
    }

    fn durationNs(start: i128, end: i128) u64 {
        return if (end > start) @intCast(end - start) else 0;
    }

    fn gizmoPassRequired(self: *const Renderer, _: *const scene_mod.Scene) bool {
        if (!self.gizmo_pass.isReady()) {
            return false;
        }
        // Player mode: skip all editor debug overlays
        if (!self.is_editor_mode) return false;
        return self.selection_history.primarySelection() != null or
            self.editor_gizmo_transform_override != null or
            self.preview_gizmo_transform != null or
            self.editor_viewport_state.show_grid or
            self.editor_viewport_state.show_bones or
            self.editor_viewport_state.show_collision or
            self.camera_path_preview_lines.items.len >= 2;
    }

    fn drawViewportDebugOverlays(
        self: *Renderer,
        frame: rhi_mod.Frame,
        pass: rhi_mod.RenderPass,
        scene: *scene_mod.Scene,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        physics_state_opt: ?*physics_mod.PhysicsState,
    ) !mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};

        if (self.editor_viewport_state.show_grid) {
            var grid_lines = std.ArrayList(gizmo_pass_mod.WorldLineVertex).empty;
            defer grid_lines.deinit(self.allocator);
            try renderer_debug.appendGridLines(self.allocator, &grid_lines, prepared_scene.camera_world_position);
            const grid_stats = try self.gizmo_pass.drawWorldLines(
                &self.rhi,
                frame,
                pass,
                prepared_scene.view_projection,
                grid_lines.items,
                .{ 0.12, 0.14, 0.18, 0.7 },
            );
            stats.add(grid_stats);
        }

        if (self.editor_viewport_state.show_bones) {
            var bone_lines = std.ArrayList(gizmo_pass_mod.WorldLineVertex).empty;
            defer bone_lines.deinit(self.allocator);
            try renderer_debug.appendBoneLines(self.allocator, scene, &bone_lines);
            const bone_stats = try self.gizmo_pass.drawWorldLines(
                &self.rhi,
                frame,
                pass,
                prepared_scene.view_projection,
                bone_lines.items,
                .{ 0.95, 0.58, 0.24, 1.0 },
            );
            stats.add(bone_stats);
        }

        if (self.editor_viewport_state.show_collision) {
            var solid_lines = std.ArrayList(gizmo_pass_mod.WorldLineVertex).empty;
            defer solid_lines.deinit(self.allocator);
            var trigger_lines = std.ArrayList(gizmo_pass_mod.WorldLineVertex).empty;
            defer trigger_lines.deinit(self.allocator);

            try renderer_debug.appendCollisionLines(self.allocator, scene, prepared_scene, &solid_lines, &trigger_lines, physics_state_opt);

            var collision_stats = mesh_pass_mod.DrawStats{};
            if (solid_lines.items.len > 0) {
                const solid_stats = try self.gizmo_pass.drawWorldLines(
                    &self.rhi,
                    frame,
                    pass,
                    prepared_scene.view_projection,
                    solid_lines.items,
                    .{ 0.30, 0.92, 0.52, 1.0 },
                );
                collision_stats.add(solid_stats);
            }
            if (trigger_lines.items.len > 0) {
                const trigger_stats = try self.gizmo_pass.drawWorldLines(
                    &self.rhi,
                    frame,
                    pass,
                    prepared_scene.view_projection,
                    trigger_lines.items,
                    .{ 0.92, 0.70, 0.30, 1.0 },
                );
                collision_stats.add(trigger_stats);
            }
            stats.add(collision_stats);
        }

        // Camera path spline preview (set by Sequencer panel)
        if (self.camera_path_preview_lines.items.len >= 2) {
            const path_stats = try self.gizmo_pass.drawWorldLines(
                &self.rhi,
                frame,
                pass,
                prepared_scene.view_projection,
                self.camera_path_preview_lines.items,
                .{ 1.0, 0.8, 0.2, 1.0 },
            );
            stats.add(path_stats);
        }

        // Mesh edit overlay — three layers matching the old ImGui visual style:
        //   wire = muted grey (vertex-mode wireframe background, depth-tested)
        //   vtx  = teal/cyan (unselected elements, always on top)
        //   sel  = gold/yellow (selected elements, always on top)
        if (self.mesh_edit_wireframe_lines.items.len >= 2) {
            const wire_stats = try self.gizmo_pass.drawWorldLines(
                &self.rhi,
                frame,
                pass,
                prepared_scene.view_projection,
                self.mesh_edit_wireframe_lines.items,
                .{ 0.60, 0.68, 0.78, 0.55 }, // muted blue-grey wireframe
            );
            stats.add(wire_stats);
        }
        if (self.mesh_edit_vertex_lines.items.len >= 2) {
            const vtx_stats = try self.gizmo_pass.drawThickOverlayLines(
                &self.rhi,
                frame,
                pass,
                prepared_scene.view_projection,
                self.mesh_edit_vertex_lines.items,
                .{ prepared_scene.camera_world_position[0], prepared_scene.camera_world_position[1], prepared_scene.camera_world_position[2] },
                prepared_scene.projection_matrix[5],
                @floatFromInt(self.scene_viewport.height),
                4.0,
                false, // no cap extension — teal ends exactly at junction so gold caps cover cleanly
                self.allocator,
                .{ 0.30, 0.72, 0.65, 0.78 }, // teal — unselected elements (always on top)
            );
            stats.add(vtx_stats);
        }
        if (self.mesh_edit_selected_lines.items.len >= 2) {
            const sel_stats = try self.gizmo_pass.drawThickOverlayLines(
                &self.rhi,
                frame,
                pass,
                prepared_scene.view_projection,
                self.mesh_edit_selected_lines.items,
                .{ prepared_scene.camera_world_position[0], prepared_scene.camera_world_position[1], prepared_scene.camera_world_position[2] },
                prepared_scene.projection_matrix[5],
                @floatFromInt(self.scene_viewport.height),
                8.0,
                true, // cap extension: gold extends past junction, covering teal endpoint area
                self.allocator,
                .{ 1.00, 0.86, 0.20, 1.00 }, // bright gold — selected elements (always on top)
            );
            stats.add(sel_stats);
        }
        // Unselected vertex / face-centroid dots (teal squares)
        if (self.mesh_edit_vtx_dot_positions.items.len > 0) {
            const dot_stats = try self.gizmo_pass.drawVertexDots(
                &self.rhi,
                frame,
                pass,
                prepared_scene.view_projection,
                self.mesh_edit_vtx_dot_positions.items,
                .{ prepared_scene.camera_world_position[0], prepared_scene.camera_world_position[1], prepared_scene.camera_world_position[2] },
                prepared_scene.projection_matrix[5],
                @floatFromInt(self.scene_viewport.height),
                7.0,
                self.allocator,
                .{ 0.38, 0.88, 0.80, 0.90 }, // teal dot
            );
            stats.add(dot_stats);
        }
        // Selected vertex / face-centroid dots (gold squares, drawn after teal)
        if (self.mesh_edit_sel_dot_positions.items.len > 0) {
            const dot_stats = try self.gizmo_pass.drawVertexDots(
                &self.rhi,
                frame,
                pass,
                prepared_scene.view_projection,
                self.mesh_edit_sel_dot_positions.items,
                .{ prepared_scene.camera_world_position[0], prepared_scene.camera_world_position[1], prepared_scene.camera_world_position[2] },
                prepared_scene.projection_matrix[5],
                @floatFromInt(self.scene_viewport.height),
                10.0,
                self.allocator,
                .{ 1.00, 0.86, 0.20, 1.00 }, // gold dot
            );
            stats.add(dot_stats);
        }

        // ── Entity icons (camera + lights) ───────────────────────────
        {
            // Camera icons (blue)
            var camera_lines = std.ArrayList(gizmo_pass_mod.WorldLineVertex).empty;
            defer camera_lines.deinit(self.allocator);
            try renderer_debug.appendCameraIconLines(self.allocator, scene, &camera_lines);
            if (camera_lines.items.len > 0) {
                const cam_stats = try self.gizmo_pass.drawOverlayLines(
                    &self.rhi,
                    frame,
                    pass,
                    prepared_scene.view_projection,
                    camera_lines.items,
                    .{ 0.30, 0.70, 1.00, 1.00 },
                );
                stats.add(cam_stats);
            }

            // Light icons (per type with different colors)
            var dir_lines = std.ArrayList(gizmo_pass_mod.WorldLineVertex).empty;
            defer dir_lines.deinit(self.allocator);
            var point_lines = std.ArrayList(gizmo_pass_mod.WorldLineVertex).empty;
            defer point_lines.deinit(self.allocator);
            var spot_lines = std.ArrayList(gizmo_pass_mod.WorldLineVertex).empty;
            defer spot_lines.deinit(self.allocator);
            try renderer_debug.appendLightIconLines(self.allocator, scene, &dir_lines, &point_lines, &spot_lines);
            if (dir_lines.items.len > 0) {
                const dir_stats = try self.gizmo_pass.drawOverlayLines(
                    &self.rhi,
                    frame,
                    pass,
                    prepared_scene.view_projection,
                    dir_lines.items,
                    .{ 1.00, 0.80, 0.30, 1.00 }, // orange — directional
                );
                stats.add(dir_stats);
            }
            if (point_lines.items.len > 0) {
                const pt_stats = try self.gizmo_pass.drawOverlayLines(
                    &self.rhi,
                    frame,
                    pass,
                    prepared_scene.view_projection,
                    point_lines.items,
                    .{ 1.00, 1.00, 0.50, 1.00 }, // yellow — point
                );
                stats.add(pt_stats);
            }
            if (spot_lines.items.len > 0) {
                const sp_stats = try self.gizmo_pass.drawOverlayLines(
                    &self.rhi,
                    frame,
                    pass,
                    prepared_scene.view_projection,
                    spot_lines.items,
                    .{ 0.50, 1.00, 0.30, 1.00 }, // green — spot
                );
                stats.add(sp_stats);
            }
        }

        return stats;
    }

    fn enqueueSelectionReadbacks(self: *Renderer, frame: rhi_mod.Frame, id_texture: *const rhi_mod.Texture) !void {
        const pending = self.pending_selection_readbacks.items;
        const total_buffer_size = std.math.cast(u32, pending.len * @as(usize, selection_readback_bytes)) orelse return error.OutOfMemory;

        if (id_texture.desc.width == 0 or id_texture.desc.height == 0) {
            try self.rhi.submitFrame(frame);
            try self.applyPendingSelectionMisses();
            return;
        }

        var readbacks = try self.allocator.alloc(InFlightSelectionReadback, pending.len);
        errdefer self.allocator.free(readbacks);

        var transfer_buffer = try self.rhi.createTransferBuffer(.{
            .size = total_buffer_size,
            .upload = false,
        });
        errdefer self.rhi.releaseTransferBuffer(&transfer_buffer);

        for (pending, 0..) |request, index| {
            readbacks[index] = .{
                .request = request,
                .offset = std.math.cast(u32, index * @as(usize, selection_readback_bytes)) orelse return error.OutOfMemory,
            };
        }

        const copy_pass = try self.rhi.beginCopyPass(frame);

        for (readbacks) |readback| {
            const pixel_x = @min(readback.request.pixel_x, id_texture.desc.width - 1);
            const pixel_y = @min(readback.request.pixel_y, id_texture.desc.height - 1);
            self.rhi.downloadTexturePixelToOffset(copy_pass, id_texture, &transfer_buffer, readback.offset, pixel_x, pixel_y);
        }

        self.rhi.endCopyPass(copy_pass);

        var fence = try self.rhi.submitFrameAndAcquireFence(frame);
        errdefer self.rhi.releaseFence(&fence);

        try self.in_flight_selection_batches.append(self.allocator, .{
            .fence = fence,
            .transfer_buffer = transfer_buffer,
            .readbacks = readbacks,
        });
        self.pending_selection_readbacks.clearRetainingCapacity();
    }

    fn resolveSelectionReadbacks(self: *Renderer) !void {
        while (self.in_flight_selection_batches.items.len > 0) {
            if (!self.rhi.isFenceSignaled(&self.in_flight_selection_batches.items[0].fence)) {
                break;
            }

            var batch = self.in_flight_selection_batches.orderedRemove(0);
            defer batch.deinit(self.allocator, &self.rhi);

            // Skip applying picks when gizmo drag is active to prevent
            // entity selection from overriding gizmo axis interaction.
            if (self.suppress_entity_pick) continue;

            for (batch.readbacks) |readback| {
                var pixel: [4]u8 = undefined;
                try self.rhi.readTransferBufferBytesAt(&batch.transfer_buffer, readback.offset, pixel[0..]);
                const entity = id_pass_mod.decodeEntityIdBgra(pixel);
                _ = try self.selection_history.applyPick(entity, readback.request.mode);
            }
        }
    }

    fn applyPendingSelectionMisses(self: *Renderer) !void {
        for (self.pending_selection_readbacks.items) |request| {
            _ = try self.selection_history.applyPick(null, request.mode);
        }
        self.pending_selection_readbacks.clearRetainingCapacity();
    }

    fn releaseInFlightSelectionBatches(self: *Renderer) void {
        for (self.in_flight_selection_batches.items) |*batch| {
            batch.deinit(self.allocator, &self.rhi);
        }
        self.in_flight_selection_batches.deinit(self.allocator);
    }
};

fn resolveEnvironmentTextures(
    self: *Renderer,
    scene: *scene_mod.Scene,
    prepared_scene: *mesh_pass_mod.PreparedScene,
) !void {
    return renderer_environment.resolveEnvironmentTextures(self, scene, prepared_scene);
}

/// Sync the first Sky component found in the scene world to PreparedScene.
/// If a Sky entity exists, its asset_id overrides the library's scene_environment_asset_id.
fn syncSkyComponent(scene: *scene_mod.Scene, prepared_scene: *mesh_pass_mod.PreparedScene) void {
    for (scene.entities.items) |*entity| {
        const sky = entity.sky orelse continue;
        const asset_id = sky.assetIdSlice();
        if (asset_id.len > 0) {
            _ = scene.resources.setSceneEnvironmentAssetId(asset_id) catch {};
        }
        prepared_scene.sky_intensity = sky.intensity;
        prepared_scene.sky_enabled = sky.enabled;
        return;
    }
    // No Sky component — keep defaults (sky_intensity=1.0, sky_enabled=true)
}

fn expectVec3ApproxEqAbs(expected: [3]f32, actual: [3]f32, tolerance: f32) !void {
    try std.testing.expectApproxEqAbs(expected[0], actual[0], tolerance);
    try std.testing.expectApproxEqAbs(expected[1], actual[1], tolerance);
    try std.testing.expectApproxEqAbs(expected[2], actual[2], tolerance);
}

fn findHashUnitFloatSeed(threshold: f32, want_lte: bool) !u32 {
    var seed: u32 = 0;
    while (true) : (seed += 1) {
        const value = hashUnitFloat(seed);
        if (want_lte) {
            if (value <= threshold) return seed;
        } else {
            if (value > threshold) return seed;
        }
        if (seed == std.math.maxInt(u32)) return error.SeedNotFound;
    }
}

test "sampleGGXVisibleHalfVector keeps sampled microfacets visible to the view" {
    const normal = [3]f32{ 0.0, 0.0, 1.0 };
    const view_dir = vec3.normalize(.{ 0.35, 0.1, 0.93 });
    const roughness: f32 = 0.55;

    var seed: u32 = 0;
    while (seed < 64) : (seed += 1) {
        const half_vector = sampleGGXVisibleHalfVector(normal, view_dir, roughness, seed);
        try std.testing.expect(vec3.dot(half_vector, normal) > 0.0);
        try std.testing.expect(vec3.dot(half_vector, view_dir) > 0.0);

        const light_dir = vec3.normalize(reflectVector(vec3.scale(view_dir, -1.0), half_vector));
        if (vec3.dot(light_dir, normal) > 0.0) {
            const pdf = ggxSpecularPdf(normal, view_dir, light_dir, roughness);
            try std.testing.expect(std.math.isFinite(pdf));
            try std.testing.expect(pdf > 0.0);
        }
    }
}

test "adaptive path trace helpers early-out stable tiles and keep noisy tiles on full budget" {
    try std.testing.expectEqual(@as(u32, 1), pathTraceAdaptiveMinSamples(1));
    try std.testing.expectEqual(@as(u32, 2), pathTraceAdaptiveMinSamples(4));
    try std.testing.expectEqual(@as(u32, 4), pathTraceAdaptiveMinSamples(16));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pathTraceAdaptiveNoiseMetric(2.0, 1.0, 0), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pathTraceAdaptiveNoiseMetric(2.0, 1.0, 4), 0.000001);
    try std.testing.expect(pathTraceAdaptiveNoiseMetric(2.0, 1.8, 4) > 0.015);
    try std.testing.expectEqual(@as(u32, 2), pathTraceAdaptiveTargetSamples(4, 0.01));
    try std.testing.expectEqual(@as(u32, 3), pathTraceAdaptiveTargetSamples(4, 0.03));
    try std.testing.expectEqual(@as(u32, 4), pathTraceAdaptiveTargetSamples(4, 0.12));
    try std.testing.expectEqual(@as(u32, 4), pathTraceAdaptiveTargetSamples(16, 0.01));
    try std.testing.expectEqual(@as(u32, 10), pathTraceAdaptiveTargetSamples(16, 0.03));
    try std.testing.expectEqual(@as(u32, 16), pathTraceAdaptiveTargetSamples(16, 0.12));
    try std.testing.expectEqual(@as(u32, 24), pathTraceAdaptiveTileSpan(3));
}

test "samplePathTraceMaterial applies normal metallic-roughness AO and emissive maps" {
    var base_color_pixels = [_]f32{ 0.25, 0.50, 0.75, 1.0 };
    var metallic_roughness_pixels = [_]f32{ 0.0, 0.25, 0.8, 1.0 };
    var ao_pixels = [_]f32{ 0.5, 0.0, 0.0, 1.0 };
    var emissive_pixels = [_]f32{ 2.0, 0.5, 1.0, 1.0 };
    var normal_pixels = [_]f32{ 0.8, 0.5, 0.9, 1.0 };

    const textures = [_]PathTraceTexture{
        .{
            .pixels = std.mem.sliceAsBytes(base_color_pixels[0..]),
            .width = 1,
            .height = 1,
            .format = .rgba32_float,
        },
        .{
            .pixels = std.mem.sliceAsBytes(metallic_roughness_pixels[0..]),
            .width = 1,
            .height = 1,
            .format = .rgba32_float,
        },
        .{
            .pixels = std.mem.sliceAsBytes(ao_pixels[0..]),
            .width = 1,
            .height = 1,
            .format = .rgba32_float,
        },
        .{
            .pixels = std.mem.sliceAsBytes(emissive_pixels[0..]),
            .width = 1,
            .height = 1,
            .format = .rgba32_float,
        },
        .{
            .pixels = std.mem.sliceAsBytes(normal_pixels[0..]),
            .width = 1,
            .height = 1,
            .format = .rgba32_float,
        },
    };

    const tri = PathTraceTriangle{
        .v0 = .{ 0.0, 0.0, 0.0 },
        .v1 = .{ 1.0, 0.0, 0.0 },
        .v2 = .{ 0.0, 1.0, 0.0 },
        .n0 = .{ 0.0, 0.0, 1.0 },
        .n1 = .{ 0.0, 0.0, 1.0 },
        .n2 = .{ 0.0, 0.0, 1.0 },
        .uv0 = .{ 0.0, 0.0 },
        .uv1 = .{ 1.0, 0.0 },
        .uv2 = .{ 0.0, 1.0 },
        .albedo = .{ 0.8, 0.6, 0.4 },
        .emissive = .{ 1.0, 2.0, 3.0 },
        .metallic = 0.5,
        .roughness = 0.8,
        .transmission = 0.0,
        .ior = 1.5,
        .thickness = 0.0,
        .base_color_texture_index = 0,
        .metallic_roughness_texture_index = 1,
        .normal_texture_index = 4,
        .occlusion_texture_index = 2,
        .emissive_texture_index = 3,
    };

    const sample = samplePathTraceMaterial(
        tri,
        &textures,
        .{ 0.25, 0.25 },
        .{ 0.0, 0.0, 1.0 },
        .{ 0.0, 0.0, 1.0 },
    );

    try expectVec3ApproxEqAbs(.{ 0.1, 0.15, 0.15 }, sample.albedo, 0.0001);
    try expectVec3ApproxEqAbs(.{ 2.0, 1.0, 3.0 }, sample.emissive, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), sample.metallic, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), sample.roughness, 0.0001);
    try expectVec3ApproxEqAbs(.{ 0.6, 0.0, 0.8 }, sample.shading_normal, 0.0001);
    try std.testing.expect(vec3.dot(sample.shading_normal, .{ 0.0, 0.0, 1.0 }) > 0.0);
}

test "samplePathTraceGuidePixel captures first-hit albedo and normal guides" {
    var base_color_pixels = [_]f32{ 0.25, 0.50, 0.75, 1.0 };
    var normal_pixels = [_]f32{ 0.8, 0.5, 0.9, 1.0 };

    var textures = [_]PathTraceTexture{
        .{
            .pixels = std.mem.sliceAsBytes(base_color_pixels[0..]),
            .width = 1,
            .height = 1,
            .format = .rgba32_float,
        },
        .{
            .pixels = std.mem.sliceAsBytes(normal_pixels[0..]),
            .width = 1,
            .height = 1,
            .format = .rgba32_float,
        },
    };

    var triangles = [_]PathTraceTriangle{
        .{
            .v0 = .{ -2.0, -2.0, 0.0 },
            .v1 = .{ 2.0, -2.0, 0.0 },
            .v2 = .{ -2.0, 2.0, 0.0 },
            .n0 = .{ 0.0, 0.0, 1.0 },
            .n1 = .{ 0.0, 0.0, 1.0 },
            .n2 = .{ 0.0, 0.0, 1.0 },
            .uv0 = .{ 0.0, 0.0 },
            .uv1 = .{ 1.0, 0.0 },
            .uv2 = .{ 0.0, 1.0 },
            .albedo = .{ 0.8, 0.6, 0.4 },
            .emissive = .{ 0.0, 0.0, 0.0 },
            .metallic = 0.0,
            .roughness = 0.5,
            .transmission = 0.0,
            .ior = 1.5,
            .thickness = 0.0,
            .base_color_texture_index = 0,
            .normal_texture_index = 1,
        },
    };
    var meshes = [_]PathTraceMesh{
        .{
            .aabb = .{ .min = .{ -2.0, -2.0, -0.01 }, .max = .{ 2.0, 2.0, 0.01 } },
            .tri_start = 0,
            .tri_count = 1,
        },
    };

    const pt = PathTraceProgressiveState{
        .trace_width = 1,
        .trace_height = 1,
        .triangles = triangles[0..],
        .meshes = meshes[0..],
        .textures = textures[0..],
        .inv_view_projection = mat4_mod.identity(),
        .camera_origin = .{ 0.0, 0.0, -1.0 },
    };

    const guide = samplePathTraceGuidePixel(&pt, 0, 0);
    try expectVec3ApproxEqAbs(.{ 0.2, 0.3, 0.3 }, guide.albedo, 0.0001);
    try expectVec3ApproxEqAbs(.{ 0.6, 0.0, 0.8 }, guide.normal, 0.0001);
}

test "applyPathTraceRussianRoulette gates bounce and rescales surviving throughput" {
    var early_tp = [3]f32{ 0.25, 0.5, 1.2 };
    try std.testing.expect(!applyPathTraceRussianRoulette(&early_tp, 1, 0));
    try expectVec3ApproxEqAbs(.{ 0.25, 0.5, 1.2 }, early_tp, 0.000001);

    try std.testing.expectApproxEqAbs(
        @as(f32, 0.95),
        pathTraceRussianRouletteSurvivalProbability(.{ 1.2, 1.1, 0.2 }),
        0.000001,
    );

    var zero_tp = [3]f32{ 0.0, 0.0, 0.0 };
    try std.testing.expect(applyPathTraceRussianRoulette(&zero_tp, 3, 0));
    try expectVec3ApproxEqAbs(.{ 0.0, 0.0, 0.0 }, zero_tp, 0.000001);

    const survive_seed = try findHashUnitFloatSeed(0.5, true);
    var surviving_tp = [3]f32{ 0.25, 0.5, 0.4 };
    try std.testing.expect(!applyPathTraceRussianRoulette(&surviving_tp, 3, survive_seed));
    try expectVec3ApproxEqAbs(.{ 0.5, 1.0, 0.8 }, surviving_tp, 0.000001);

    const terminate_seed = try findHashUnitFloatSeed(0.5, false);
    var terminated_tp = [3]f32{ 0.25, 0.5, 0.4 };
    try std.testing.expect(applyPathTraceRussianRoulette(&terminated_tp, 3, terminate_seed));
    try expectVec3ApproxEqAbs(.{ 0.25, 0.5, 0.4 }, terminated_tp, 0.000001);
}

test "resolveMaterialThumbnailSource captures loaded material signatures" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const texture_handle = try world.assets().createTexture(.{
        .name = "PreviewAlbedo",
        .width = 4,
        .height = 2,
        .pixels = &[_]u8{
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
        },
    });
    _ = try world.assets().bindTextureAssetRecord(
        texture_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .texture, "texture://preview", "assets/textures/preview.png", "Preview Texture"),
    );

    const material_handle = try world.assets().createMaterial(.{
        .name = "PreviewMaterial",
        .shading = .lambert,
        .base_color_factor = .{ 0.2, 0.4, 0.6, 1.0 },
        .base_color_texture = texture_handle,
    });
    _ = try world.assets().bindMaterialAssetRecord(
        material_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .material, "material://preview", "assets/materials/preview.guava_material", "Preview Material"),
    );

    const source = resolveMaterialThumbnailSource(world.assets(), "material://preview").?;
    try std.testing.expectEqual(material_handle, source.material_handle);
    try std.testing.expectEqual(components.ShadingModel.lambert, source.signature.shading);
    try std.testing.expectEqualDeep([4]f32{ 0.2, 0.4, 0.6, 1.0 }, source.signature.base_color_factor);
    try std.testing.expectEqual(texture_handle, source.signature.texture.handle.?);
    try std.testing.expectEqual(@as(u32, 4), source.signature.texture.width);
    try std.testing.expectEqual(@as(u32, 2), source.signature.texture.height);
}

test "material thumbnail preview scene mirrors source material resources" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const texture_handle = try world.assets().createTexture(.{
        .name = "PreviewSyncTexture",
        .width = 2,
        .height = 2,
        .pixels = &[_]u8{
            255, 128, 0, 255,
            255, 128, 0, 255,
            255, 128, 0, 255,
            255, 128, 0, 255,
        },
    });
    _ = try world.assets().bindTextureAssetRecord(
        texture_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .texture, "texture://sync", "assets/textures/sync.png", "Sync Texture"),
    );

    const material_handle = try world.assets().createMaterial(.{
        .name = "PreviewSyncMaterial",
        .shading = .unlit,
        .base_color_factor = .{ 0.9, 0.3, 0.1, 1.0 },
        .base_color_texture = texture_handle,
    });
    _ = try world.assets().bindMaterialAssetRecord(
        material_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .material, "material://sync", "assets/materials/sync.guava_material", "Sync Material"),
    );

    var preview = try MaterialThumbnailPreview.init(std.testing.allocator);
    defer preview.deinit();

    const source = resolveMaterialThumbnailSource(world.assets(), "material://sync").?;
    try preview.syncFromSource(source);

    const preview_material = preview.world.resources.material(preview.preview_material_handle).?;
    try std.testing.expectEqual(components.ShadingModel.unlit, preview_material.shading);
    try std.testing.expectEqualDeep([4]f32{ 0.9, 0.3, 0.1, 1.0 }, preview_material.base_color_factor);
    try std.testing.expect(preview_material.base_color_texture != null);

    const preview_texture = preview.world.resources.texture(preview_material.base_color_texture.?).?;
    try std.testing.expectEqual(@as(u32, 2), preview_texture.width);
    try std.testing.expectEqual(@as(u32, 2), preview_texture.height);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        255, 128, 0, 255,
        255, 128, 0, 255,
        255, 128, 0, 255,
        255, 128, 0, 255,
    }, preview_texture.pixels);
}
