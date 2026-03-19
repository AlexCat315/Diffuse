const std = @import("std");

const Entity = struct {
    vel: ?f32 = null,
};

pub fn main() !void {
    var e = Entity{ .vel = 5.0 };
    if (e.vel) |*v| {
        v.* = 0.0;
    }
    std.debug.print("v: {d}\n", .{e.vel.?});
}
