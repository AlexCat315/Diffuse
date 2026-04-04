const std = @import("std");
const layer_mod = @import("layer.zig");

pub const LayerStack = struct {
    allocator: std.mem.Allocator,
    layers: std.ArrayList(layer_mod.Layer) = .empty,
    overlay_start: usize = 0,

    pub fn init(allocator: std.mem.Allocator) LayerStack {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *LayerStack) void {
        self.layers.deinit(self.allocator);
    }

    pub fn pushLayer(self: *LayerStack, layer: layer_mod.Layer) !void {
        try self.layers.insert(self.allocator, self.overlay_start, layer);
        self.overlay_start += 1;
    }

    pub fn pushOverlay(self: *LayerStack, overlay: layer_mod.Layer) !void {
        try self.layers.append(self.allocator, overlay);
    }
};

test "layers stay below overlays" {
    var stack = LayerStack.init(std.testing.allocator);
    defer stack.deinit();

    var marker: u8 = 0;
    try stack.pushLayer(.{ .name = "Gameplay", .context = &marker });
    try stack.pushLayer(.{ .name = "Editor", .context = &marker });
    try stack.pushOverlay(.{ .name = "Overlay", .context = &marker });

    try std.testing.expectEqual(@as(usize, 3), stack.layers.items.len);
    try std.testing.expectEqualStrings("Gameplay", stack.layers.items[0].name);
    try std.testing.expectEqualStrings("Editor", stack.layers.items[1].name);
    try std.testing.expectEqualStrings("Overlay", stack.layers.items[2].name);
}
