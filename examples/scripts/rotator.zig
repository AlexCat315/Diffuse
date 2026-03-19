/// Rotator Script - 让实体旋转的简单示例
const script = @import("../../src/engine/script/script.zig");
const context = @import("../../src/engine/script/context.zig");

/// 脚本用户数据 - 存储旋转速度
const RotatorData = struct {
    rotation_speed: f32 = 45.0, // 度/秒
};

/// OnInit - 脚本初始化时调用
pub fn onInit(ctx: *context.ScriptContext) void {
    // 分配用户数据
    const data = ctx.allocator.create(RotatorData) catch {
        ctx.error("Failed to allocate RotatorData");
        return;
    };
    data.rotation_speed = 45.0;
    ctx.setUserData(data);
    
    ctx.log("Rotator script initialized");
}

/// OnUpdate - 每帧调用
pub fn onUpdate(ctx: *context.ScriptContext, dt: f32) void {
    // 获取用户数据
    const data = ctx.getUserData(RotatorData) orelse {
        ctx.error("RotatorData not found");
        return;
    };
    
    // 获取当前旋转
    const current_rot = ctx.getRotation() orelse {
        ctx.error("Failed to get rotation");
        return;
    };
    
    // 计算新的旋转（简单绕Y轴旋转）
    const rotation_radians = data.rotation_speed * std.math.pi / 180.0 * dt;
    const quat = @import("../../src/engine/math/quat.zig");
    const new_rot = quat.mul(current_rot, quat.fromAxisAngle(.{ 0, 1, 0 }, rotation_radians));
    
    // 应用新旋转
    ctx.setRotation(new_rot);
}

/// OnDestroy - 脚本销毁时调用
pub fn onDestroy(ctx: *context.ScriptContext) void {
    // 释放用户数据
    if (ctx.getUserData(RotatorData)) |data| {
        ctx.allocator.destroy(data);
    }
    ctx.log("Rotator script destroyed");
}

/// 导出脚本虚拟表 - 这是脚本系统的入口点
pub const script_vtable = script.types.ScriptVTable{
    .onInit = onInit,
    .onUpdate = onUpdate,
    .onDestroy = onDestroy,
};
