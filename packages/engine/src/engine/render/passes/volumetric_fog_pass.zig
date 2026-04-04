const std = @import("std");
const rhi = @import("../../rhi/rhi.zig");
const render_graph = @import("../render_graph.zig");

/// Volumetric fog pass
///
/// Binding layout: 5 sets
///   Set 0 — Depth texture (sampled)
///   Set 1 — Shadow map texture (sampled)
///   Set 2 — Linear sampler
///   Set 3 — Shadow-compare sampler
///   Set 4 — Uniform buffer (FogParams)
pub const VolumetricFogPass = struct {
    pub const FogParams = extern struct {
        inv_view_projection: [16]f32 = std.mem.zeroes([16]f32),
        light_space_matrix: [16]f32 = std.mem.zeroes([16]f32),
        camera_position: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
        light_direction: [4]f32 = .{ 0.0, -1.0, 0.0, 0.0 },
        light_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
        fog_params: [4]f32 = .{ 0.02, 0.1, 100.0, 32.0 },
        fog_color: [4]f32 = .{ 0.8, 0.85, 0.9, 1.0 },
        noise_params: [4]f32 = .{ 0.0, 0.05, 0.3, 0.0 },
    };

    pub const LayoutIds = struct {
        depth_layout: rhi.BindingLayout,
        shadow_layout: rhi.BindingLayout,
        sampler_layout: rhi.BindingLayout,
        shadow_sampler_layout: rhi.BindingLayout,
        uniform_layout: rhi.BindingLayout,
    };

    pub fn createLayouts(device: *rhi.Device) !LayoutIds {
        const depth_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "fog_depth",
        });

        const shadow_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .texture,
                .stage = .fragment,
            }},
            .label = "fog_shadow",
        });

        const sampler_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .sampler,
                .stage = .fragment,
            }},
            .label = "fog_sampler",
        });

        const shadow_sampler_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .sampler,
                .stage = .fragment,
            }},
            .label = "fog_shadow_sampler",
        });

        const uniform_layout = try device.createBindingLayout(.{
            .entries = &.{.{
                .slot = 0,
                .binding_type = .uniform_buffer,
                .stage = .fragment,
            }},
            .label = "fog_uniform",
        });

        return .{
            .depth_layout = depth_layout,
            .shadow_layout = shadow_layout,
            .sampler_layout = sampler_layout,
            .shadow_sampler_layout = shadow_sampler_layout,
            .uniform_layout = uniform_layout,
        };
    }

    /// Encode and submit volumetric fog pass via command buffer.
    pub fn execute(
        allocator: std.mem.Allocator,
        device: *rhi.Device,
        graph: ?*const render_graph.RenderGraph,
        input_resource_id: u32,
        output_resource_id: u32,
        params: FogParams,
    ) !void {
        // V2 prototype: skip GPU submission when no valid render target is bound
        if (output_resource_id == 0) return;
        const layouts = try createLayouts(device);

        const pipeline_layout = try device.resolvePipelineLayout(&.{
            layouts.depth_layout,
            layouts.shadow_layout,
            layouts.sampler_layout,
            layouts.shadow_sampler_layout,
            layouts.uniform_layout,
        });

        const depth_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .d32_float,
            .usage = .{ .sampled = true },
            .label = "fog_depth_tex",
        });
        defer device.destroyTexture(depth_tex);

        const shadow_tex = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .d32_float,
            .usage = .{ .sampled = true },
            .label = "fog_shadow_tex",
        });
        defer device.destroyTexture(shadow_tex);

        const linear_sampler = try device.createSampler(.{});
        defer device.destroySampler(linear_sampler);

        const shadow_sampler = try device.createSampler(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
        });
        defer device.destroySampler(shadow_sampler);

        const uniform_buf = try device.createBuffer(.{
            .size = @sizeOf(FogParams),
            .usage = .{ .uniform = true },
            .label = "fog_params",
        });
        defer device.destroyBuffer(uniform_buf);

        const depth_set = try device.createBindingSetCached(layouts.depth_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = depth_tex } }},
            .label = "fog_depth_set",
        });
        const shadow_set = try device.createBindingSetCached(layouts.shadow_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .texture = shadow_tex } }},
            .label = "fog_shadow_set",
        });
        const sampler_set = try device.createBindingSetCached(layouts.sampler_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .sampler = linear_sampler } }},
            .label = "fog_sampler_set",
        });
        const shadow_sampler_set = try device.createBindingSetCached(layouts.shadow_sampler_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .sampler = shadow_sampler } }},
            .label = "fog_shadow_sampler_set",
        });
        const uniform_set = try device.createBindingSetCached(layouts.uniform_layout, .{
            .entries = &.{.{ .slot = 0, .resource = .{ .uniform_buffer = uniform_buf } }},
            .label = "fog_params_set",
        });

        try device.validateBindingSetForPipelineSlot(pipeline_layout, 0, depth_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 1, shadow_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 2, sampler_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 3, shadow_sampler_set);
        try device.validateBindingSetForPipelineSlot(pipeline_layout, 4, uniform_set);

        _ = params;

        var cmd = try device.createCommandBuffer(allocator);
        defer cmd.deinit();

        if (graph) |g| {
            try g.encodeBarrierPlansToCommandBuffer(allocator, device, &cmd);
        }

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
            .color_target_id = output_resource_id,
            .depth_target_id = 0,
            .clear_mask = 0,
        });

        try cmd.encodeSetBindingSet(.{ .slot = 0, .set_id = depth_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 1, .set_id = shadow_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 2, .set_id = sampler_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 3, .set_id = shadow_sampler_set.id });
        try cmd.encodeSetBindingSet(.{ .slot = 4, .set_id = uniform_set.id });

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
