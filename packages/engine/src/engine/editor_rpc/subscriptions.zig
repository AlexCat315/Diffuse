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
    // Playback state tracking
    last_playback_state: core.PlaybackState = .stopped,
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

    // ── Playback state changes ────────────────────────────────
    const current_playback = layer_context.playback_controller.state;
    if (current_playback != state.last_playback_state) {
        state.last_playback_state = current_playback;
        const state_str: []const u8 = switch (current_playback) {
            .stopped => "stopped",
            .playing => "playing",
            .paused => "paused",
        };
        const notification = try buildNotification(
            server.allocator,
            "on:playback.stateChanged",
            .{ .state = state_str },
        );
        server.broadcast(notification);
    }

    // ── Console log entries (batched into one notification) ───
    var log_buf: [64]server_mod.ConsoleLogEntry = undefined;
    const log_count = server.drainConsoleLogs(&log_buf);
    if (log_count > 0) {
        // Build batched notification: {"jsonrpc":"2.0","method":"on:console.logs","params":{"entries":[...]}}
        var batch_writer: std.Io.Writer.Allocating = .init(server.allocator);
        errdefer batch_writer.deinit();
        {
            const w = &batch_writer.writer;
            try w.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"on:console.logs\",\"params\":{\"entries\":[");
            for (log_buf[0..log_count], 0..) |entry, i| {
                if (i > 0) try w.writeAll(",");
                try w.writeAll("{\"level\":\"");
                try w.writeAll(entry.level[0..entry.level_len]);
                try w.writeAll("\",\"message\":\"");
                // Escape JSON special chars in message
                for (entry.message[0..entry.message_len]) |ch| {
                    switch (ch) {
                        '"' => try w.writeAll("\\\""),
                        '\\' => try w.writeAll("\\\\"),
                        '\n' => try w.writeAll("\\n"),
                        '\r' => try w.writeAll("\\r"),
                        '\t' => try w.writeAll("\\t"),
                        else => {
                            const byte: [1]u8 = .{ch};
                            try w.writeAll(&byte);
                        },
                    }
                }
                try w.writeAll("\"");
                if (entry.source_len > 0) {
                    try w.writeAll(",\"source\":\"");
                    try w.writeAll(entry.source[0..entry.source_len]);
                    try w.writeAll("\"");
                }
                try w.writeAll("}");
            }
            try w.writeAll("]}}");
        }
        const owned = try batch_writer.toOwnedSlice();
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
    const params_json = try std.json.Stringify.valueAlloc(allocator, params, .{});
    defer allocator.free(params_json);

    return try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}", .{
        method,
        params_json,
    });
}
