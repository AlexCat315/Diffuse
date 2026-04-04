//!guava builtin=fps_controller move_speed=5.0 mouse_sensitivity=0.002 gravity=-9.8 jump_velocity=5.0
const std = @import("std");
const script = @import("../../src/engine/script/script.zig");

/// FPS 控制器脚本 - 简单的第一人称移动控制
pub const FpsControllerScript = struct {
    /// 移动速度
    move_speed: f32 = 5.0,
    /// 鼠标灵敏度
    mouse_sensitivity: f32 = 0.002,
    /// 是否锁定指针
    lock_cursor: bool = true,
    /// 重力
    gravity: f32 = -9.8,
    /// 跳跃速度
    jump_velocity: f32 = 5.0,
    /// 是否在地面上
    is_grounded: bool = false,
    /// Y轴速度（用于重力）
    vertical_velocity: f32 = 0.0,
};

/// 脚本入口 - 初始化
pub fn onInit(ctx: *script.ScriptContext) void {
    ctx.log("FPS Controller initialized");
}

/// 脚本入口 - 每帧更新
pub fn onUpdate(ctx: *script.ScriptContext, dt: f32) void {
    const self = ctx.getUserData(FpsControllerScript) orelse return;

    // 获取当前变换
    var pos = ctx.getPosition() orelse return;
    var rot = ctx.getRotation() orelse return;

    // 获取输入（需要 Input 系统支持）
    // 这里假设有某种输入系统 API
    const input = getInput(ctx);

    // 计算移动方向
    var move_x: f32 = 0;
    var move_z: f32 = 0;

    if (input.forward) move_z += 1;
    if (input.backward) move_z -= 1;
    if (input.left) move_x -= 1;
    if (input.right) move_x += 1;

    // 标准化移动向量
    const move_len = @sqrt(move_x * move_x + move_z * move_z);
    if (move_len > 0) {
        move_x /= move_len;
        move_z /= move_len;
    }

    // 应用移动（相对于相机朝向）
    const speed = self.move_speed * dt;
    pos[0] += move_x * speed;
    pos[2] += move_z * speed;

    // 应用重力
    self.vertical_velocity += self.gravity * dt;
    pos[1] += self.vertical_velocity * dt;

    // 简单地面碰撞检测
    if (pos[1] < 0) {
        pos[1] = 0;
        self.vertical_velocity = 0;
        self.is_grounded = true;
    } else {
        self.is_grounded = false;
    }

    // 跳跃
    if (input.jump and self.is_grounded) {
        self.vertical_velocity = self.jump_velocity;
        self.is_grounded = false;
    }

    // 应用鼠标旋转
    rot[0] += input.mouse_dy * self.mouse_sensitivity;
    rot[1] += input.mouse_dx * self.mouse_sensitivity;

    // 限制俯仰角
    rot[0] = std.math.clamp(rot[0], -1.5, 1.5);

    // 应用变换
    ctx.setPosition(pos);
    ctx.setRotation(rot);
}

/// 脚本入口 - 销毁时调用
pub fn onDestroy(ctx: *script.ScriptContext) void {
    ctx.log("FPS Controller destroyed");
}

/// 输入状态结构
const InputState = struct {
    forward: bool = false,
    backward: bool = false,
    left: bool = false,
    right: bool = false,
    jump: bool = false,
    mouse_dx: f32 = 0,
    mouse_dy: f32 = 0,
};

/// 获取输入状态（需要与 Input 系统集成）
fn getInput(ctx: *script.ScriptContext) InputState {
    // Builtin runtime integrates input directly; this helper remains as a reference shape.
    _ = ctx;
    return .{};
}
