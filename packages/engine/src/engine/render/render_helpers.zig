const std = @import("std");
const io_globals = @import("io_globals");
const rhi_mod = @import("../rhi/device.zig");
const mesh_pass_mod = @import("passes/mesh_pass.zig");
const graph_mod = @import("render_graph.zig");

/// Execute a render pass with timing and stat recording.
/// Encapsulates the begin → draw → record stats → end pattern from Hazel's
/// SceneRenderer, reducing boilerplate in drawFrame().
pub fn executePass(
    rhi: *rhi_mod.RhiDevice,
    frame: rhi_mod.Frame,
    desc: rhi_mod.RenderPassDesc,
    graph: *graph_mod.RenderGraph,
    pass_stats: []graph_mod.PassStat,
    pass_id: graph_mod.PassId,
    draw_stats: *mesh_pass_mod.DrawStats,
    drawFn: *const fn (*rhi_mod.RhiDevice, rhi_mod.Frame, rhi_mod.RenderPass) mesh_pass_mod.DrawStats,
) !void {
    const render_pass = try rhi.beginRenderPassWithDesc(frame, desc);
    const start = std.Io.Timestamp.now(io_globals.global_io, .boot).nanoseconds;
    const stats = drawFn(rhi, frame, render_pass);
    graph.recordPassStat(pass_stats, pass_id, durationNs(start, std.Io.Timestamp.now(io_globals.global_io, .boot).nanoseconds), stats.draw_calls, stats.triangles_drawn);
    draw_stats.add(stats);
    rhi.endRenderPass(render_pass);
}

fn durationNs(start: i96, end: i96) u64 {
    return @intCast(@max(0, end - start));
}

/// Common render pass descriptors following Hazel's named RenderPass pattern.
/// Instead of constructing inline descriptors at each call site, passes
/// declare their descriptor configuration here.
pub const PassDescriptors = struct {
    pub fn shadowOnly(depth_texture: *const rhi_mod.Texture) rhi_mod.RenderPassDesc {
        return .{
            .color = .{ .target = .none, .load_op = .dont_care, .store_op = .dont_care },
            .depth = .{
                .texture = depth_texture,
                .clear_depth = 1.0,
                .load_op = .clear,
                .store_op = .store,
            },
        };
    }

    pub fn depthOnly(depth: rhi_mod.DepthAttachmentDesc) rhi_mod.RenderPassDesc {
        return .{
            .color = .{ .target = .none, .load_op = .dont_care, .store_op = .dont_care },
            .depth = depth,
        };
    }

    pub fn idPass(id_texture: *const rhi_mod.Texture, depth: ?rhi_mod.DepthAttachmentDesc) rhi_mod.RenderPassDesc {
        return .{
            .color = .{
                .target = .{ .texture = id_texture },
                .clear_color = .{ 0.0, 0.0, 0.0, 0.0 },
                .load_op = .clear,
                .store_op = .store,
            },
            .depth = depth,
        };
    }

    pub fn colorWithDepth(target: rhi_mod.ColorTarget, clear_color: [4]f32, depth: ?rhi_mod.DepthAttachmentDesc) rhi_mod.RenderPassDesc {
        return .{
            .color = .{
                .target = target,
                .clear_color = clear_color,
                .load_op = .clear,
                .store_op = .store,
            },
            .depth = depth,
        };
    }

    pub fn postProcess(target: rhi_mod.ColorTarget) rhi_mod.RenderPassDesc {
        return .{
            .color = .{
                .target = target,
                .clear_color = .{ 0.0, 0.0, 0.0, 1.0 },
                .load_op = .clear,
                .store_op = .store,
            },
            .depth = null,
        };
    }

    pub fn overlay(target: rhi_mod.ColorTarget) rhi_mod.RenderPassDesc {
        return .{
            .color = .{
                .target = target,
                .load_op = .load,
                .store_op = .store,
            },
            .depth = null,
        };
    }

    pub fn overlayWithDepth(target: rhi_mod.ColorTarget, depth: rhi_mod.DepthAttachmentDesc) rhi_mod.RenderPassDesc {
        return .{
            .color = .{
                .target = target,
                .load_op = .load,
                .store_op = .store,
            },
            .depth = depth,
        };
    }
};
