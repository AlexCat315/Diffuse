///! handlers/console.zig — log retrieval & management.
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

pub fn clear(ctx: *Ctx) !void {
    // Log buffer lives Electron-side; engine acknowledges.
    try ctx.reply(.{});
}
