const std = @import("std");
const io_globals = @import("io_globals");
const gfx_mod = @import("gfx/mod.zig");
const mesh_pass_mod = @import("passes/mesh_pass.zig");
const graph_mod = @import("render_graph.zig");

/// Execute a render pass with timing and stat recording.
/// Encapsulates the begin → draw → record stats → end pattern from Hazel's
/// SceneRenderer, reducing boilerplate in drawFrame().
pub fn executePass(
    gfx: *gfx_mod.GfxDevice,
    frame: gfx_mod.Frame,
    desc: gfx_mod.RenderPassDesc,
    graph: *graph_mod.RenderGraph,
    pass_stats: []graph_mod.PassStat,
    pass_id: graph_mod.PassId,
    draw_stats: *mesh_pass_mod.DrawStats,
    drawFn: *const fn (*gfx_mod.GfxDevice, gfx_mod.Frame, gfx_mod.RenderPass) mesh_pass_mod.DrawStats,
) !void {
    const render_pass = try gfx.beginRenderPassWithDesc(frame, desc);
    const start = std.Io.Timestamp.now(io_globals.global_io, .boot).nanoseconds;
    const stats = drawFn(gfx, frame, render_pass);
    graph.recordPassStat(pass_stats, pass_id, durationNs(start, std.Io.Timestamp.now(io_globals.global_io, .boot).nanoseconds), stats.draw_calls, stats.triangles_drawn);
    draw_stats.add(stats);
    gfx.endRenderPass(render_pass);
}

fn durationNs(start: i96, end: i96) u64 {
    return @intCast(@max(0, end - start));
}

/// Common render pass descriptors following Hazel's named RenderPass pattern.
/// Instead of constructing inline descriptors at each call site, passes
/// declare their descriptor configuration here.
pub const PassDescriptors = struct {
    pub fn shadowOnly(depth_texture: *const gfx_mod.Texture) gfx_mod.RenderPassDesc {
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

    pub fn depthOnly(depth: gfx_mod.DepthAttachmentDesc) gfx_mod.RenderPassDesc {
        return .{
            .color = .{ .target = .none, .load_op = .dont_care, .store_op = .dont_care },
            .depth = depth,
        };
    }

    pub fn idPass(id_texture: *const gfx_mod.Texture, depth: ?gfx_mod.DepthAttachmentDesc) gfx_mod.RenderPassDesc {
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

    pub fn colorWithDepth(target: gfx_mod.ColorTarget, clear_color: [4]f32, depth: ?gfx_mod.DepthAttachmentDesc) gfx_mod.RenderPassDesc {
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

    pub fn postProcess(target: gfx_mod.ColorTarget) gfx_mod.RenderPassDesc {
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

    pub fn overlay(target: gfx_mod.ColorTarget) gfx_mod.RenderPassDesc {
        return .{
            .color = .{
                .target = target,
                .load_op = .load,
                .store_op = .store,
            },
            .depth = null,
        };
    }

    pub fn overlayWithDepth(target: gfx_mod.ColorTarget, depth: gfx_mod.DepthAttachmentDesc) gfx_mod.RenderPassDesc {
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
