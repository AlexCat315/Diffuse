///! RPC schema aggregation module.
///!
///! Re-exports all schema sub-modules so that gen_types.zig and other
///! consumers have a single import point.
///!
///! AI tool exposure: add `pub const ai_tool: types.AiTool = .{ ... };`
///! inside any method struct to expose it. gen_types.zig will auto-collect.
pub const types = @import("types.zig");
pub const subscriptions = @import("subscriptions.zig");

/// Comptime tuple of all method modules.  gen_types.zig iterates this
/// with `inline for` to emit every RPC method signature.
pub const method_modules = .{
    @import("core.zig"),
    @import("viewport.zig"),
    @import("content.zig"),
    @import("material.zig"),
    @import("rendering.zig"),
    @import("animation.zig"),
    @import("mesh.zig"),
    @import("collaboration.zig"),
};

test {
    _ = @import("types.zig");
    _ = @import("core.zig");
    _ = @import("viewport.zig");
    _ = @import("content.zig");
    _ = @import("material.zig");
    _ = @import("rendering.zig");
    _ = @import("animation.zig");
    _ = @import("mesh.zig");
    _ = @import("collaboration.zig");
    _ = @import("subscriptions.zig");
}
