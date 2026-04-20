//! RTS 相机控制器
//!
//! 提供适用于即时战略游戏的俯瞰/斜视角相机。
//! 支持 WASD/方向键平移、屏幕边缘滚动、滚轮缩放、中键拖拽平移、
//! 可选旋转（Alt+RMB 或 Q/E）、地图边界约束。
//!
//! ## 使用方式
//!
//! 1. 在 Entity 上设置 `rts_camera` 组件（含 Config）
//! 2. 引擎每帧自动通过 `RtsCameraSystem.update()` 驱动
//! 3. 脚本可通过修改 Config 字段调整参数
//!
//! ## 坐标系
//!
//! Y 轴朝上。相机以 `focus_point`（地面焦点）为中心，
//! 通过 `yaw`、`pitch`、`distance` 参数计算出轨道位置和朝向。

const std = @import("std");
const components = @import("../scene/components.zig");
const vec3 = @import("../math/vec3.zig");
const quat = @import("../math/quat.zig");
const input_mod = @import("../core/input.zig");
const world_mod = @import("../scene/world.zig");

/// RTS 相机运行时状态（挂载在 Entity 上的组件）
pub const RtsCamera = struct {
    /// 地面焦点（相机围绕此点旋转/平移）
    focus_point: [3]f32 = .{ 0.0, 0.0, 0.0 },
    /// 水平旋转（弧度，0 = -Z 方向）
    yaw: f32 = 0.0,
    /// 俯仰角（弧度，负值向下看）。RTS 典型值约 -0.8 ~ -1.2
    pitch: f32 = -1.0,
    /// 相机与焦点距离
    distance: f32 = 20.0,

    /// 配置参数（可在运行时调节）
    config: Config = .{},

    /// 是否启用此控制器
    enabled: bool = true,
};

/// RTS 相机配置参数
pub const Config = struct {
    // ── 平移 ──
    /// WASD/方向键平移速度（单位/秒）
    pan_speed: f32 = 20.0,
    /// 按住 Shift 时的平移加速倍率
    pan_boost: f32 = 2.5,
    /// 中键拖拽平移灵敏度
    drag_sensitivity: f32 = 0.05,

    // ── 屏幕边缘滚动 ──
    /// 是否启用屏幕边缘滚动
    edge_scroll_enabled: bool = true,
    /// 触发边缘滚动的像素宽度
    edge_scroll_margin: f32 = 10.0,
    /// 边缘滚动速度（单位/秒）
    edge_scroll_speed: f32 = 15.0,

    // ── 缩放 ──
    /// 滚轮缩放灵敏度（每档变化比率）
    zoom_sensitivity: f32 = 0.15,
    /// 最小距离
    min_distance: f32 = 5.0,
    /// 最大距离
    max_distance: f32 = 120.0,

    // ── 旋转 ──
    /// 是否允许旋转
    rotation_enabled: bool = true,
    /// Q/E 旋转速度（弧度/秒）
    rotate_speed: f32 = 2.0,
    /// Alt+RMB 拖拽旋转灵敏度
    rotate_drag_sensitivity: f32 = 0.005,
    /// 最小俯仰角（弧度，向下看更多）
    min_pitch: f32 = -1.4, // ≈ -80°
    /// 最大俯仰角（弧度，接近水平）
    max_pitch: f32 = -0.15, // ≈ -9°

    // ── 地图边界 ──
    /// 是否启用地图边界
    bounds_enabled: bool = false,
    /// 焦点 X 最小值
    bounds_min_x: f32 = -500.0,
    /// 焦点 X 最大值
    bounds_max_x: f32 = 500.0,
    /// 焦点 Z 最小值
    bounds_min_z: f32 = -500.0,
    /// 焦点 Z 最大值
    bounds_max_z: f32 = 500.0,

    // ── 平滑 ──
    /// 平移平滑系数（0 = 无平滑，1 = 完全平滑/不移动）
    pan_smoothing: f32 = 0.0,
    /// 缩放平滑系数
    zoom_smoothing: f32 = 0.0,
};

/// 系统级别的 RTS 相机更新器
pub const RtsCameraSystem = struct {
    /// 每帧更新：扫描所有带 `rts_camera` 组件的实体，
    /// 根据输入状态更新焦点/旋转/距离，并写入 `local_transform`。
    pub fn update(
        world: *world_mod.World,
        input: *const input_mod.InputState,
        delta: f32,
        viewport_width: f32,
        viewport_height: f32,
    ) void {
        for (world.entities.items) |*entity| {
            const rts = &(entity.rts_camera orelse continue);
            if (!rts.enabled) continue;

            updateController(rts, input, delta, viewport_width, viewport_height);
            applyToTransform(rts, &entity.local_transform);
            world.markDirty(entity.id);
        }
    }
};

/// 核心逻辑：读取输入，更新 RtsCamera 状态
fn updateController(
    rts: *RtsCamera,
    input: *const input_mod.InputState,
    delta: f32,
    viewport_w: f32,
    viewport_h: f32,
) void {
    const cfg = rts.config;

    // ── 1. WASD / 方向键平移 ──
    var pan_dir: [3]f32 = .{ 0.0, 0.0, 0.0 };

    // 计算世界空间中相机朝向的水平方向
    const forward = vec3.normalize(.{
        -std.math.sin(rts.yaw),
        0.0,
        -std.math.cos(rts.yaw),
    });
    const right = vec3.normalize(.{
        std.math.cos(rts.yaw),
        0.0,
        -std.math.sin(rts.yaw),
    });

    if (input.isKeyDown(.w) or input.isKeyDown(.up)) pan_dir = vec3.add(pan_dir, forward);
    if (input.isKeyDown(.s) or input.isKeyDown(.down)) pan_dir = vec3.sub(pan_dir, forward);
    if (input.isKeyDown(.d) or input.isKeyDown(.right)) pan_dir = vec3.add(pan_dir, right);
    if (input.isKeyDown(.a) or input.isKeyDown(.left)) pan_dir = vec3.sub(pan_dir, right);

    // ── 2. 屏幕边缘滚动 ──
    if (cfg.edge_scroll_enabled and viewport_w > 0 and viewport_h > 0) {
        const mx = input.mouse_position[0];
        const my = input.mouse_position[1];
        const margin = cfg.edge_scroll_margin;

        if (mx < margin) pan_dir = vec3.sub(pan_dir, right);
        if (mx > viewport_w - margin) pan_dir = vec3.add(pan_dir, right);
        if (my < margin) pan_dir = vec3.add(pan_dir, forward);
        if (my > viewport_h - margin) pan_dir = vec3.sub(pan_dir, forward);
    }

    // 归一化方向后应用速度
    if (vec3.length(pan_dir) > 0.0001) {
        const boost: f32 = if (input.modifiers.shift) cfg.pan_boost else 1.0;
        const pan_delta = vec3.scale(vec3.normalize(pan_dir), cfg.pan_speed * boost * delta);
        rts.focus_point = vec3.add(rts.focus_point, pan_delta);
    }

    // ── 3. 中键拖拽平移 ──
    if (input.isMouseDown(.middle)) {
        const drag_right = vec3.scale(right, -input.mouse_delta[0] * cfg.drag_sensitivity * rts.distance * 0.01);
        const drag_fwd = vec3.scale(forward, input.mouse_delta[1] * cfg.drag_sensitivity * rts.distance * 0.01);
        rts.focus_point = vec3.add(rts.focus_point, vec3.add(drag_right, drag_fwd));
    }

    // ── 4. 滚轮缩放 ──
    if (@abs(input.mouse_wheel[1]) > 0.001) {
        const zoom_factor = 1.0 - input.mouse_wheel[1] * cfg.zoom_sensitivity;
        rts.distance = std.math.clamp(rts.distance * zoom_factor, cfg.min_distance, cfg.max_distance);
    }

    // ── 5. 旋转 ──
    if (cfg.rotation_enabled) {
        // Q/E 键旋转
        if (input.isKeyDown(.q)) rts.yaw -= cfg.rotate_speed * delta;
        if (input.isKeyDown(.e)) rts.yaw += cfg.rotate_speed * delta;

        // Alt+RMB 拖拽旋转
        if (input.modifiers.alt and input.isMouseDown(.right)) {
            rts.yaw -= input.mouse_delta[0] * cfg.rotate_drag_sensitivity;
            rts.pitch = std.math.clamp(
                rts.pitch - input.mouse_delta[1] * cfg.rotate_drag_sensitivity,
                cfg.min_pitch,
                cfg.max_pitch,
            );
        }
    }

    // 确保 pitch 始终在范围内
    rts.pitch = std.math.clamp(rts.pitch, cfg.min_pitch, cfg.max_pitch);

    // ── 6. 地图边界约束 ──
    if (cfg.bounds_enabled) {
        rts.focus_point[0] = std.math.clamp(rts.focus_point[0], cfg.bounds_min_x, cfg.bounds_max_x);
        rts.focus_point[2] = std.math.clamp(rts.focus_point[2], cfg.bounds_min_z, cfg.bounds_max_z);
    }
}

/// 将 RtsCamera 状态写入 Entity 的 local_transform
fn applyToTransform(rts: *const RtsCamera, transform: *components.Transform) void {
    // 相机位于焦点后方+上方的轨道位置
    const cam_offset: [3]f32 = .{
        -std.math.sin(rts.yaw) * std.math.cos(rts.pitch) * rts.distance,
        -std.math.sin(rts.pitch) * rts.distance,
        -std.math.cos(rts.yaw) * std.math.cos(rts.pitch) * rts.distance,
    };
    transform.translation = vec3.add(rts.focus_point, cam_offset);

    // 旋转：先 yaw 再 pitch（与编辑器相机一致）
    transform.rotation = quat.fromEuler(.{ rts.pitch, rts.yaw, 0.0 });
}
