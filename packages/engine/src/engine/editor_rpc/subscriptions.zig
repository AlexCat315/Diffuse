///! Subscription state tracking for push notifications.
///!
///! Compares engine state each frame to detect changes and
///! broadcasts JSON-RPC notifications to connected Electron clients.
const std = @import("std");
const core = @import("../core/layer.zig");

const log = std.log.scoped(.editor_rpc_sub);

// Forward reference to Server (avoid circular import)
const server_mod = @import("server.zig");
const Server = server_mod.Server;

pub const SubscriptionState = struct {
    last_scene_revision: u64 = 0,
    last_selection_hash: u64 = 0,
    last_entity_count: u32 = 0,
    frames_since_metrics: u32 = 0,
};

/// Check for state changes and broadcast notifications.
/// Called once per frame from Server.processPending().
pub fn checkAndBroadcast(server: *Server, layer_context: *core.LayerContext) !void {
    const state = &server.sub_state;
    const world = layer_context.world;

    // Skip if no clients connected
    if (server.active_client_count.load(.acquire) == 0) return;

    // ── Scene changes ──────────────────────────────────────────
    const current_revision = world.sceneRevision();
    if (current_revision != state.last_scene_revision) {
        state.last_scene_revision = current_revision;

        const notification = try buildNotification(
            server.allocator,
            "on:scene.changed",
            .{ .revision = current_revision },
        );
        server.broadcast(notification);
    }

    // ── Selection changes ──────────────────────────────────────
    const selected = layer_context.renderer.selectedEntity();
    const multi_selected = layer_context.renderer.selectedEntities();
    const sel_hash = computeSelectionHash(selected, multi_selected);
    if (sel_hash != state.last_selection_hash) {
        state.last_selection_hash = sel_hash;

        // Build entity ID array
        var ids_buf: [128]u64 = undefined;
        var id_count: usize = 0;
        if (selected) |id| {
            ids_buf[0] = id;
            id_count = 1;
        }
        for (multi_selected) |id| {
            if (id_count < ids_buf.len) {
                ids_buf[id_count] = id;
                id_count += 1;
            }
        }

        const notification = try buildNotification(
            server.allocator,
            "on:selection.changed",
            .{ .entityIds = ids_buf[0..id_count] },
        );
        server.broadcast(notification);
    }

    // ── Entity count changes ──────────────────────────────────
    const entity_count: u32 = @intCast(world.entities.items.len);
    if (entity_count != state.last_entity_count) {
        state.last_entity_count = entity_count;
        // Scene change notification already covers this via revision
    }

    // ── Console log entries ────────────────────────────────────
    var log_buf: [64]server_mod.ConsoleLogEntry = undefined;
    const log_count = server.drainConsoleLogs(&log_buf);
    for (log_buf[0..log_count]) |entry| {
        const notification = try buildNotification(
            server.allocator,
            "on:console.log",
            .{
                .level = entry.level[0..entry.level_len],
                .message = entry.message[0..entry.message_len],
                .source = if (entry.source_len > 0) entry.source[0..entry.source_len] else null,
            },
        );
        server.broadcast(notification);
    }
}

fn computeSelectionHash(primary: ?u64, multi: []const u64) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const pval: u64 = if (primary) |id| @intCast(id) else 0;
    hasher.update(std.mem.asBytes(&pval));
    const count: u64 = @intCast(multi.len);
    hasher.update(std.mem.asBytes(&count));
    for (multi) |id| {
        const v: u64 = @intCast(id);
        hasher.update(std.mem.asBytes(&v));
    }
    return hasher.final();
}

fn buildNotification(allocator: std.mem.Allocator, method: []const u8, params: anytype) ![]u8 {
    // First serialize params
    var params_buf = std.ArrayList(u8).empty;
    defer params_buf.deinit(allocator);
    {
        var pw = params_buf.writer(allocator);
        var ptmp: [4096]u8 = undefined;
        var padapter = pw.adaptToNewApi(&ptmp);
        try std.json.Stringify.value(params, .{}, &padapter.new_interface);
        try padapter.new_interface.flush();
        if (padapter.err) |err| return err;
    }

    // Build the full notification JSON
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    {
        var w = buf.writer(allocator);
        var tmp: [256]u8 = undefined;
        var adapter = w.adaptToNewApi(&tmp);
        try adapter.new_interface.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"");
        try adapter.new_interface.writeAll(method);
        try adapter.new_interface.writeAll("\",\"params\":");
        try adapter.new_interface.writeAll(params_buf.items);
        try adapter.new_interface.writeAll("}");
        try adapter.new_interface.flush();
        if (adapter.err) |err| return err;
    }

    return try buf.toOwnedSlice(allocator);
}
