//! Coin Collector — 计分 UI 脚本
//! 挂载到一个空实体（GameManager）上
const guava = @import("guava");

var text_id: u32 = 0;
var win_id: u32 = 0;
var won: bool = false;

export fn guava_on_init() callconv(.c) void {
    // 左上角分数显示
    text_id = guava.canvasAddText(20, 20, 300, 40, "Score: 0 / 5", 255, 255, 255, 255);
    guava.log("Score UI initialized");
}

export fn guava_on_update(dt: f32) callconv(.c) void {
    _ = dt;
    const score_str = guava.blackboardGet("score") orelse "0";
    const total_str = guava.blackboardGet("total") orelse "5";

    // 构造 "Score: X / Y"
    var buf: [64]u8 = undefined;
    var pos: usize = 0;
    pos = appendSlice(&buf, pos, "Score: ");
    pos = appendSlice(&buf, pos, score_str);
    pos = appendSlice(&buf, pos, " / ");
    pos = appendSlice(&buf, pos, total_str);
    guava.canvasSetText(text_id, buf[0..pos]);

    // 检查是否胜利
    if (!won) {
        const score = parseU32(score_str);
        const total = parseU32(total_str);
        if (score >= total and total > 0) {
            won = true;
            win_id = guava.canvasAddText(200, 250, 400, 60, "YOU WIN!", 255, 215, 0, 255);
        }
    }
}

fn appendSlice(buf: []u8, start: usize, s: []const u8) usize {
    var i = start;
    for (s) |c| {
        if (i >= buf.len) break;
        buf[i] = c;
        i += 1;
    }
    return i;
}

fn parseU32(s: []const u8) u32 {
    var v: u32 = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            v = v * 10 + (c - '0');
        } else break;
    }
    return v;
}
