//! Guava Engine 碰撞驱动游戏逻辑示例
//!
//! 演示如何用 dylib 脚本：
//! 1. 响应碰撞事件
//! 2. 使用射线检测 (raycast)
//! 3. 操作物理速度和冲量
//! 4. 加载新场景
//!
//! 挂载到任意实体上即可运行。

const guava = @import("guava");

var score: u32 = 0;
var health: f32 = 100.0;

export fn guava_on_init() callconv(.c) void {
    guava.log("Game logic script initialized");
}

export fn guava_on_update(dt: f32) callconv(.c) void {
    _ = dt;
    const eid = guava.entityId();

    // 每帧做一次向下射线检测，判断脚下是否有地面
    const pos = guava.getPosition();
    if (guava.raycast(pos, .{ 0, -1, 0 }, 2.0)) |hit| {
        _ = hit; // 脚下有碰撞体
    }

    // 按 F 键对自身实体施加向上冲量
    if (guava.wasKeyPressed(.f)) {
        guava.addImpulse(eid, .{ 0, 500, 0 });
    }

    // 滚轮缩放示例
    const wheel = guava.getMouseWheel();
    if (wheel[1] != 0) {
        var scale = guava.getScale();
        const factor = 1.0 + wheel[1] * 0.1;
        scale[0] *= factor;
        scale[1] *= factor;
        scale[2] *= factor;
        guava.setScale(scale);
    }
}

export fn guava_on_collision_enter(other: u64) callconv(.c) void {
    score += 1;
    _ = other;
    guava.log("Score+1!");

    // 示例：碰撞后将对方弹飞
    // guava.addImpulse(other, .{ 0, 300, 0 });
}

export fn guava_on_collision_exit(other: u64) callconv(.c) void {
    _ = other;
}

export fn guava_on_trigger_enter(other: u64) callconv(.c) void {
    _ = other;
    // 进入触发区域时切换到下一关
    guava.loadScene("assets/scenes/level_2.guava_scene");
}

export fn guava_on_destroy() callconv(.c) void {
    guava.log("Game logic script destroyed");
}
