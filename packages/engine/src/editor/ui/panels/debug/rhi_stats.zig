const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

/// Draw the RHI debug stats overlay panel.
pub fn drawRhiStatsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    var open = state.rhi_stats_open;
    const open_window = gui.beginWindowOpen("RHI Stats###rhi_stats_panel", &open);
    floating_window_blocker.registerCurrentWindow("rhi_stats_panel");
    if (!open_window) {
        gui.endWindow();
        state.rhi_stats_open = open;
        return;
    }
    defer {
        gui.endWindow();
        state.rhi_stats_open = open;
    }

    const renderer = layer_context.renderer;
    const dev = renderer.rhi_device orelse {
        gui.textWrapped("RHI device not initialized.");
        return;
    };

    // ── Binding Cache ──────────────────────────────────────────────
    if (gui.collapsingHeader("Binding Set Cache", true)) {
        const stats = dev.bindingSetCacheStats();
        const entries = dev.bindingSetCacheEntryCount();
        const frame_delta = stats.delta(dev.prev_frame_stats);

        var buf: [128]u8 = undefined;

        const hit_text = std.fmt.bufPrint(&buf, "{d}", .{stats.hits}) catch "?";
        gui.labelText("Hits (total)", hit_text);

        const miss_text = std.fmt.bufPrint(&buf, "{d}", .{stats.misses}) catch "?";
        gui.labelText("Misses (total)", miss_text);

        const rate_text = std.fmt.bufPrint(&buf, "{d:.1}%", .{stats.hitRate() * 100.0}) catch "?";
        gui.labelText("Hit Rate", rate_text);

        const total_text = std.fmt.bufPrint(&buf, "{d}", .{stats.totalLookups()}) catch "?";
        gui.labelText("Total Lookups", total_text);

        const evict_text = std.fmt.bufPrint(&buf, "{d}", .{stats.evictions}) catch "?";
        gui.labelText("Evictions (total)", evict_text);

        const entry_text = std.fmt.bufPrint(&buf, "{d} / 1024", .{entries}) catch "?";
        gui.labelText("Entries", entry_text);

        gui.dummy(0.0, 4.0);
        gui.textColored(.{ 0.6, 0.8, 1.0, 1.0 }, "Per-Frame Delta");

        const dh_text = std.fmt.bufPrint(&buf, "+{d}", .{frame_delta.hits}) catch "?";
        gui.labelText("Hits (frame)", dh_text);

        const dm_text = std.fmt.bufPrint(&buf, "+{d}", .{frame_delta.misses}) catch "?";
        gui.labelText("Misses (frame)", dm_text);

        const de_text = std.fmt.bufPrint(&buf, "+{d}", .{frame_delta.evictions}) catch "?";
        gui.labelText("Evictions (frame)", de_text);

        gui.dummy(0.0, 4.0);
        if (gui.button("Reset Stats")) {
            dev.resetBindingSetCacheStats();
        }
    }

    // ── Slot-Layout Validation ─────────────────────────────────────
    if (gui.collapsingHeader("Slot-Layout Validation", true)) {
        const slot_errors = renderer.graph.validateSlotLayoutConstraints(
            renderer.allocator,
            dev,
        ) catch &.{};
        defer if (slot_errors.len > 0) renderer.allocator.free(slot_errors);

        var err_buf: [128]u8 = undefined;
        const err_text = std.fmt.bufPrint(&err_buf, "{d}", .{slot_errors.len}) catch "?";
        if (slot_errors.len == 0) {
            gui.textColored(.{ 0.2, 0.8, 0.2, 1.0 }, "All constraints OK");
        } else {
            gui.textColored(.{ 1.0, 0.3, 0.3, 1.0 }, err_text);
        }
        gui.labelText("Constraint Errors", err_text);

        for (slot_errors) |se| {
            const detail = std.fmt.bufPrint(&err_buf, "slot={d} expected={d}", .{ se.slot, se.expected_layout_id }) catch "?";
            gui.labelText(se.pass_name, detail);
        }
    }

    // ── RHI Pass Status ───────────────────────────────────────────
    if (gui.collapsingHeader("RHI Pass Status", true)) {
        gui.labelText("SSAO", "compute");
        gui.labelText("FXAA", "RHI");
        gui.labelText("Bloom", "RHI");
        gui.labelText("Tonemap", "RHI");
        gui.labelText("Contact Shadow", "RHI");
        gui.labelText("DOF", "RHI");
        gui.labelText("SSR", "RHI");
        gui.labelText("Volumetric Fog", "RHI");

        gui.dummy(0.0, 4.0);
        gui.textColored(.{ 0.6, 0.8, 1.0, 1.0 }, "Geometry / Misc");
        gui.labelText("Depth Prepass", "RHI");
        gui.labelText("Shadow Pass", "RHI");
        gui.labelText("Outline", "RHI");
        gui.labelText("Skybox", "RHI");
        gui.labelText("TAA", "RHI");
        gui.labelText("IBL Compute", "RHI (BRDF + Irradiance)");

        gui.dummy(0.0, 4.0);
        gui.textColored(.{ 0.6, 0.8, 1.0, 1.0 }, "Final Passes");
        gui.labelText("Gizmo", "RHI (line geometry)");
        gui.labelText("ID Pass", "RHI (entity picking)");
        gui.labelText("Omni Shadow", "RHI (6-face cubemap)");
        gui.labelText("RT Shadow Composite", "RHI (fullscreen multiply)");
        gui.labelText("Base Pass", "RHI (10-set PBR + IBL + CSM)");
    }

    // ── RHI Infrastructure ─────────────────────────────────────────
    if (gui.collapsingHeader("RHI Infrastructure", false)) {
        gui.labelText("Pipeline Creation", "shader + gfx + compute");
        gui.labelText("Sampler", "create + destroy");
        gui.labelText("Buffer Upload", "uploadBufferData");
        gui.labelText("Command Buffer", "encode + decode + submit");
        gui.labelText("Vertex/Index Binding", "set_vertex_buffer + set_index_buffer + set_pipeline");
        gui.labelText("Binding Cache", "FIFO eviction (max 1024)");
        gui.labelText("State Tracker", "barrier + ownership");
    }
}
