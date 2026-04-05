///! Subscription state tracking for push notifications.
///!
///! Compares engine state each frame to detect changes and
///! broadcasts JSON-RPC notifications to connected Electron clients.
const std = @import("std");
const core = @import("../core/layer.zig");
const mesh_ops_mod = @import("mesh_ops.zig");

const log = std.log.scoped(.editor_rpc_sub);

// Forward reference to Server (avoid circular import)
const server_mod = @import("server.zig");
const Server = server_mod.Server;

pub const SubscriptionState = struct {
    last_scene_revision: u64 = 0,
    last_selection_hash: u64 = 0,
    last_entity_count: u32 = 0,
    frames_since_metrics: u32 = 0,
    // Mesh edit state tracking
    last_mesh_active: bool = false,
    last_mesh_selection_mode: mesh_ops_mod.SelectionMode = .face,
    last_mesh_entity: ?u64 = null,
    last_mesh_selection_count: u32 = 0,
    last_can_enter_edit_mode: bool = false,
};

/// Check for state changes and broadcast notifications.
/// Called once per frame from Server.processPending().
pub fn checkAndBroadcast(server: *Server, layer_context: *core.LayerContext) !void {
    const state = &server.sub_state;
    const world = layer_context.world;

    // Skip if no clients connected
    if (server.active_client_count.load(.acquire) == 0) return;

    // NOTE: on:viewport.frameReady is broadcast directly from renderer.zig
    // right after blitSharedTexture/waitForGpu, NOT here. This ensures the
    // notification reaches the editor during the inter-frame safe window.

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

    // ── Mesh edit state changes ────────────────────────────────
    if (server.mesh_ops) |ops| {
        const snap = ops.getSnapshot(ops.state_ptr, layer_context);

        const changed = (snap.active != state.last_mesh_active) or
            (snap.selection_mode != state.last_mesh_selection_mode) or
            (snap.entity_id != state.last_mesh_entity) or
            (snap.selection_count != state.last_mesh_selection_count) or
            (snap.can_enter_edit_mode != state.last_can_enter_edit_mode);

        if (changed) {
            state.last_mesh_active = snap.active;
            state.last_mesh_selection_mode = snap.selection_mode;
            state.last_mesh_entity = snap.entity_id;
            state.last_mesh_selection_count = snap.selection_count;
            state.last_can_enter_edit_mode = snap.can_enter_edit_mode;

            const mode_str: []const u8 = if (snap.mode_edit) "edit" else "object";
            const sel_mode_str: []const u8 = switch (snap.selection_mode) {
                .vertex => "vertex",
                .edge => "edge",
                .face => "face",
            };
            const notification = try buildNotification(
                server.allocator,
                "on:mesh.stateChanged",
                .{
                    .active = snap.active,
                    .mode = mode_str,
                    .selectionMode = sel_mode_str,
                    .selectionCount = @as(u64, snap.selection_count),
                    .canEnterEditMode = snap.can_enter_edit_mode,
                    .entityId = snap.entity_id,
                },
            );
            server.broadcast(notification);
        }
    }

    // ── Entity count changes ──────────────────────────────────
    const entity_count: u32 = @intCast(world.entities.items.len);
    if (entity_count != state.last_entity_count) {
        state.last_entity_count = entity_count;
        // Scene change notification already covers this via revision
    }

    // ── Console log entries (batched into one notification) ───
    var log_buf: [64]server_mod.ConsoleLogEntry = undefined;
    const log_count = server.drainConsoleLogs(&log_buf);
    if (log_count > 0) {
        // Build batched notification: {"jsonrpc":"2.0","method":"on:console.logs","params":{"entries":[...]}}
        var batch_buf_arr = std.ArrayList(u8).empty;
        defer batch_buf_arr.deinit(server.allocator);
        {
            var w = batch_buf_arr.writer(server.allocator);
            var tmp: [4096]u8 = undefined;
            var adapter = w.adaptToNewApi(&tmp);
            try adapter.new_interface.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"on:console.logs\",\"params\":{\"entries\":[");
            for (log_buf[0..log_count], 0..) |entry, i| {
                if (i > 0) try adapter.new_interface.writeAll(",");
                try adapter.new_interface.writeAll("{\"level\":\"");
                try adapter.new_interface.writeAll(entry.level[0..entry.level_len]);
                try adapter.new_interface.writeAll("\",\"message\":\"");
                // Escape JSON special chars in message
                for (entry.message[0..entry.message_len]) |ch| {
                    switch (ch) {
                        '"' => try adapter.new_interface.writeAll("\\\""),
                        '\\' => try adapter.new_interface.writeAll("\\\\"),
                        '\n' => try adapter.new_interface.writeAll("\\n"),
                        '\r' => try adapter.new_interface.writeAll("\\r"),
                        '\t' => try adapter.new_interface.writeAll("\\t"),
                        else => {
                            const byte: [1]u8 = .{ch};
                            try adapter.new_interface.writeAll(&byte);
                        },
                    }
                }
                try adapter.new_interface.writeAll("\"");
                if (entry.source_len > 0) {
                    try adapter.new_interface.writeAll(",\"source\":\"");
                    try adapter.new_interface.writeAll(entry.source[0..entry.source_len]);
                    try adapter.new_interface.writeAll("\"");
                }
                try adapter.new_interface.writeAll("}");
            }
            try adapter.new_interface.writeAll("]}}");
            try adapter.new_interface.flush();
            if (adapter.err) |err| return err;
        }
        const owned = try batch_buf_arr.toOwnedSlice(server.allocator);
        server.broadcast(owned);
    }

    // ── Viewport metrics (FPS, draw calls, triangles) ──────────
    // Use stack buffer to avoid per-broadcast heap allocation.
    // Interval of 60 frames (~1s @ 60fps) to minimise main-thread overhead.
    state.frames_since_metrics += 1;
    if (state.frames_since_metrics >= 60) {
        state.frames_since_metrics = 0;
        const renderer = layer_context.renderer;
        const report = renderer.last_frame_report;
        const delay_ms = renderer.current_frame_delay_ms;
        const fps: f64 = if (layer_context.delta_seconds > 0)
            1.0 / @as(f64, layer_context.delta_seconds)
        else
            0.0;
        const frame_time_ms: f64 = @as(f64, layer_context.delta_seconds) * 1000.0;

        var stack_buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(
            &stack_buf,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"on:viewport.metrics\",\"params\":{{\"fps\":{d},\"frameTimeMs\":{d},\"drawCalls\":{d},\"triangles\":{d},\"frameDelayMs\":{d}}}}}",
            .{
                @as(u32, @intFromFloat(@min(fps, 9999.0))),
                @as(u32, @intFromFloat(@min(frame_time_ms + 0.5, 9999.0))),
                @as(u32, @intCast(@min(report.draw_calls, std.math.maxInt(u32)))),
                @as(u32, @intCast(@min(report.triangles_drawn, std.math.maxInt(u32)))),
                delay_ms,
            },
        ) catch unreachable;
        // Copy to heap for broadcast queue (single allocation)
        const owned = server.allocator.dupe(u8, json) catch return;
        server.broadcast(owned);
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
