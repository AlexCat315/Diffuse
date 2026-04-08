//! FPS 相机控制器
//!
//! 提供第一人称射击游戏的相机控制。
//! 支持鼠标视角（Yaw + Pitch 限制）、WASD 移动、冲刺、蹲下、
//! 头部摆动（Head Bob）、可选 ADS（瞄准）FOV 过渡。
//!
//! ## 使用方式
//!
//! 1. 在 Entity 上设置 `fps_camera` 组件
//! 2. 引擎每帧自动通过 `FpsCameraSystem.update()` 驱动
//! 3. 脚本可通过修改 Config 字段调整参数
//!
//! ## 坐标系
//!
//! Y 轴朝上。Yaw 绕 Y 轴旋转，Pitch 绕局部 X 轴旋转。

const std = @import("std");
const components = @import("../scene/components.zig");
const vec3 = @import("../math/vec3.zig");
const quat = @import("../math/quat.zig");
const input_mod = @import("../core/input.zig");
const world_mod = @import("../scene/world.zig");

/// FPS 相机运行时状态（挂载在 Entity 上的组件）
pub const FpsCamera = struct {
    /// 水平旋转角（弧度）
    yaw: f32 = 0.0,
    /// 垂直旋转角（弧度，正值向上）
    pitch: f32 = 0.0,
    /// 当前速度（用于平滑加减速）
    velocity: [3]f32 = .{ 0, 0, 0 },
    /// 是否在冲刺
    is_sprinting: bool = false,
    /// 是否蹲下
    is_crouching: bool = false,
    /// 是否在瞄准（ADS）
    is_aiming: bool = false,
    /// 头部摆动相位（弧度）
    bob_phase: f32 = 0.0,

    /// 配置参数
    config: Config = .{},

    /// 是否启用此控制器
    enabled: bool = true,
};

/// FPS 相机配置参数
pub const Config = struct {
    // ── 鼠标灵敏度 ──
    /// 水平灵敏度
    sensitivity_x: f32 = 0.003,
    /// 垂直灵敏度
    sensitivity_y: f32 = 0.003,
    /// 最大仰角（弧度，略小于 90°）
    max_pitch: f32 = 1.48, // ~85°
    /// 最小俯角
    min_pitch: f32 = -1.48,
    /// 是否反转 Y 轴
    invert_y: bool = false,

    // ── 移动 ──
    /// 行走速度（单位/秒）
    move_speed: f32 = 5.0,
    /// 冲刺速度倍率
    sprint_multiplier: f32 = 2.0,
    /// 蹲下速度倍率
    crouch_multiplier: f32 = 0.5,
    /// 加速度（0 = 立即到达目标速度）
    acceleration: f32 = 30.0,
    /// 摩擦力（减速率）
    friction: f32 = 10.0,

    // ── 高度 ──
    /// 站立时眼睛高度
    eye_height: f32 = 1.7,
    /// 蹲下时眼睛高度
    crouch_eye_height: f32 = 1.0,
    /// 蹲下过渡速度
    crouch_transition_speed: f32 = 8.0,

    // ── 头部摆动 ──
    /// 摆动幅度（上下）
    bob_amplitude: f32 = 0.04,
    /// 摆动频率（步/秒）
    bob_frequency: f32 = 10.0,
    /// 冲刺时摆动频率倍率
    sprint_bob_multiplier: f32 = 1.4,

    // ── ADS（瞄准镜） ──
    /// 默认 FOV（弧度）
    default_fov: f32 = 1.0472, // 60°
    /// ADS FOV（弧度，通常更小）
    ads_fov: f32 = 0.6,
    /// ADS 过渡速度
    ads_transition_speed: f32 = 10.0,
    /// ADS 时灵敏度倍率
    ads_sensitivity_multiplier: f32 = 0.5,
};

/// FPS 相机系统 — 不需要实例化，纯函数操作
pub const FpsCameraSystem = struct {
    /// 每帧更新所有带 FpsCamera 组件的实体
    pub fn update(world: *world_mod.World, input: *const input_mod.InputState, delta: f32) void {
        for (world.entities.items) |*entity| {
            var cam = entity.fps_camera orelse continue;
            if (!cam.enabled) continue;

            updateController(&cam, input, delta);
            applyToTransform(&cam, entity);

            entity.fps_camera = cam;
        }
    }
};

fn updateController(cam: *FpsCamera, input: *const input_mod.InputState, delta: f32) void {
    const cfg = cam.config;

    // ── 鼠标视角 ──
    var sens_x = cfg.sensitivity_x;
    var sens_y = cfg.sensitivity_y;
    if (cam.is_aiming) {
        sens_x *= cfg.ads_sensitivity_multiplier;
        sens_y *= cfg.ads_sensitivity_multiplier;
    }

    cam.yaw -= input.mouse_delta[0] * sens_x;
    const pitch_delta = input.mouse_delta[1] * sens_y * @as(f32, if (cfg.invert_y) -1.0 else 1.0);
    cam.pitch -= pitch_delta;
    cam.pitch = std.math.clamp(cam.pitch, cfg.min_pitch, cfg.max_pitch);

    // ── 冲刺/蹲下 ──
    const shift_idx = @intFromEnum(input_mod.Key.shift);
    cam.is_sprinting = input.key_down[shift_idx];

    const ctrl_idx = @intFromEnum(input_mod.Key.ctrl);
    if (input.key_pressed[ctrl_idx]) {
        cam.is_crouching = !cam.is_crouching;
    }

    // ── ADS 切换（右键按住） ──
    const rmb = @intFromEnum(input_mod.MouseButton.right);
    cam.is_aiming = input.mouse_down[rmb];

    // ── 移动输入 ──
    var move_input: [3]f32 = .{ 0, 0, 0 };

    const w_idx = @intFromEnum(input_mod.Key.w);
    const s_idx = @intFromEnum(input_mod.Key.s);
    const a_idx = @intFromEnum(input_mod.Key.a);
    const d_idx = @intFromEnum(input_mod.Key.d);

    if (input.key_down[w_idx]) move_input[2] -= 1.0; // 前（-Z）
    if (input.key_down[s_idx]) move_input[2] += 1.0; // 后（+Z）
    if (input.key_down[a_idx]) move_input[0] -= 1.0; // 左（-X）
    if (input.key_down[d_idx]) move_input[0] += 1.0; // 右（+X）

    // 归一化移动方向
    const len_sq = move_input[0] * move_input[0] + move_input[2] * move_input[2];
    if (len_sq > 0.001) {
        const inv_len = 1.0 / @sqrt(len_sq);
        move_input[0] *= inv_len;
        move_input[2] *= inv_len;
    }

    // 计算世界空间移动方向（基于 yaw 旋转）
    const cos_yaw = @cos(cam.yaw);
    const sin_yaw = @sin(cam.yaw);

    var world_move: [3]f32 = .{
        move_input[0] * cos_yaw - move_input[2] * sin_yaw,
        0,
        move_input[0] * sin_yaw + move_input[2] * cos_yaw,
    };

    // 速度修正
    var speed = cfg.move_speed;
    if (cam.is_sprinting and !cam.is_crouching) {
        speed *= cfg.sprint_multiplier;
    }
    if (cam.is_crouching) {
        speed *= cfg.crouch_multiplier;
    }

    world_move[0] *= speed;
    world_move[2] *= speed;

    // 加速/减速
    if (cfg.acceleration > 0) {
        const accel = cfg.acceleration * delta;
        cam.velocity[0] = approach(cam.velocity[0], world_move[0], accel);
        cam.velocity[2] = approach(cam.velocity[2], world_move[2], accel);
    } else {
        cam.velocity[0] = world_move[0];
        cam.velocity[2] = world_move[2];
    }

    // 摩擦减速（无输入时）
    if (len_sq <= 0.001 and cfg.friction > 0) {
        const fric = cfg.friction * delta;
        cam.velocity[0] = approach(cam.velocity[0], 0, fric);
        cam.velocity[2] = approach(cam.velocity[2], 0, fric);
    }

    // ── 头部摆动 ──
    const speed_xz = @sqrt(cam.velocity[0] * cam.velocity[0] + cam.velocity[2] * cam.velocity[2]);
    if (speed_xz > 0.5) {
        var freq = cfg.bob_frequency;
        if (cam.is_sprinting) freq *= cfg.sprint_bob_multiplier;
        cam.bob_phase += freq * delta;
        if (cam.bob_phase > std.math.pi * 2.0) {
            cam.bob_phase -= std.math.pi * 2.0;
        }
    } else {
        // 逐渐归零
        cam.bob_phase = approach(cam.bob_phase, 0, delta * 5.0);
    }
}

fn applyToTransform(cam: *const FpsCamera, entity: *world_mod.Entity) void {
    const cfg = cam.config;

    // 每帧位移
    // 注意：这里直接修改 local_transform.translation
    // 实际游戏中应通过 CharacterController 移动
    entity.local_transform.translation[0] += cam.velocity[0] * (1.0 / 60.0); // 简化：假设 60fps
    entity.local_transform.translation[2] += cam.velocity[2] * (1.0 / 60.0);

    // 眼睛高度（蹲下过渡由上层处理，这里直接设置）
    const target_height: f32 = if (cam.is_crouching) cfg.crouch_eye_height else cfg.eye_height;
    entity.local_transform.translation[1] = target_height;

    // 头部摆动偏移
    const bob_offset = @sin(cam.bob_phase) * cfg.bob_amplitude;
    entity.local_transform.translation[1] += bob_offset;

    // 旋转：先 pitch（绕 X）再 yaw（绕 Y）
    const pitch_quat = quat.fromAxisAngle(.{ 1, 0, 0 }, cam.pitch);
    const yaw_quat = quat.fromAxisAngle(.{ 0, 1, 0 }, cam.yaw);
    entity.local_transform.rotation = quat.mul(yaw_quat, pitch_quat);

    // ADS FOV 过渡（需要 Camera 组件）
    if (entity.camera) |*camera| {
        switch (camera.projection) {
            .perspective => |*persp| {
                const target_fov: f32 = if (cam.is_aiming) cfg.ads_fov else cfg.default_fov;
                // 简单线性插值
                const t = std.math.clamp(cfg.ads_transition_speed * (1.0 / 60.0), 0.0, 1.0);
                persp.fov_y_radians = persp.fov_y_radians + (target_fov - persp.fov_y_radians) * t;
            },
            else => {},
        }
    }
}

/// 向目标值靠近，步长不超过 max_step
fn approach(current: f32, target: f32, max_step: f32) f32 {
    if (current < target) {
        return @min(current + max_step, target);
    } else {
        return @max(current - max_step, target);
    }
}
