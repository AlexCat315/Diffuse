//! Coin Collector — 硬币拾取脚本
//! 挂载到带 is_trigger=true 碰撞体的实体上
const guava = @import("guava");
const std = @import("std");

var collected: bool = false;

export fn guava_on_update(dt: f32) callconv(.c) void {
    _ = dt;
    if (collected) return;
    // 简单旋转动画：让硬币绕 Y 轴旋转
    const t = guava.time();
    const half_angle = t * 1.5; // 旋转速度
    guava.setRotation(.{ 0, @sin(half_angle), 0, @cos(half_angle) });
}

export fn guava_on_trigger_enter(other: u64) callconv(.c) void {
    _ = other;
    if (collected) return;
    collected = true;

    // 读取当前分数并加 1
    const score_str = guava.blackboardGet("score") orelse "0";
    var score: u32 = 0;
    for (score_str) |c| {
        if (c >= '0' and c <= '9') {
            score = score * 10 + (c - '0');
        } else break;
    }
    score += 1;

    // 写回分数（最多 3 位数足够）
    var buf: [16]u8 = undefined;
    const len = formatU32(score, &buf);
    guava.blackboardSet("score", buf[0..len]);

    guava.log("Coin collected!");
    // 销毁自身
    guava.destroyEntity(guava.entityId());
}

fn formatU32(val: u32, buf: []u8) usize {
    if (val == 0) {
        buf[0] = '0';
        return 1;
    }
    var v = val;
    var i: usize = 0;
    while (v > 0 and i < buf.len) : (i += 1) {
        buf[i] = @intCast(v % 10 + '0');
        v /= 10;
    }
    // 反转
    var lo: usize = 0;
    var hi: usize = i - 1;
    while (lo < hi) {
        const tmp = buf[lo];
        buf[lo] = buf[hi];
        buf[hi] = tmp;
        lo += 1;
        hi -= 1;
    }
    return i;
}
