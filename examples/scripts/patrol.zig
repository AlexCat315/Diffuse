//!guava builtin=patrol speed=2.0 arrival=0.1 loop=true waypoints=0,0,0;2,0,0;2,0,2;0,0,2
const script = @import("../../src/engine/script/script.zig");

/// 巡逻脚本 - 让实体在多个点之间巡逻
pub const PatrolScript = struct {
    /// 移动速度
    speed: f32 = 2.0,
    /// 巡逻点（最多 8 个）
    waypoints: [8][3]f32 = .{
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
    },
    /// 实际使用的巡逻点数量
    waypoint_count: u8 = 0,
    /// 当前目标点索引
    current_waypoint: u8 = 0,
    /// 到达目标的阈值距离
    arrival_threshold: f32 = 0.1,
    /// 是否循环巡逻
    loop: bool = true,
    /// 是否等待
    wait_at_waypoint: bool = false,
    /// 等待时间（秒）
    wait_time: f32 = 1.0,
    /// 当前等待计时器
    wait_timer: f32 = 0.0,
};

/// 脚本入口 - 初始化
pub fn onInit(ctx: *script.ScriptContext) void {
    ctx.log("PatrolScript initialized");

    // 验证巡逻点
    const self = ctx.getUserData(PatrolScript) orelse return;
    if (self.waypoint_count == 0) {
        ctx.warn("No waypoints defined!");
    }
}

/// 脚本入口 - 每帧更新
pub fn onUpdate(ctx: *script.ScriptContext, dt: f32) void {
    const self = ctx.getUserData(PatrolScript) orelse return;

    // 如果正在等待
    if (self.wait_at_waypoint and self.wait_timer > 0) {
        self.wait_timer -= dt;
        return;
    }

    // 获取当前位置
    const current_pos = ctx.getPosition() orelse return;

    // 获取目标点
    const target_idx = self.current_waypoint;
    if (target_idx >= self.waypoint_count) return;

    const target = self.waypoints[target_idx];

    // 计算方向和距离
    const dx = target[0] - current_pos[0];
    const dy = target[1] - current_pos[1];
    const dz = target[2] - current_pos[2];
    const distance = @sqrt(dx * dx + dy * dy + dz * dz);

    // 检查是否到达目标
    if (distance < self.arrival_threshold) {
        // 到达目标点
        if (self.wait_at_waypoint) {
            self.wait_timer = self.wait_time;
        }

        // 移动到下一个点
        self.current_waypoint +%= 1;

        // 如果超出范围
        if (self.current_waypoint >= self.waypoint_count) {
            if (self.loop) {
                self.current_waypoint = 0;
            } else {
                // 停止巡逻
                self.current_waypoint = self.waypoint_count - 1;
                ctx.log("Patrol complete!");
                return;
            }
        }
        return;
    }

    // 移动向目标
    const move_dist = self.speed * dt;
    const t = move_dist / distance;

    const new_pos: [3]f32 = .{
        current_pos[0] + dx * t,
        current_pos[1] + dy * t,
        current_pos[2] + dz * t,
    };

    ctx.setPosition(new_pos);

    // 面向移动方向（简单实现）
    if (dx != 0 or dz != 0) {
        const angle = @atan2(dz, dx);
        // 设置朝向
        _ = angle;
    }
}

/// 脚本入口 - 销毁时调用
pub fn onDestroy(ctx: *script.ScriptContext) void {
    ctx.log("PatrolScript destroyed");
}
