const std = @import("std");
const mesh_pass_mod = @import("mesh_pass.zig");
const gfx_mod = @import("gfx/mod.zig");
const gfx_types = @import("guava_gfx").types;
const shader_support = @import("../shader_support.zig");

const fullscreen_triangle_vertex_count: u32 = 3;

pub const DofUniforms = extern struct {
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

pub const DofRuntimePass = struct {
    sampler: ?gfx_mod.Sampler = null,

    // CoC subpass
    coc_stages: ?shader_support.ProgramStages = null,
    coc_pipeline: ?gfx_mod.GraphicsPipeline = null,
    coc_bind_group: ?gfx_mod.BindGroup = null,
    coc_bound_color: usize = 0,
    coc_bound_depth: usize = 0,

    // Blur subpass
    blur_stages: ?shader_support.ProgramStages = null,
    blur_pipeline: ?gfx_mod.GraphicsPipeline = null,
    blur_bind_group: ?gfx_mod.BindGroup = null,
    blur_bound_color: usize = 0,
    blur_bound_coc: usize = 0,

    // Composite subpass
    composite_stages: ?shader_support.ProgramStages = null,
    composite_pipeline: ?gfx_mod.GraphicsPipeline = null,
    composite_bind_group: ?gfx_mod.BindGroup = null,
    composite_bound_color: usize = 0,
    composite_bound_blur: usize = 0,
    composite_bound_coc: usize = 0,

    // Intermediate textures (owned)
    coc_texture: ?gfx_mod.Texture = null,
    blur_texture: ?gfx_mod.Texture = null,
    output_texture: ?gfx_mod.Texture = null,
    intermediate_width: u32 = 0,
    intermediate_height: u32 = 0,

    pub fn init(device: *gfx_mod.GfxDevice) !DofRuntimePass {
        var pass = DofRuntimePass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *DofRuntimePass, device: *gfx_mod.GfxDevice) void {
        self.releaseBindGroups(device);
        self.releaseIntermediateTextures(device);
        if (self.sampler) |*s| device.releaseSampler(s);
        if (self.coc_pipeline) |*p| device.releaseGraphicsPipeline(p);
        if (self.blur_pipeline) |*p| device.releaseGraphicsPipeline(p);
        if (self.composite_pipeline) |*p| device.releaseGraphicsPipeline(p);
        if (self.coc_stages) |*s| s.deinit(device);
        if (self.blur_stages) |*s| s.deinit(device);
        if (self.composite_stages) |*s| s.deinit(device);
        self.* = undefined;
    }

    pub fn isReady(self: *const DofRuntimePass) bool {
        return self.coc_pipeline != null and self.blur_pipeline != null and self.composite_pipeline != null and self.sampler != null;
    }

    pub fn output(self: *const DofRuntimePass) ?*const gfx_mod.Texture {
        return if (self.output_texture) |*t| t else null;
    }

    pub fn ensureIntermediateTextures(self: *DofRuntimePass, device: *gfx_mod.GfxDevice, width: u32, height: u32) !void {
        if (self.intermediate_width == width and self.intermediate_height == height and
            self.coc_texture != null and self.blur_texture != null and self.output_texture != null)
        {
            return;
        }
        self.releaseIntermediateTextures(device);
        self.releaseBindGroups(device);

        const usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler;

        self.coc_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = usage,
        });
        self.blur_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = usage,
        });
        self.output_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = usage,
        });
        self.intermediate_width = width;
        self.intermediate_height = height;
    }

    pub fn syncCocBindGroup(
        self: *DofRuntimePass,
        device: *gfx_mod.GfxDevice,
        color_texture: *const gfx_mod.Texture,
        depth_texture: *const gfx_mod.Texture,
    ) !void {
        if (self.coc_bind_group != null and self.coc_bound_color == color_texture.id and self.coc_bound_depth == depth_texture.id) return;
        if (self.coc_bind_group) |*bg| device.releaseBindGroup(bg);
        const bindings = [_]gfx_mod.TextureSamplerBinding{
            .{ .texture = color_texture, .sampler = &self.sampler.? },
            .{ .texture = depth_texture, .sampler = &self.sampler.? },
        };
        self.coc_bind_group = try device.createBindGroup(.{ .stage = .fragment, .texture_sampler_bindings = bindings[0..] });
        self.coc_bound_color = color_texture.id;
        self.coc_bound_depth = depth_texture.id;
    }

    pub fn syncBlurBindGroup(
        self: *DofRuntimePass,
        device: *gfx_mod.GfxDevice,
        color_texture: *const gfx_mod.Texture,
    ) !void {
        const coc_tex = self.coc_texture orelse return;
        if (self.blur_bind_group != null and self.blur_bound_color == color_texture.id and self.blur_bound_coc == coc_tex.id) return;
        if (self.blur_bind_group) |*bg| device.releaseBindGroup(bg);
        const bindings = [_]gfx_mod.TextureSamplerBinding{
            .{ .texture = color_texture, .sampler = &self.sampler.? },
            .{ .texture = &coc_tex, .sampler = &self.sampler.? },
        };
        self.blur_bind_group = try device.createBindGroup(.{ .stage = .fragment, .texture_sampler_bindings = bindings[0..] });
        self.blur_bound_color = color_texture.id;
        self.blur_bound_coc = coc_tex.id;
    }

    pub fn syncCompositeBindGroup(
        self: *DofRuntimePass,
        device: *gfx_mod.GfxDevice,
        color_texture: *const gfx_mod.Texture,
    ) !void {
        const blur_tex = self.blur_texture orelse return;
        const coc_tex = self.coc_texture orelse return;
        if (self.composite_bind_group != null and self.composite_bound_color == color_texture.id and self.composite_bound_blur == blur_tex.id and self.composite_bound_coc == coc_tex.id) return;
        if (self.composite_bind_group) |*bg| device.releaseBindGroup(bg);
        const bindings = [_]gfx_mod.TextureSamplerBinding{
            .{ .texture = color_texture, .sampler = &self.sampler.? },
            .{ .texture = &blur_tex, .sampler = &self.sampler.? },
            .{ .texture = &coc_tex, .sampler = &self.sampler.? },
        };
        self.composite_bind_group = try device.createBindGroup(.{ .stage = .fragment, .texture_sampler_bindings = bindings[0..] });
        self.composite_bound_color = color_texture.id;
        self.composite_bound_blur = blur_tex.id;
        self.composite_bound_coc = coc_tex.id;
    }

    pub fn drawCoc(
        self: *DofRuntimePass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        uniforms: DofUniforms,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (self.coc_pipeline == null or self.coc_bind_group == null) return stats;
        device.bindGraphicsPipeline(pass, &self.coc_pipeline.?);
        device.bindGroup(pass, &self.coc_bind_group.?);
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.drawPrimitives(pass, fullscreen_triangle_vertex_count, 1, 0, 0);
        stats.draw_calls = 1;
        stats.triangles_drawn = 1;
        return stats;
    }

    pub fn drawBlur(
        self: *DofRuntimePass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        uniforms: DofUniforms,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (self.blur_pipeline == null or self.blur_bind_group == null) return stats;
        device.bindGraphicsPipeline(pass, &self.blur_pipeline.?);
        device.bindGroup(pass, &self.blur_bind_group.?);
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.drawPrimitives(pass, fullscreen_triangle_vertex_count, 1, 0, 0);
        stats.draw_calls = 1;
        stats.triangles_drawn = 1;
        return stats;
    }

    pub fn drawComposite(
        self: *DofRuntimePass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        uniforms: DofUniforms,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (self.composite_pipeline == null or self.composite_bind_group == null) return stats;
        device.bindGraphicsPipeline(pass, &self.composite_pipeline.?);
        device.bindGroup(pass, &self.composite_bind_group.?);
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&uniforms));
        device.drawPrimitives(pass, fullscreen_triangle_vertex_count, 1, 0, 0);
        stats.draw_calls = 1;
        stats.triangles_drawn = 1;
        return stats;
    }

    fn releaseBindGroups(self: *DofRuntimePass, device: *gfx_mod.GfxDevice) void {
        if (self.coc_bind_group) |*bg| {
            device.releaseBindGroup(bg);
            self.coc_bind_group = null;
        }
        if (self.blur_bind_group) |*bg| {
            device.releaseBindGroup(bg);
            self.blur_bind_group = null;
        }
        if (self.composite_bind_group) |*bg| {
            device.releaseBindGroup(bg);
            self.composite_bind_group = null;
        }
        self.coc_bound_color = 0;
        self.coc_bound_depth = 0;
        self.blur_bound_color = 0;
        self.blur_bound_coc = 0;
        self.composite_bound_color = 0;
        self.composite_bound_blur = 0;
        self.composite_bound_coc = 0;
    }

    fn releaseIntermediateTextures(self: *DofRuntimePass, device: *gfx_mod.GfxDevice) void {
        if (self.coc_texture) |*t| {
            device.releaseTexture(t);
            self.coc_texture = null;
        }
        if (self.blur_texture) |*t| {
            device.releaseTexture(t);
            self.blur_texture = null;
        }
        if (self.output_texture) |*t| {
            device.releaseTexture(t);
            self.output_texture = null;
        }
        self.intermediate_width = 0;
        self.intermediate_height = 0;
    }

    fn createResources(self: *DofRuntimePass, device: *gfx_mod.GfxDevice) !void {
        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });

        const vertex_layouts = [_]gfx_mod.VertexBufferLayoutDesc{};
        const vertex_attributes = [_]gfx_mod.VertexAttributeDesc{};

        self.coc_stages = try shader_support.loadProgramStages(device, "dof_coc");
        self.coc_pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.coc_stages.?.vertex,
            .fragment_shader = &self.coc_stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = .rgba16_float,
            .depth_format = null,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .always,
            .depth_test = false,
            .depth_write = false,
        });

        self.blur_stages = try shader_support.loadProgramStages(device, "dof_blur");
        self.blur_pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.blur_stages.?.vertex,
            .fragment_shader = &self.blur_stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = .rgba16_float,
            .depth_format = null,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .always,
            .depth_test = false,
            .depth_write = false,
        });

        self.composite_stages = try shader_support.loadProgramStages(device, "dof_composite");
        self.composite_pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.composite_stages.?.vertex,
            .fragment_shader = &self.composite_stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = .rgba16_float,
            .depth_format = null,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .always,
            .depth_test = false,
            .depth_write = false,
        });
    }
};
