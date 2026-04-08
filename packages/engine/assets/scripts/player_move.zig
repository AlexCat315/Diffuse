//! Coin Collector — 玩家移动脚本
//! WASD 移动，物理驱动
const guava = @import("guava");

const move_speed: f32 = 8.0;

export fn guava_on_init() callconv(.c) void {
    guava.log("Player ready — WASD to move, collect all coins!");
    // 初始化黑板分数为 0
    guava.blackboardSet("score", "0");
    guava.blackboardSet("total", "5");
}

export fn guava_on_update(dt: f32) callconv(.c) void {
    _ = dt;
    const eid = guava.entityId();

    var vx: f32 = 0;
    var vz: f32 = 0;

    if (guava.isKeyDown(.w)) vz -= 1;
    if (guava.isKeyDown(.s)) vz += 1;
    if (guava.isKeyDown(.a)) vx -= 1;
    if (guava.isKeyDown(.d)) vx += 1;

    // 归一化
    const len = @sqrt(vx * vx + vz * vz);
    if (len > 0.001) {
        vx = vx / len * move_speed;
        vz = vz / len * move_speed;
    }

    // 保持当前 Y 速度（重力）
    const cur = guava.getLinearVelocity(eid);
    guava.setLinearVelocity(eid, .{ vx, cur[1], vz });
}
