const std = @import("std");

const Entity = struct {
    id: u64,
    vel: f32,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var entities = std.ArrayList(Entity).init(allocator);
    try entities.append(.{ .id = 2, .vel = 5.0 });

    for (entities.items) |*e| {
        if (e.id == 2) {
            e.vel = 0.0;
        }
    }

    std.debug.print("v: {d}\n", .{entities.items[0].vel});
}
