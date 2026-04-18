const std = @import("std");
const gfx = @import("guava_gfx").gfx;
const render_graph = @import("../render_graph.zig");

/// Depth-of-Field pass
///
/// Three logical subpasses encoded as a single command buffer submission:
///   Subpass 0 (CoC)       — Binding sets: color texture + depth texture + uniform buffer
///   Subpass 1 (Blur)      — Binding sets: CoC output texture + uniform buffer
///   Subpass 2 (Composite) — Binding sets: original color + blur output + uniform buffer
///
/// Pipeline layout has 3 binding set slots (texture, texture, uniform).
/// The same uniform layout is reused across subpasses.
pub const DOFPass = struct {
    pub const DOFParams = extern struct {
        projection: [16]f32 = std.mem.zeroes([16]f32),
        inv_projection: [16]f32 = std.mem.zeroes([16]f32),
        resolution: [2]f32 = .{ 1.0, 1.0 },
        focus_distance: f32 = 10.0,
        focus_range: f32 = 5.0,
        blur_radius: f32 = 10.0,
        bokeh_radius: f32 = 5.0,
        near_blur: f32 = 0.0,
        far_blur: f32 = 100.0,
        quality: u32 = 4,
        padding: [3]f32 = .{ 0.0, 0.0, 0.0 },
    };

    pub const LayoutIds = struct {
        texture_layout_a: gfx.BindingLayout,
        texture_layout_b: gfx.BindingLayout,
        uniform_layout: gfx.BindingLayout,
    };

    pub fn createLayouts(device: *gfx.Device) !LayoutIds {
        const texture_layout_a = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "dof_texture_a",
        });

        const texture_layout_b = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "dof_texture_b",
        });

        const uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .fragment,
            }},
            .label = "dof_uniform",
        });

        return .{
            .texture_layout_a = texture_layout_a,
            .texture_layout_b = texture_layout_b,
            .uniform_layout = uniform_layout,
        };
    }

    /// Encodes the full DOF pipeline: CoC → Blur → Composite.
    pub fn execute(
        allocator: std.mem.Allocator,
        device: *gfx.Device,
        graph: ?*const render_graph.RenderGraph,
        input_resource_id: u32,
        output_resource_id: u32,
        params: DOFParams,
    ) !void {
        // V2 prototype: skip GPU submission when no valid render target is bound
        if (output_resource_id == 0) return;
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.texture_layout_a,
            layouts.texture_layout_b,
            layouts.uniform_layout,
        });

        // Placeholder textures for color, depth, intermediate
        const color_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba16_float,
            .usage = .{ .sampled = true },
            .label = "dof_color",
        });
        defer device.destroyTexture(color_tex);

        const depth_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .d32_float,
            .usage = .{ .sampled = true },
            .label = "dof_depth",
        });
        defer device.destroyTexture(depth_tex);

        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(DOFParams),
            .usage = .{ .uniform = true },
            .label = "dof_params",
        });
        defer device.destroyBuffer(uniform_buf);

        // Binding sets
        const color_set = try device.createBindingSetCached(layouts.texture_layout_a, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = color_tex } }},
            .label = "dof_color_set",
        });
        const depth_set = try device.createBindingSetCached(layouts.texture_layout_b, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = depth_tex } }},
            .label = "dof_depth_set",
        });
        const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
            .label = "dof_params_set",
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, color_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, depth_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 2, uniform_set);

        _ = params;

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        if (graph) |g| {
            try g.encodeBarrierPlansToCommandBuffer(allocator, device, &cmd);
        }

        // Subpass 0: CoC generation
        try render_graph.RenderGraph.encodeBarrierTransition(
            &cmd,
            input_resource_id,
            .texture,
            .render_target,
            .shader_read,
            .graphics,
            .graphics,
        );
        try cmd.encodeBeginRenderPass(.{
            .color_target_id = output_resource_id + 100, // CoC intermediate target
            .depth_target_id = 0,
            .clear_mask = 0,
        });
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = color_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 1, .set_id = depth_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 2, .set_id = uniform_set.id });
        try cmd.encodeDrawIndexed(.{
            .index_count = 3,
            .instance_count = 1,
            .first_index = 0,
            .vertex_offset = 0,
            .first_instance = 0,
        });
        try cmd.encodeEndRenderPass();

        // Subpass 1: Blur
        try cmd.encodeBeginRenderPass(.{
            .color_target_id = output_resource_id + 200, // Blur intermediate target
            .depth_target_id = 0,
            .clear_mask = 0,
        });
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = color_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 2, .set_id = uniform_set.id });
        try cmd.encodeDrawIndexed(.{
            .index_count = 3,
            .instance_count = 1,
            .first_index = 0,
            .vertex_offset = 0,
            .first_instance = 0,
        });
        try cmd.encodeEndRenderPass();

        // Subpass 2: Composite
        try cmd.encodeBeginRenderPass(.{
            .color_target_id = output_resource_id,
            .depth_target_id = 0,
            .clear_mask = 0,
        });
        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = color_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 2, .set_id = uniform_set.id });
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
