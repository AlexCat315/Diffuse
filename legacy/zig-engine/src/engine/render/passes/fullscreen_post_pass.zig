const std = @import("std");
const gfx = @import("guava_rhi").gfx;
const render_graph = @import("../render_graph.zig");

pub const FullscreenPostPass = struct {
    pub fn execute(
        allocator: std.mem.Allocator,
        device: *gfx.Device,
        graph: ?*const render_graph.RenderGraph,
        input_resource_id: u32,
        output_resource_id: u32,
    ) !void {
        // V2 prototype: skip GPU submission when no valid render target is bound
        if (output_resource_id == 0) return;
        const sampled_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "fullscreen_post_sampled_layout",
        });

        const pipeline_layout = try device.resolvePipelineLayout(&.{sampled_layout});

        const sampled_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba8_unorm,
            .usage = .{ .sampled = true },
            .label = "fullscreen_post_input",
        });
        defer device.destroyTexture(sampled_tex);

        const sampled_set = try device.createBindingSetCached(sampled_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = sampled_tex } }},
            .label = "fullscreen_post_input_set",
        });

        // Runtime protection: binding set layout must match the pipeline layout slot.
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, sampled_set);

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        if (graph) |g| {
            try g.encodeBarrierPlansToCommandBuffer(allocator, device, &cmd);
        }

        try render_graph.RenderGraph.encodeBarrierTransition(
            &cmd,
            input_resource_id,
            .texture,
            .shader_write,
            .shader_read,
            .graphics,
            .graphics,
        );

        try cmd.encodeBeginRenderPass(.{
            .color_target_id = output_resource_id,
            .depth_target_id = 0,
            .clear_mask = 0,
        });
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = sampled_set.id });
        try cmd.encodeDrawIndexed(.{
            .index_count = 3,
            .instance_count = 1,
            .first_index = 0,
            .vertex_offset = 0,
            .first_instance = 0,
        });
        try cmd.encodeEndRenderPass();

        try device.submitCommandBuffer(.graphics, &cmd, .{});
    }
};
