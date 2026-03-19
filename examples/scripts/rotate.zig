const script = @import("../../src/engine/script/script.zig");

/// 旋转脚本 - 让实体绕 Y 轴旋转
pub const RotateScript = struct {
    /// 旋转速度（弧度/秒）
    speed: f32 = 1.0,
    /// 是否沿局部坐标旋转
    local_space: bool = true,
};

/// 脚本入口 - 初始化
pub fn onInit(ctx: *script.ScriptContext) void {
    ctx.log("RotateScript initialized");
}

/// 脚本入口 - 每帧更新
pub fn onUpdate(ctx: *script.ScriptContext, dt: f32) void {
    const self = ctx.getUserData(RotateScript) orelse return;
    
    if (self.local_space) {
        // 局部空间旋转
        if (ctx.getRotation()) |rot| {
            const speed = self.speed * dt;
            // 简单的 Y 轴旋转
            ctx.setRotation(.{ 0, @sin(speed * 0.5), 0, @cos(speed * 0.5) });
        }
    } else {
        // 世界空间旋转 - 需要获取当前旋转并修改
        if (ctx.getRotation()) |rot| {
            const speed = self.speed * dt;
            // 简单的 Y 轴旋转
            ctx.setRotation(.{ 0, @sin(speed * 0.5), 0, @cos(speed * 0.5) });
        }
    }
}

/// 脚本入口 - 销毁时调用
pub fn onDestroy(ctx: *script.ScriptContext) void {
    ctx.log("RotateScript destroyed");
}
