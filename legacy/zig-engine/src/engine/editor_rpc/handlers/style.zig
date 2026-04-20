///! handlers/style.zig — render style inspection and parameter editing.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

pub fn getActiveStyle(ctx: *Ctx) !void {
    const style_reg = ctx.layer.renderer.styleRegistry();
    const active = style_reg.getActiveStyle();

    const ParamSchema = struct {
        name: []const u8,
        displayName: []const u8,
        paramType: []const u8,
        defaultValue: f32,
        minValue: f32,
        maxValue: f32,
    };

    var schema_list = std.ArrayList(ParamSchema).empty;
    defer schema_list.deinit(ctx.allocator);

    for (active.config_schema) |param| {
        try schema_list.append(ctx.allocator, .{
            .name = param.name,
            .displayName = if (param.display_name.len > 0) param.display_name else param.name,
            .paramType = @tagName(param.param_type),
            .defaultValue = param.default_value,
            .minValue = param.min_value,
            .maxValue = param.max_value,
        });
    }

    var disabled_list = std.ArrayList([]const u8).empty;
    defer disabled_list.deinit(ctx.allocator);
    for (active.disabled_passes) |pass| {
        try disabled_list.append(ctx.allocator, pass);
    }

    // Gather current parameter values
    const ParamValue = struct {
        name: []const u8,
        value: f32,
    };

    var param_vals = std.ArrayList(ParamValue).empty;
    defer param_vals.deinit(ctx.allocator);

    if (style_reg.getParamValues(active.name)) |pv| {
        for (active.config_schema) |param| {
            try param_vals.append(ctx.allocator, .{
                .name = param.name,
                .value = pv.get(param.name, param.default_value),
            });
        }
    } else |_| {}

    try ctx.reply(.{
        .name = active.name,
        .displayName = if (active.display_name.len > 0) active.display_name else active.name,
        .meshProgram = active.mesh_program,
        .shadowProgram = active.shadow_program,
        .source = @tagName(active.source),
        .path = active.path,
        .disabledPasses = disabled_list.items,
        .configSchema = schema_list.items,
        .paramValues = param_vals.items,
    });
}

pub fn listStyles(ctx: *Ctx) !void {
    const style_reg = ctx.layer.renderer.styleRegistry();

    const StyleInfo = struct {
        name: []const u8,
        displayName: []const u8,
        source: []const u8,
        isActive: bool,
    };

    var items = std.ArrayList(StyleInfo).empty;
    defer items.deinit(ctx.allocator);

    var it = style_reg.styleIterator();
    while (it.next()) |entry| {
        const manifest = entry.value_ptr.*;
        try items.append(ctx.allocator, .{
            .name = manifest.name,
            .displayName = if (manifest.display_name.len > 0) manifest.display_name else manifest.name,
            .source = @tagName(manifest.source),
            .isActive = std.mem.eql(u8, manifest.name, style_reg.active_style_name),
        });
    }

    try ctx.reply(.{ .styles = items.items });
}

pub fn setActiveStyle(ctx: *Ctx) !void {
    const name = try ctx.param([]const u8, "name");
    var style_reg = ctx.layer.renderer.styleRegistry();
    if (!style_reg.setActiveStyle(name)) {
        return error.InvalidArguments;
    }
    ctx.layer.renderer.needs_redraw = true;
    try ctx.reply(.{});
}

pub fn setParam(ctx: *Ctx) !void {
    const style_name = try ctx.param([]const u8, "styleName");
    const param_name = try ctx.param([]const u8, "paramName");
    const value = try ctx.param(f32, "value");

    var style_reg = ctx.layer.renderer.styleRegistry();
    const pv = try style_reg.getParamValues(style_name);
    try pv.set(param_name, value);
    ctx.layer.renderer.needs_redraw = true;
    try ctx.reply(.{});
}
