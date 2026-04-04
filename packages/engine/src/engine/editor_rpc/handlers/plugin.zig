///! handlers/plugin.zig — plugin registry inspection and control.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

pub fn list(ctx: *Ctx) !void {
    const renderer = ctx.layer.renderer;
    const plugin_reg = renderer.pluginRegistry();

    const PluginInfo = struct {
        name: []const u8,
        pluginType: []const u8,
        source: []const u8,
        lifecycle: []const u8,
        lastError: ?[]const u8,
    };

    var items = std.ArrayList(PluginInfo).empty;
    defer items.deinit(ctx.allocator);

    var it = plugin_reg.plugins.iterator();
    while (it.next()) |entry| {
        const record = entry.value_ptr.*;
        try items.append(ctx.allocator, .{
            .name = record.getName(),
            .pluginType = @tagName(record.getType()),
            .source = @tagName(record.getSource()),
            .lifecycle = @tagName(record.lifecycle),
            .lastError = record.last_error,
        });
    }

    try ctx.reply(.{ .plugins = items.items });
}

pub fn enable(ctx: *Ctx) !void {
    const name = try ctx.param([]const u8, "name");
    ctx.layer.renderer.enablePlugin(name);
    try ctx.reply(.{});
}

pub fn disable(ctx: *Ctx) !void {
    const name = try ctx.param([]const u8, "name");
    ctx.layer.renderer.disablePlugin(name);
    try ctx.reply(.{});
}

pub fn unload(ctx: *Ctx) !void {
    const name = try ctx.param([]const u8, "name");
    ctx.layer.renderer.unloadPlugin(name);
    try ctx.reply(.{});
}

pub fn rescan(ctx: *Ctx) !void {
    const path = (try ctx.paramOpt([]const u8, "path")) orelse "project_plugins";
    ctx.layer.renderer.rescanPlugins(path);
    try ctx.reply(.{});
}
