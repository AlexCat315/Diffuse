/// Fly Camera Script - 使用WASD和鼠标控制相机飞行
const script = @import("../../src/engine/script/script.zig");
const context = @import("../../src/engine/script/context.zig");
const input_mod = @import("../../src/engine/core/input.zig");

/// 相机控制数据
const CameraData = struct {
    /// 移动速度（单位/秒）
    move_speed: f32 = 5.0,
    /// 鼠标灵敏度
    mouse_sensitivity: f32 = 0.002,
    /// 是否首次获取鼠标（用于初始化）
    first_mouse: bool = true,
    /// 上次鼠标位置
    last_mouse_x: f32 = 0.0,
    last_mouse_y: f32 = 0.0,
    /// 相机俯仰角
    pitch: f32 = 0.0,
    /// 相机偏航角
    yaw: f32 = -90.0, // 面向-Z
};

/// OnInit - 脚本初始化
pub fn onInit(ctx: *context.ScriptContext) void {
    // 分配用户数据
    const data = ctx.allocator.create(CameraData) catch {
        ctx.error("Failed to allocate CameraData");
        return;
    };
    data.* = CameraData{};
    ctx.setUserData(data);
    
    ctx.log("Fly camera script initialized");
}

/// OnUpdate - 每帧更新
pub fn onUpdate(ctx: *context.ScriptContext, dt: f32) void {
    // 获取用户数据
    const data = ctx.getUserData(CameraData) orelse {
        ctx.error("CameraData not found");
        return;
    };
    
    // 获取Transform
    const transform = ctx.getTransform() orelse {
        ctx.error("Failed to get transform");
        return;
    };
    
    // ===== 键盘移动 =====
    var velocity = [3]f32{ 0, 0, 0 };
    
    // W/S - 前后移动
    if (ctx.isKeyDown(input_mod.Key.w)) {
        velocity[0] += transform.rotation[0] * data.move_speed * dt;
        velocity[2] += transform.rotation[2] * data.move_speed * dt;
    }
    if (ctx.isKeyDown(input_mod.Key.s)) {
        velocity[0] -= transform.rotation[0] * data.move_speed * dt;
        velocity[2] -= transform.rotation[2] * data.move_speed * dt;
    }
    
    // A/D - 左右移动
    if (ctx.isKeyDown(input_mod.Key.a)) {
        // 右向量 = 前向量 x 上向量
        const right_x = transform.rotation[1] * transform.rotation[2] - transform.rotation[2] * transform.rotation[1];
        const right_z = transform.rotation[2] * transform.rotation[0] - transform.rotation[0] * transform.rotation[2];
        velocity[0] -= right_x * data.move_speed * dt;
        velocity[2] -= right_z * data.move_speed * dt;
    }
    if (ctx.isKeyDown(input_mod.Key.d)) {
        const right_x = transform.rotation[1] * transform.rotation[2] - transform.rotation[2] * transform.rotation[1];
        const right_z = transform.rotation[2] * transform.rotation[0] - transform.rotation[0] * transform.rotation[2];
        velocity[0] += right_x * data.move_speed * dt;
        velocity[2] += right_z * data.move_speed * dt;
    }
    
    // Q/E - 上下移动
    if (ctx.isKeyDown(input_mod.Key.q)) {
        velocity[1] -= data.move_speed * dt;
    }
    if (ctx.isKeyDown(input_mod.Key.e)) {
        velocity[1] += data.move_speed * dt;
    }
    
    // 应用移动
    const current_pos = ctx.getPosition() orelse [3]f32{ 0, 0, 0 };
    ctx.setPosition(.{
        current_pos[0] + velocity[0],
        current_pos[1] + velocity[1],
        current_pos[2] + velocity[2],
    });
    
    // ===== 鼠标视角控制 =====
    if (ctx.getMousePosition()) |mouse_pos| {
        // 如果是首次获取鼠标，初始化上次位置
        if (data.first_mouse) {
            data.last_mouse_x = mouse_pos[0];
            data.last_mouse_y = mouse_pos[1];
            data.first_mouse = false;
        }
        
        // 计算鼠标Delta
        const delta_x = mouse_pos[0] - data.last_mouse_x;
        const delta_y = data.last_mouse_y - mouse_pos[1]; // Y轴反转
        
        data.last_mouse_x = mouse_pos[0];
        data.last_mouse_y = mouse_pos[1];
        
        // 更新角度
        data.yaw += delta_x * data.mouse_sensitivity;
        data.pitch += delta_y * data.mouse_sensitivity;
        
        // 限制俯仰角
        const max_pitch = 89.0 * std.math.pi / 180.0;
        data.pitch = std.math.clamp(data.pitch, -max_pitch, max_pitch);
        
        // 转换为四元数
        const quat = @import("../../src/engine/math/quat.zig");
        const yaw_quat = quat.fromAxisAngle(.{ 0, 1, 0 }, data.yaw);
        const pitch_quat = quat.fromAxisAngle(.{ 1, 0, 0 }, data.pitch);
        const new_rot = quat.mul(yaw_quat, pitch_quat);
        
        ctx.setRotation(new_rot);
    }
    
    // ===== 时间控制示例 =====
    // 按空格键切换时间缩放
    if (ctx.wasKeyPressed(input_mod.Key.space)) {
        const current_scale = ctx.getTimeScale();
        const new_scale = if (current_scale > 0.5) 0.2 else 1.0;
        ctx.setTimeScale(new_scale);
        ctx.log("Time scale changed to: ", new_scale);
    }
    
    // 按Tab键显示调试信息
    if (ctx.wasKeyPressed(input_mod.Key.tab)) {
        const pos = ctx.getPosition() orelse [3]f32{ 0, 0, 0 };
        const fps = ctx.getFPS();
        ctx.log("Camera pos: ({d:.2}, {d:.2}, {d:.2}), FPS: {d:.1}, Time: {d:.2}", .{
            pos[0], pos[1], pos[2], fps, ctx.getTime()
        });
    }
}

/// OnDestroy - 脚本销毁
pub fn onDestroy(ctx: *context.ScriptContext) void {
    // 释放用户数据
    if (ctx.getUserData(CameraData)) |data| {
        ctx.allocator.destroy(data);
    }
    ctx.log("Fly camera script destroyed");
}

/// 导出脚本虚拟表
pub const script_vtable = script.types.ScriptVTable{
    .onInit = onInit,
    .onUpdate = onUpdate,
    .onDestroy = onDestroy,
};
