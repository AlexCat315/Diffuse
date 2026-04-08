//! Coin Collector — 玩家移动 + 拾取脚本
//! WASD 移动，距离检测拾取硬币
const guava = @import("guava");

const move_speed: f32 = 8.0;
const pickup_radius: f32 = 1.2;

// 硬币实体 ID 缓存
var coin_ids: [5]u64 = .{ 0, 0, 0, 0, 0 };
var score: u32 = 0;
var total: u32 = 5;
var initialized: bool = false;

export fn guava_on_init() callconv(.c) void {
    guava.log("Player ready — WASD to move, collect all coins!");
    guava.blackboardSet("score", "0");
    guava.blackboardSet("total", "5");
}

export fn guava_on_update(dt: f32) callconv(.c) void {
    // 延迟查找硬币实体（确保场景完全加载）
    if (!initialized) {
        initialized = true;
        coin_ids[0] = guava.findEntityByName("Coin_0");
        coin_ids[1] = guava.findEntityByName("Coin_1");
        coin_ids[2] = guava.findEntityByName("Coin_2");
        coin_ids[3] = guava.findEntityByName("Coin_3");
        coin_ids[4] = guava.findEntityByName("Coin_4");
    }

    // --- 移动 ---
    var pos = guava.getPosition();
    var dx: f32 = 0;
    var dz: f32 = 0;

    if (guava.isKeyDown(.w)) dz -= 1;
    if (guava.isKeyDown(.s)) dz += 1;
    if (guava.isKeyDown(.a)) dx -= 1;
    if (guava.isKeyDown(.d)) dx += 1;

    const len = @sqrt(dx * dx + dz * dz);
    if (len > 0.001) {
        dx = dx / len * move_speed * dt;
        dz = dz / len * move_speed * dt;
    }
    pos[0] += dx;
    pos[2] += dz;
    guava.setPosition(pos);

    // --- 拾取检测 ---
    for (&coin_ids) |*cid| {
        if (cid.* == 0) continue; // 已拾取或无效
        const cp = guava.getPositionOf(cid.*);
        const ddx = pos[0] - cp[0];
        const ddz = pos[2] - cp[2];
        const dist_sq = ddx * ddx + ddz * ddz;
        if (dist_sq < pickup_radius * pickup_radius) {
            // 拾取！
            score += 1;
            var buf: [16]u8 = undefined;
            const slen = formatU32(score, &buf);
            guava.blackboardSet("score", buf[0..slen]);
            guava.log("Coin collected!");
            guava.destroyEntity(cid.*);
            cid.* = 0;
        }
    }
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
