///! Batched UI renderer — converts the node tree into vertex batches
///! and issues draw calls through the GFX.
const std = @import("std");
const node_mod = @import("node.zig");
const style_mod = @import("style.zig");
const font_mod = @import("font.zig");
const gfx_mod = @import("gfx/mod.zig");
const gfx_types = @import("guava_gfx").types;
const shader_support = @import("../render/shader_support.zig");

pub const UIVertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

const VertexUniforms = extern struct {
    viewport_size: [2]f32,
    _pad: [2]f32 = .{ 0, 0 },
};

const FragmentUniforms = extern struct {
    mode: i32, // 0 = solid, 1 = textured, 2 = SDF
    sdf_threshold: f32 = 0.5,
    sdf_smoothing: f32 = 0.1,
    _pad: f32 = 0,
};

const max_vertices = 16384;

pub const DrawBatch = struct {
    mode: i32 = 0,
    start_vertex: u32 = 0,
    vertex_count: u32 = 0,
};

pub const UIRenderer = struct {
    allocator: std.mem.Allocator,
    vertices: std.ArrayListUnmanaged(UIVertex) = .empty,
    batches: std.ArrayListUnmanaged(DrawBatch) = .empty,

    pipeline: ?gfx_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,
    vertex_buffer: ?gfx_mod.Buffer = null,
    white_texture: ?gfx_mod.Texture = null,
    sampler: ?gfx_mod.Sampler = null,
    bind_group: ?gfx_mod.BindGroup = null,
    font: ?*font_mod.Font = null,

    pub fn init(allocator: std.mem.Allocator) UIRenderer {
        return .{ .allocator = allocator };
    }

    pub fn createGpuResources(self: *UIRenderer, device: *gfx_mod.GfxDevice) !void {
        // Shader
        self.stages = try shader_support.loadProgramStages(device, "ui");
        errdefer if (self.stages) |*s| {
            s.deinit(device);
        };

        // Vertex buffer (dynamic, re-uploaded each frame)
        self.vertex_buffer = try device.createBuffer(.{
            .size = @intCast(@sizeOf(UIVertex) * max_vertices),
            .usage = gfx_types.BufferUsage.vertex,
            .label = "ui_vertex_buffer",
        });

        // 1x1 white texture for solid-color quads
        self.white_texture = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .rgba8_unorm,
            .usage = gfx_types.TextureUsage.sampler,
            .label = "ui_white_1x1",
        });
        const white_pixel = [_]u8{ 255, 255, 255, 255 };
        try device.uploadTextureData(&self.white_texture.?, &white_pixel, 1, 1);

        // Sampler
        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
        });

        // Bind group (texture + sampler at set=2 for fragment stage)
        const bindings = [_]gfx_mod.TextureSamplerBinding{
            .{
                .texture = &self.white_texture.?,
                .sampler = &self.sampler.?,
            },
        };
        self.bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = &bindings,
            .slot_offset = 0,
        });

        // Pipeline
        const vertex_layouts = [_]gfx_mod.VertexBufferLayoutDesc{
            .{
                .slot = 0,
                .stride = @sizeOf(UIVertex),
                .input_rate = .per_vertex,
            },
        };
        const vertex_attributes = [_]gfx_mod.VertexAttributeDesc{
            .{
                .location = 0,
                .buffer_slot = 0,
                .format = .float2,
                .offset = @offsetOf(UIVertex, "position"),
            },
            .{
                .location = 1,
                .buffer_slot = 0,
                .format = .float2,
                .offset = @offsetOf(UIVertex, "uv"),
            },
            .{
                .location = 2,
                .buffer_slot = 0,
                .format = .float4,
                .offset = @offsetOf(UIVertex, "color"),
            },
        };

        self.pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = device.runtimeInfo().swapchain_format,
            .depth_format = null,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .always,
            .depth_test = false,
            .depth_write = false,
            .blend_state = .{
                .enable_blend = true,
            },
        });
    }

    pub fn deinit(self: *UIRenderer, device: *gfx_mod.GfxDevice) void {
        if (self.bind_group) |*bg| device.releaseBindGroup(bg);
        if (self.sampler) |*s| device.releaseSampler(s);
        if (self.white_texture) |*t| device.releaseTexture(t);
        if (self.vertex_buffer) |*b| device.releaseBuffer(b);
        if (self.pipeline) |*p| device.releaseGraphicsPipeline(p);
        if (self.stages) |*s| s.deinit(device);
        self.vertices.deinit(self.allocator);
        self.batches.deinit(self.allocator);
    }

    pub fn isReady(self: *const UIRenderer) bool {
        return self.pipeline != null and self.vertex_buffer != null;
    }

    // ── Geometry building ───────────────────────────────────────

    pub fn beginFrame(self: *UIRenderer) void {
        self.vertices.clearRetainingCapacity();
        self.batches.clearRetainingCapacity();
    }

    /// Push a solid-color rectangle.
    pub fn pushRect(self: *UIRenderer, x: f32, y: f32, w: f32, h: f32, color: style_mod.Color) void {
        self.pushQuad(x, y, w, h, .{ 0, 0 }, .{ 1, 1 }, color, 0, null);
    }

    /// Push a textured quad.
    pub fn pushImage(self: *UIRenderer, x: f32, y: f32, w: f32, h: f32, tex_id: u32) void {
        self.pushQuad(x, y, w, h, .{ 0, 0 }, .{ 1, 1 }, style_mod.Color.white, 1, tex_id);
    }

    /// Push a single glyph quad (SDF text).
    pub fn pushGlyph(
        self: *UIRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        uv_min: [2]f32,
        uv_max: [2]f32,
        color: style_mod.Color,
        font_tex_id: u32,
    ) void {
        self.pushQuad(x, y, w, h, uv_min, uv_max, color, 2, font_tex_id);
    }

    fn pushQuad(
        self: *UIRenderer,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        uv_min: [2]f32,
        uv_max: [2]f32,
        color: style_mod.Color,
        mode: i32,
        _: ?u32, // tex_id — reserved for future per-batch texture binding
    ) void {
        if (self.vertices.items.len + 6 > max_vertices) return;

        const c = color.toArray();
        const x1 = x + w;
        const y1 = y + h;

        // Two triangles forming a quad
        const verts = [6]UIVertex{
            .{ .position = .{ x, y }, .uv = .{ uv_min[0], uv_min[1] }, .color = c },
            .{ .position = .{ x1, y }, .uv = .{ uv_max[0], uv_min[1] }, .color = c },
            .{ .position = .{ x, y1 }, .uv = .{ uv_min[0], uv_max[1] }, .color = c },
            .{ .position = .{ x1, y }, .uv = .{ uv_max[0], uv_min[1] }, .color = c },
            .{ .position = .{ x1, y1 }, .uv = .{ uv_max[0], uv_max[1] }, .color = c },
            .{ .position = .{ x, y1 }, .uv = .{ uv_min[0], uv_max[1] }, .color = c },
        };

        const start: u32 = @intCast(self.vertices.items.len);
        self.vertices.appendSlice(self.allocator, &verts) catch return;

        // Merge with existing batch if compatible
        if (self.batches.items.len > 0) {
            const last = &self.batches.items[self.batches.items.len - 1];
            if (last.mode == mode) {
                last.vertex_count += 6;
                return;
            }
        }

        self.batches.append(self.allocator, .{
            .mode = mode,
            .start_vertex = start,
            .vertex_count = 6,
        }) catch {};
    }

    // ── Draw calls ──────────────────────────────────────────────

    pub fn flush(
        self: *UIRenderer,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        viewport_w: f32,
        viewport_h: f32,
    ) void {
        if (!self.isReady()) return;
        if (self.vertices.items.len == 0) return;

        // Upload vertices
        device.uploadBufferData(
            &self.vertex_buffer.?,
            std.mem.sliceAsBytes(self.vertices.items),
        ) catch return;

        // Bind pipeline + vertex buffer
        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        device.bindVertexBuffer(pass, 0, &self.vertex_buffer.?, 0);

        // Push vertex uniforms (viewport size for pixel→NDC)
        const vu = VertexUniforms{ .viewport_size = .{ viewport_w, viewport_h } };
        device.pushVertexUniformData(frame, 0, std.mem.asBytes(&vu));

        // Draw each batch
        for (self.batches.items) |batch| {
            const fu = FragmentUniforms{ .mode = batch.mode };
            device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&fu));

            // Bind the appropriate texture: font atlas for SDF text, white 1x1 for solid
            if (batch.mode == 2) {
                if (self.font) |f| {
                    if (f.atlas_bind_group) |*bg| {
                        device.bindGroup(pass, bg);
                    }
                }
            } else if (self.bind_group) |*bg| {
                device.bindGroup(pass, bg);
            }

            device.drawPrimitives(pass, batch.vertex_count, 1, batch.start_vertex, 0);
        }
    }

    // ── Node tree traversal ─────────────────────────────────────

    /// Walk the node tree and generate render geometry.
    pub fn buildFromTree(self: *UIRenderer, pool: *node_mod.NodePool, root_id: u32) void {
        self.beginFrame();
        self.visitNode(pool, root_id);
    }

    fn visitNode(self: *UIRenderer, pool: *node_mod.NodePool, id: u32) void {
        const node = pool.get(id) orelse return;
        if (!node.visible) return;

        const r = node.computed;

        // Draw background
        if (node.style.background.a > 0) {
            self.pushRect(r.x, r.y, r.width, r.height, node.style.background.withAlpha(
                node.style.background.a * node.style.opacity,
            ));
        }

        // Draw border
        if (node.style.border_width > 0 and node.style.border_color.a > 0) {
            const bw = node.style.border_width;
            const bc = node.style.border_color;
            // Top
            self.pushRect(r.x, r.y, r.width, bw, bc);
            // Bottom
            self.pushRect(r.x, r.y + r.height - bw, r.width, bw, bc);
            // Left
            self.pushRect(r.x, r.y + bw, bw, r.height - 2 * bw, bc);
            // Right
            self.pushRect(r.x + r.width - bw, r.y + bw, bw, r.height - 2 * bw, bc);
        }

        // Draw text (SDF glyphs)
        if (node.tag == .text) {
            if (node.text) |txt| {
                if (txt.len > 0) self.renderText(node, r, txt);
            }
        }

        // Recurse children
        var child_opt = node.first_child;
        while (child_opt) |cid| {
            self.visitNode(pool, cid);
            child_opt = if (pool.get(cid)) |c_node| c_node.next_sibling else null;
        }
    }

    fn renderText(self: *UIRenderer, node: *const node_mod.Node, r: node_mod.ComputedRect, text: []const u8) void {
        const f = self.font orelse return;
        const size = node.style.font_size;
        const color = node.style.text_color;
        const scale_factor = size / f.font_size;
        const baseline_y = r.y + f.scaledAscent(size);

        var pen_x = r.x;

        for (text) |byte| {
            const g = f.getGlyph(byte) orelse continue;

            const gx = pen_x + g.bearing_x * scale_factor;
            const gy = baseline_y + g.bearing_y * scale_factor;
            const gw = g.width * scale_factor;
            const gh = g.height * scale_factor;

            if (gw > 0 and gh > 0) {
                self.pushGlyph(
                    gx,
                    gy,
                    gw,
                    gh,
                    .{ g.uv_x0, g.uv_y0 },
                    .{ g.uv_x1, g.uv_y1 },
                    color,
                    0, // font_tex_id — single font for now
                );
            }

            pen_x += g.advance * scale_factor;
        }
    }
};
