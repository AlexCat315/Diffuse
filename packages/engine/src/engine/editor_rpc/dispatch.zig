///! dispatch.zig — comptime multi-module RPC dispatch.
///!
///! ## Adding a new namespace
///!
///! 1. Create  `handlers/my_namespace.zig`  with `pub fn` handlers.
///! 2. Add one entry to `handler_modules` below.
///! 3. Done — dispatch, capabilities, method names are all auto-generated.
///!
///! ## Adding a method to an existing namespace
///!
///! Just add a `pub fn` to the handler file.  Nothing else to touch.
const std = @import("std");
const core = @import("../core/layer.zig");
const ctx_mod = @import("ctx.zig");
const Ctx = ctx_mod.Ctx;

const log = std.log.scoped(.editor_rpc);

// ═══════════════════════════════════════════════════════════════════
//  Handler module registry — ONE LINE PER NAMESPACE
// ═══════════════════════════════════════════════════════════════════

const HandlerModule = struct {
    prefix: []const u8,
    mod: type,
};

const handler_modules = [_]HandlerModule{
    .{ .prefix = "editor", .mod = @import("handlers/editor.zig") },
    .{ .prefix = "scene", .mod = @import("handlers/scene.zig") },
    .{ .prefix = "entity", .mod = @import("handlers/entity.zig") },
    .{ .prefix = "playback", .mod = @import("handlers/playback.zig") },
    .{ .prefix = "viewport", .mod = @import("handlers/viewport.zig") },
    .{ .prefix = "console", .mod = @import("handlers/console.zig") },
    .{ .prefix = "assets", .mod = @import("handlers/assets.zig") },
    .{ .prefix = "camera", .mod = @import("handlers/camera.zig") },
    .{ .prefix = "debug", .mod = @import("handlers/debug.zig") },
    .{ .prefix = "audio", .mod = @import("handlers/audio.zig") },
    .{ .prefix = "plugin", .mod = @import("handlers/plugin.zig") },
    .{ .prefix = "style", .mod = @import("handlers/style.zig") },
    .{ .prefix = "renderqueue", .mod = @import("handlers/renderqueue.zig") },
    .{ .prefix = "physicsviz", .mod = @import("handlers/physics_viz.zig") },
    .{ .prefix = "utilities", .mod = @import("handlers/utilities.zig") },
    .{ .prefix = "rendersettings", .mod = @import("handlers/rendersettings.zig") },
    .{ .prefix = "material", .mod = @import("handlers/material.zig") },
    .{ .prefix = "sequencer", .mod = @import("handlers/sequencer.zig") },
    .{ .prefix = "animation", .mod = @import("handlers/animation.zig") },
};

// Subscriptions (push events — detection logic in subscriptions.zig)
const subscriptions = [_][]const u8{
    "on:scene.changed",
    "on:selection.changed",
    "on:console.log",
    "on:viewport.metrics",
};

// ═══════════════════════════════════════════════════════════════════
//  Comptime-generated tables
// ═══════════════════════════════════════════════════════════════════

const total_methods = countAllMethods();

fn countAllMethods() comptime_int {
    var n: comptime_int = 0;
    for (handler_modules) |hm| {
        n += @typeInfo(hm.mod).@"struct".decls.len;
    }
    return n;
}

/// All method names ("namespace.method"), generated at comptime.
pub const method_names: [total_methods][]const u8 = blk: {
    var result: [total_methods][]const u8 = undefined;
    var idx: usize = 0;
    for (handler_modules) |hm| {
        for (@typeInfo(hm.mod).@"struct".decls) |decl| {
            result[idx] = hm.prefix ++ "." ++ decl.name;
            idx += 1;
        }
    }
    break :blk result;
};

pub const subscription_names = subscriptions;

// ═══════════════════════════════════════════════════════════════════
//  Dispatch — inline-for over all modules × their declarations
// ═══════════════════════════════════════════════════════════════════

fn dispatchToHandler(method_str: []const u8, ctx: *Ctx) !void {
    inline for (handler_modules) |hm| {
        // Quick prefix check to short-circuit non-matching namespaces.
        if (method_str.len > hm.prefix.len and
            method_str[hm.prefix.len] == '.' and
            std.mem.eql(u8, method_str[0..hm.prefix.len], hm.prefix))
        {
            const fn_name = method_str[hm.prefix.len + 1 ..];
            inline for (@typeInfo(hm.mod).@"struct".decls) |decl| {
                if (std.mem.eql(u8, fn_name, decl.name)) {
                    return @field(hm.mod, decl.name)(ctx);
                }
            }
        }
    }
    return error.MethodNotFound;
}

// ═══════════════════════════════════════════════════════════════════
//  Public API — called from server.zig
// ═══════════════════════════════════════════════════════════════════

pub fn dispatch(allocator: std.mem.Allocator, payload: []const u8, layer_context: *core.LayerContext) !?[]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch {
        return try errorResponse(allocator, null, -32700, "Parse error");
    };
    defer parsed.deinit();

    const root = parsed.value;
    const obj = switch (root) {
        .object => |o| o,
        else => return try errorResponse(allocator, null, -32600, "Invalid Request"),
    };

    const method_str = switch (obj.get("method") orelse return try errorResponse(allocator, null, -32600, "Missing method")) {
        .string => |s| s,
        else => return try errorResponse(allocator, null, -32600, "Method must be string"),
    };

    const id_val = obj.get("id");
    const params = obj.get("params");

    // Notifications (no id) — fire-and-forget
    if (id_val == null) {
        log.debug("Notification: {s}", .{method_str});
        return null;
    }

    var ctx = Ctx{
        .allocator = allocator,
        .params = params,
        .layer = layer_context,
    };

    dispatchToHandler(method_str, &ctx) catch |err| {
        return try errorResponse(allocator, id_val, if (err == error.MethodNotFound) @as(i64, -32601) else -32603, @errorName(err));
    };

    return try successResponse(allocator, id_val, ctx._result orelse try ctx_mod.json(allocator, .{}));
}

// ═══════════════════════════════════════════════════════════════════
//  JSON-RPC response builders
// ═══════════════════════════════════════════════════════════════════

fn successResponse(allocator: std.mem.Allocator, id: ?std.json.Value, result_json: []u8) ![]u8 {
    defer allocator.free(result_json);
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var writer = buf.writer(allocator);
    var tmp: [256]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    const w = &adapter.new_interface;

    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonId(w, id);
    try w.writeAll(",\"result\":");
    try w.writeAll(result_json);
    try w.writeAll("}");
    try w.flush();
    if (adapter.err) |err| return err;
    return try buf.toOwnedSlice(allocator);
}

fn errorResponse(allocator: std.mem.Allocator, id: ?std.json.Value, code: i64, message: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    var writer = buf.writer(allocator);
    var tmp: [256]u8 = undefined;
    var adapter = writer.adaptToNewApi(&tmp);
    const w = &adapter.new_interface;

    try w.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonId(w, id);
    try w.print(",\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}", .{ code, message });
    try w.flush();
    if (adapter.err) |err| return err;
    return try buf.toOwnedSlice(allocator);
}

fn writeJsonId(w: anytype, id: ?std.json.Value) !void {
    if (id) |id_val| {
        switch (id_val) {
            .integer => |i| try w.print("{d}", .{i}),
            .string => |s| {
                try w.writeAll("\"");
                try w.writeAll(s);
                try w.writeAll("\"");
            },
            else => try w.writeAll("null"),
        }
    } else {
        try w.writeAll("null");
    }
}
