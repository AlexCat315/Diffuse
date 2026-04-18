const std = @import("std");
const math = @import("../../math/mat4.zig");
const vec3 = @import("../../math/vec3.zig");
const axis_mod = @import("../../math/axis.zig");
const components = @import("../../scene/components.zig");
const mesh_pass_mod = @import("mesh_pass.zig");
const gfx_mod = @import("gfx/mod.zig");
const gfx_types = @import("guava_gfx").types;
const shader_support = @import("../shader_support.zig");

pub const EditorGizmoMode = enum {
    idle,
    translate,
    rotate,
    scale,
};

pub const EditorGizmoAxis = axis_mod.Axis3;

pub const EditorGizmoSpace = enum {
    local,
    world,
};

pub const EditorGizmoState = struct {
    mode: EditorGizmoMode = .idle,
    axis: EditorGizmoAxis = .free,
    space: EditorGizmoSpace = .local,
};

pub const WorldLineVertex = extern struct {
    position: [3]f32,
};

const GizmoVertex = WorldLineVertex;

const VertexUniforms = extern struct {
    view_projection: [16]f32,
    model: [16]f32,
};

const FragmentUniforms = extern struct {
    color: [4]f32,
};

const ring_segment_count = 64;

const line_axis_vertices = [_]GizmoVertex{
    .{ .position = .{ 0.0, 0.0, 0.0 } },
    .{ .position = .{ 1.0, 0.0, 0.0 } },
    .{ .position = .{ 0.0, 0.0, 0.0 } },
    .{ .position = .{ 0.0, 1.0, 0.0 } },
    .{ .position = .{ 0.0, 0.0, 0.0 } },
    .{ .position = .{ 0.0, 0.0, 1.0 } },
};

const translate_axis_vertices = buildTranslateAxisVertices();
const scale_axis_vertices = buildScaleAxisVertices();
const center_cube_vertices = buildCenterCubeVertices();
const ring_vertices = buildRingVertices();

const translate_axis_vertex_count = translate_axis_vertices.len;
const scale_axis_vertex_count = scale_axis_vertices.len;
const center_cube_vertex_count = center_cube_vertices.len;
const ring_vertex_count = ring_vertices.len;

pub const GizmoPass = struct {
    line_axis_vertex_buffer: ?gfx_mod.Buffer = null,
    translate_axis_vertex_buffer: ?gfx_mod.Buffer = null,
    scale_axis_vertex_buffer: ?gfx_mod.Buffer = null,
    center_cube_vertex_buffer: ?gfx_mod.Buffer = null,
    ring_vertex_buffer: ?gfx_mod.Buffer = null,
    /// Temporary per-frame buffers for drawWorldLines.  Kept alive until the
    /// next frame so the Metal command buffer can reference them after encoding.
    temp_world_line_buffers: [8]gfx_mod.Buffer = undefined,
    temp_world_line_count: u32 = 0,
    line_pipeline: ?gfx_mod.GraphicsPipeline = null,
    /// Overlay line pipeline — same as line_pipeline but depth_test = false
    /// so mesh edit overlay elements always draw on top of geometry.
    overlay_line_pipeline: ?gfx_mod.GraphicsPipeline = null,
    triangle_pipeline: ?gfx_mod.GraphicsPipeline = null,
    /// Mesh-edit overlay triangle pipeline — depth_test=false + alpha blending.
    /// Used for drawThickOverlayLines / drawVertexDots so teal is semi-transparent
    /// and gold (alpha=1.0) fully replaces teal wherever it overlaps.
    overlay_triangle_pipeline: ?gfx_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,

    pub fn init(device: *gfx_mod.GfxDevice) !GizmoPass {
        var pass = GizmoPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *GizmoPass, device: *gfx_mod.GfxDevice) void {
        var i: u32 = 0;
        while (i < self.temp_world_line_count) : (i += 1) {
            device.releaseBuffer(&self.temp_world_line_buffers[i]);
        }
        self.temp_world_line_count = 0;
        if (self.ring_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.center_cube_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.scale_axis_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.translate_axis_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.line_axis_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        }
        if (self.triangle_pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.overlay_triangle_pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.line_pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.overlay_line_pipeline) |*pipeline| {
            device.releaseGraphicsPipeline(pipeline);
        }
        if (self.stages) |*stages| {
            stages.deinit(device);
        }
        self.* = undefined;
    }

    pub fn isReady(self: *const GizmoPass) bool {
        return self.triangle_pipeline != null and
            self.overlay_triangle_pipeline != null and
            self.line_pipeline != null and
            self.overlay_line_pipeline != null and
            self.line_axis_vertex_buffer != null and
            self.translate_axis_vertex_buffer != null and
            self.scale_axis_vertex_buffer != null and
            self.center_cube_vertex_buffer != null and
            self.ring_vertex_buffer != null;
    }

    /// Release all temporary world-line buffers from the previous frame.
    /// Call this once per frame BEFORE any drawWorldLines calls.
    pub fn releaseWorldLineBuffers(self: *GizmoPass, device: *gfx_mod.GfxDevice) void {
        var i: u32 = 0;
        while (i < self.temp_world_line_count) : (i += 1) {
            device.releaseBuffer(&self.temp_world_line_buffers[i]);
        }
        self.temp_world_line_count = 0;
    }

    pub fn draw(
        self: *GizmoPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        prepared_scene: *const mesh_pass_mod.PreparedScene,
        selected_transform: components.Transform,
        state: EditorGizmoState,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) {
            return stats;
        }

        const gizmo_scale = scaleForSelection(prepared_scene.camera_world_position, selected_transform.translation);
        const base_translation = selected_transform.translation;
        const base_rotation = rotationForSpace(selected_transform, state.space);

        device.bindGraphicsPipeline(pass, &self.triangle_pipeline.?);

        switch (state.mode) {
            .idle => {
                self.drawTranslateAxes(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale * 0.92, state.axis, false, &stats);
                self.drawCenterCube(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale * 0.34, centerColor(.idle), &stats);
            },
            .translate => {
                self.drawTranslateAxes(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale, state.axis, true, &stats);
                self.drawCenterCube(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale * 0.38, centerColor(.translate), &stats);
            },
            .rotate => {
                self.drawRotateRings(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale, state.axis, &stats);
                self.drawCenterCube(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale * 0.3, centerColor(.rotate), &stats);
            },
            .scale => {
                self.drawScaleAxes(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale, state.axis, &stats);
                self.drawScaleBox(device, frame, pass, prepared_scene.view_projection, base_translation, base_rotation, gizmo_scale, &stats);
            },
        }

        return stats;
    }

    pub fn drawWorldLines(
        self: *GizmoPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        view_projection: [16]f32,
        vertices: []const WorldLineVertex,
        color: [4]f32,
    ) !mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or vertices.len == 0) {
            return stats;
        }

        const buffer = try createVertexBuffer(device, vertices);
        // Keep the buffer alive until next frame so the Metal command buffer
        // can reference it after encoding.  All previous frame's buffers are
        // released on the first call of a new frame via releaseWorldLineBuffers.
        if (self.temp_world_line_count < self.temp_world_line_buffers.len) {
            self.temp_world_line_buffers[self.temp_world_line_count] = buffer;
            self.temp_world_line_count += 1;
        } else {
            // Array full: release the oldest buffer and shift
            device.releaseBuffer(&self.temp_world_line_buffers[0]);
            var j: usize = 0;
            while (j < self.temp_world_line_buffers.len - 1) : (j += 1) {
                self.temp_world_line_buffers[j] = self.temp_world_line_buffers[j + 1];
            }
            self.temp_world_line_buffers[self.temp_world_line_buffers.len - 1] = buffer;
        }

        const model = math.identity();
        device.bindGraphicsPipeline(pass, &self.line_pipeline.?);
        self.drawShape(device, frame, pass, buffer, 0, vertices.len, view_projection, model, color, .lines, &stats);
        return stats;
    }

    /// Draw world-space line pairs that always appear on top of geometry
    /// (depth test disabled). Intended for mesh-edit overlay highlight lines.
    pub fn drawOverlayLines(
        self: *GizmoPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        view_projection: [16]f32,
        vertices: []const WorldLineVertex,
        color: [4]f32,
    ) !mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or vertices.len == 0) {
            return stats;
        }

        const buffer = try createVertexBuffer(device, vertices);
        if (self.temp_world_line_count < self.temp_world_line_buffers.len) {
            self.temp_world_line_buffers[self.temp_world_line_count] = buffer;
            self.temp_world_line_count += 1;
        } else {
            device.releaseBuffer(&self.temp_world_line_buffers[0]);
            var j: usize = 0;
            while (j < self.temp_world_line_buffers.len - 1) : (j += 1) {
                self.temp_world_line_buffers[j] = self.temp_world_line_buffers[j + 1];
            }
            self.temp_world_line_buffers[self.temp_world_line_buffers.len - 1] = buffer;
        }

        const model = math.identity();
        device.bindGraphicsPipeline(pass, &self.overlay_line_pipeline.?);
        self.drawShape(device, frame, pass, buffer, 0, vertices.len, view_projection, model, color, .lines, &stats);
        return stats;
    }

    /// Draw world-space line pairs as camera-facing quads so they appear
    /// `line_width_px` pixels wide regardless of camera distance.
    /// Uses the existing `triangle_pipeline` (depth_test=false) so quads
    /// are always drawn on top of geometry.
    ///
    /// `proj_fov_factor` = projection_matrix[5] = 1/tan(fov_y/2).
    /// `viewport_height` = render-target height in pixels.
    pub fn drawThickOverlayLines(
        self: *GizmoPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        view_projection: [16]f32,
        line_vertices: []const WorldLineVertex,
        camera_pos: [3]f32,
        proj_fov_factor: f32,
        viewport_height: f32,
        line_width_px: f32,
        /// When true, extend each segment endpoint outward by half_thick
        /// to create square caps.  Use for selected (gold) lines only —
        /// this allows gold to cover the exact endpoint area of teal lines,
        /// preventing gold+teal blending at shared vertices.
        extend_caps: bool,
        allocator: std.mem.Allocator,
        color: [4]f32,
    ) !mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or line_vertices.len < 2) {
            return stats;
        }

        const segment_count = line_vertices.len / 2;
        const quad_vertex_count = segment_count * 6;

        const quad_vertices = try allocator.alloc(WorldLineVertex, quad_vertex_count);
        defer allocator.free(quad_vertices);

        const safe_fov = if (proj_fov_factor < 0.001) 1.0 else proj_fov_factor;
        const safe_height = if (viewport_height < 1.0) 1.0 else viewport_height;

        var out: usize = 0;
        var seg: usize = 0;
        while (seg < segment_count) : (seg += 1) {
            const p0: [3]f32 = line_vertices[seg * 2].position;
            const p1: [3]f32 = line_vertices[seg * 2 + 1].position;

            const mid = [3]f32{
                (p0[0] + p1[0]) * 0.5,
                (p0[1] + p1[1]) * 0.5,
                (p0[2] + p1[2]) * 0.5,
            };

            const line_dir = vec3.normalize(vec3.sub(p1, p0));
            const to_cam = vec3.sub(camera_pos, mid);
            const dist = vec3.length(to_cam);

            // Camera-facing perpendicular via billboard cross product.
            const perp = vec3.normalize(vec3.cross(line_dir, to_cam));

            // Perspective-correct world-space half-thickness.
            const half_thick = line_width_px * dist / (safe_fov * safe_height * 0.5);

            // Optionally extend endpoints for square caps (gold lines only).
            const p0c = if (extend_caps) vec3.sub(p0, vec3.scale(line_dir, half_thick)) else p0;
            const p1c = if (extend_caps) vec3.add(p1, vec3.scale(line_dir, half_thick)) else p1;

            // Quad corners (two triangles, CCW winding).
            const a = vec3.sub(p0c, vec3.scale(perp, half_thick));
            const b = vec3.add(p0c, vec3.scale(perp, half_thick));
            const c = vec3.add(p1c, vec3.scale(perp, half_thick));
            const d = vec3.sub(p1c, vec3.scale(perp, half_thick));

            quad_vertices[out + 0] = .{ .position = a };
            quad_vertices[out + 1] = .{ .position = b };
            quad_vertices[out + 2] = .{ .position = c };
            quad_vertices[out + 3] = .{ .position = a };
            quad_vertices[out + 4] = .{ .position = c };
            quad_vertices[out + 5] = .{ .position = d };
            out += 6;
        }

        const buffer = try createVertexBuffer(device, quad_vertices[0..out]);
        if (self.temp_world_line_count < self.temp_world_line_buffers.len) {
            self.temp_world_line_buffers[self.temp_world_line_count] = buffer;
            self.temp_world_line_count += 1;
        } else {
            device.releaseBuffer(&self.temp_world_line_buffers[0]);
            var j: usize = 0;
            while (j < self.temp_world_line_buffers.len - 1) : (j += 1) {
                self.temp_world_line_buffers[j] = self.temp_world_line_buffers[j + 1];
            }
            self.temp_world_line_buffers[self.temp_world_line_buffers.len - 1] = buffer;
        }

        const model = math.identity();
        device.bindGraphicsPipeline(pass, &self.overlay_triangle_pipeline.?);
        self.drawShape(device, frame, pass, buffer, 0, out, view_projection, model, color, .triangles, &stats);
        return stats;
    }

    /// Render world-space positions as camera-facing square billboards.
    /// Each element of `positions` is treated as a single dot center (NOT a
    /// line pair).  The billboard is `dot_size_px` × `dot_size_px` pixels.
    pub fn drawVertexDots(
        self: *GizmoPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        view_projection: [16]f32,
        positions: []const WorldLineVertex,
        camera_pos: [3]f32,
        proj_fov_factor: f32,
        viewport_height: f32,
        dot_size_px: f32,
        allocator: std.mem.Allocator,
        color: [4]f32,
    ) !mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady() or positions.len == 0) {
            return stats;
        }

        const quad_vertices = try allocator.alloc(WorldLineVertex, positions.len * 6);
        defer allocator.free(quad_vertices);

        const safe_fov = if (proj_fov_factor < 0.001) 1.0 else proj_fov_factor;
        const safe_height = if (viewport_height < 1.0) 1.0 else viewport_height;
        const world_up: [3]f32 = .{ 0.0, 1.0, 0.0 };
        const world_z: [3]f32 = .{ 0.0, 0.0, 1.0 };

        var out: usize = 0;
        for (positions) |vx| {
            const p = vx.position;
            const to_cam = vec3.sub(camera_pos, p);
            const dist = vec3.length(to_cam);
            const view_dir = vec3.normalize(to_cam);

            // Perspective-correct half-size: (dot_size_px / 2) world units
            const half = dot_size_px * dist / (safe_fov * safe_height * 0.5);

            // Camera-facing right/up.  Avoid cross-product degeneracy when
            // looking almost straight up or down.
            const right_raw = vec3.cross(view_dir, world_up);
            const right = if (vec3.length(right_raw) > 0.001)
                vec3.normalize(right_raw)
            else
                vec3.normalize(vec3.cross(view_dir, world_z));
            const up_local = vec3.normalize(vec3.cross(right, view_dir));

            const r = vec3.scale(right, half);
            const u = vec3.scale(up_local, half);

            // CCW quad: bl → br → tr, bl → tr → tl
            const bl = vec3.sub(vec3.sub(p, r), u);
            const br = vec3.sub(vec3.add(p, r), u);
            const tr = vec3.add(vec3.add(p, r), u);
            const tl = vec3.add(vec3.sub(p, r), u);

            quad_vertices[out + 0] = .{ .position = bl };
            quad_vertices[out + 1] = .{ .position = br };
            quad_vertices[out + 2] = .{ .position = tr };
            quad_vertices[out + 3] = .{ .position = bl };
            quad_vertices[out + 4] = .{ .position = tr };
            quad_vertices[out + 5] = .{ .position = tl };
            out += 6;
        }

        const buffer = try createVertexBuffer(device, quad_vertices[0..out]);
        if (self.temp_world_line_count < self.temp_world_line_buffers.len) {
            self.temp_world_line_buffers[self.temp_world_line_count] = buffer;
            self.temp_world_line_count += 1;
        } else {
            device.releaseBuffer(&self.temp_world_line_buffers[0]);
            var j: usize = 0;
            while (j < self.temp_world_line_buffers.len - 1) : (j += 1) {
                self.temp_world_line_buffers[j] = self.temp_world_line_buffers[j + 1];
            }
            self.temp_world_line_buffers[self.temp_world_line_buffers.len - 1] = buffer;
        }

        const model = math.identity();
        device.bindGraphicsPipeline(pass, &self.overlay_triangle_pipeline.?);
        self.drawShape(device, frame, pass, buffer, 0, out, view_projection, model, color, .triangles, &stats);
        return stats;
    }

    fn createResources(self: *GizmoPass, device: *gfx_mod.GfxDevice) !void {
        self.line_axis_vertex_buffer = try createVertexBuffer(device, line_axis_vertices[0..]);
        errdefer if (self.line_axis_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };

        self.translate_axis_vertex_buffer = try createVertexBuffer(device, translate_axis_vertices[0..]);
        errdefer if (self.translate_axis_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };

        self.scale_axis_vertex_buffer = try createVertexBuffer(device, scale_axis_vertices[0..]);
        errdefer if (self.scale_axis_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };

        self.center_cube_vertex_buffer = try createVertexBuffer(device, center_cube_vertices[0..]);
        errdefer if (self.center_cube_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };

        self.ring_vertex_buffer = try createVertexBuffer(device, ring_vertices[0..]);
        errdefer if (self.ring_vertex_buffer) |*buffer| {
            device.releaseBuffer(buffer);
        };

        self.stages = try shader_support.loadProgramStages(device, "gizmo");
        errdefer if (self.stages) |*stages| {
            stages.deinit(device);
        };

        const vertex_layouts = [_]gfx_mod.VertexBufferLayoutDesc{
            .{
                .slot = 0,
                .stride = @sizeOf(GizmoVertex),
                .input_rate = .per_vertex,
            },
        };
        const vertex_attributes = [_]gfx_mod.VertexAttributeDesc{
            .{
                .location = 0,
                .buffer_slot = 0,
                .format = .float3,
                .offset = @offsetOf(GizmoVertex, "position"),
            },
        };

        self.line_pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = device.runtimeInfo().swapchain_format,
            .depth_format = .d32_float,
            .primitive_type = .line_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal,
            .depth_test = true,
            .depth_write = false,
        });

        // Overlay variant: no depth test so overlay lines always appear on top.
        self.overlay_line_pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = device.runtimeInfo().swapchain_format,
            .depth_format = .d32_float,
            .primitive_type = .line_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .always,
            .depth_test = false,
            .depth_write = false,
        });

        self.triangle_pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = device.runtimeInfo().swapchain_format,
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .always,
            .depth_test = false,
            .depth_write = false,
        });

        // Mesh-edit overlay triangle pipeline: no depth test + alpha blending.
        // With blend enabled, gold (alpha=1.0) fully overwrites teal, and teal
        // is composited semi-transparently over the scene.
        self.overlay_triangle_pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = device.runtimeInfo().swapchain_format,
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .none,
            .front_face = .counter_clockwise,
            .depth_compare = .always,
            .depth_test = false,
            .depth_write = false,
            .blend_state = .{ .enable_blend = true },
        });
    }

    fn drawTranslateAxes(
        self: *GizmoPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        view_projection: [16]f32,
        translation: [3]f32,
        rotation: [3]f32,
        gizmo_scale: f32,
        constrained_axis: EditorGizmoAxis,
        active: bool,
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        const mode: EditorGizmoMode = if (active) .translate else .idle;
        const x_color = axisColor(.x, constrained_axis, mode);
        const y_color = axisColor(.y, constrained_axis, mode);
        const z_color = axisColor(.z, constrained_axis, mode);
        self.drawAxisMesh(device, frame, pass, self.translate_axis_vertex_buffer.?, translate_axis_vertex_count, view_projection, translation, rotation, .{ 0.0, 0.0, 0.0 }, gizmo_scale, x_color, stats);
        self.drawAxisMesh(device, frame, pass, self.translate_axis_vertex_buffer.?, translate_axis_vertex_count, view_projection, translation, rotation, .{ 0.0, 0.0, std.math.pi * 0.5 }, gizmo_scale, y_color, stats);
        self.drawAxisMesh(device, frame, pass, self.translate_axis_vertex_buffer.?, translate_axis_vertex_count, view_projection, translation, rotation, .{ 0.0, -std.math.pi * 0.5, 0.0 }, gizmo_scale, z_color, stats);
    }

    fn drawScaleAxes(
        self: *GizmoPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        view_projection: [16]f32,
        translation: [3]f32,
        rotation: [3]f32,
        gizmo_scale: f32,
        constrained_axis: EditorGizmoAxis,
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        const x_color = axisColor(.x, constrained_axis, .scale);
        const y_color = axisColor(.y, constrained_axis, .scale);
        const z_color = axisColor(.z, constrained_axis, .scale);
        self.drawAxisMesh(device, frame, pass, self.scale_axis_vertex_buffer.?, scale_axis_vertex_count, view_projection, translation, rotation, .{ 0.0, 0.0, 0.0 }, gizmo_scale, x_color, stats);
        self.drawAxisMesh(device, frame, pass, self.scale_axis_vertex_buffer.?, scale_axis_vertex_count, view_projection, translation, rotation, .{ 0.0, 0.0, std.math.pi * 0.5 }, gizmo_scale, y_color, stats);
        self.drawAxisMesh(device, frame, pass, self.scale_axis_vertex_buffer.?, scale_axis_vertex_count, view_projection, translation, rotation, .{ 0.0, -std.math.pi * 0.5, 0.0 }, gizmo_scale, z_color, stats);
    }

    fn drawRotateRings(
        self: *GizmoPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        view_projection: [16]f32,
        translation: [3]f32,
        rotation: [3]f32,
        gizmo_scale: f32,
        constrained_axis: EditorGizmoAxis,
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        const x_color = axisColor(.x, constrained_axis, .rotate);
        const y_color = axisColor(.y, constrained_axis, .rotate);
        const z_color = axisColor(.z, constrained_axis, .rotate);
        self.drawRingCluster(device, frame, pass, view_projection, translation, rotation, gizmo_scale, .{ 0.0, std.math.pi * 0.5, 0.0 }, x_color, stats);
        self.drawRingCluster(device, frame, pass, view_projection, translation, rotation, gizmo_scale, .{ std.math.pi * 0.5, 0.0, 0.0 }, y_color, stats);
        self.drawRingCluster(device, frame, pass, view_projection, translation, rotation, gizmo_scale, .{ 0.0, 0.0, 0.0 }, z_color, stats);
    }

    fn drawAxisMesh(
        self: *GizmoPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        buffer: gfx_mod.Buffer,
        vertex_count: usize,
        view_projection: [16]f32,
        translation: [3]f32,
        rotation: [3]f32,
        extra_rotation: [3]f32,
        gizmo_scale: f32,
        color: [4]f32,
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        const model = composeModelMatrix(translation, rotation, .{ gizmo_scale, gizmo_scale, gizmo_scale }, extra_rotation);
        self.drawShape(device, frame, pass, buffer, 0, vertex_count, view_projection, model, color, .triangles, stats);
    }

    fn drawRingCluster(
        self: *GizmoPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        view_projection: [16]f32,
        translation: [3]f32,
        rotation: [3]f32,
        gizmo_scale: f32,
        extra_rotation: [3]f32,
        color: [4]f32,
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        const model = composeModelMatrix(translation, rotation, .{ gizmo_scale, gizmo_scale, gizmo_scale }, extra_rotation);
        self.drawShape(device, frame, pass, self.ring_vertex_buffer.?, 0, ring_vertex_count, view_projection, model, color, .triangles, stats);
    }

    fn drawScaleBox(
        self: *GizmoPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        view_projection: [16]f32,
        translation: [3]f32,
        rotation: [3]f32,
        gizmo_scale: f32,
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        self.drawCenterCube(device, frame, pass, view_projection, translation, rotation, gizmo_scale * 0.42, centerColor(.scale), stats);
    }

    fn drawCenterCube(
        self: *GizmoPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        view_projection: [16]f32,
        translation: [3]f32,
        rotation: [3]f32,
        gizmo_scale: f32,
        color: [4]f32,
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        const model = composeModelMatrix(translation, rotation, .{ gizmo_scale, gizmo_scale, gizmo_scale }, .{ 0.0, 0.0, 0.0 });
        self.drawShape(device, frame, pass, self.center_cube_vertex_buffer.?, 0, center_cube_vertex_count, view_projection, model, color, .triangles, stats);
    }

    fn drawShape(
        self: *GizmoPass,
        device: *gfx_mod.GfxDevice,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        buffer: gfx_mod.Buffer,
        first_vertex: usize,
        vertex_count: usize,
        view_projection: [16]f32,
        model: [16]f32,
        color: [4]f32,
        primitive: enum { lines, triangles },
        stats: *mesh_pass_mod.DrawStats,
    ) void {
        _ = self;
        var vertex_uniforms = VertexUniforms{
            .view_projection = view_projection,
            .model = model,
        };
        var fragment_uniforms = FragmentUniforms{
            .color = color,
        };

        device.bindVertexBuffer(pass, 0, &buffer, 0);
        device.pushVertexUniformData(frame, 0, std.mem.asBytes(&vertex_uniforms));
        device.pushFragmentUniformData(frame, 0, std.mem.asBytes(&fragment_uniforms));
        device.drawPrimitives(pass, @intCast(vertex_count), 1, @intCast(first_vertex), 0);
        stats.draw_calls += 1;
        if (primitive == .triangles) {
            stats.triangles_drawn += vertex_count / 3;
        }
    }
};

fn createVertexBuffer(device: *gfx_mod.GfxDevice, vertices: []const GizmoVertex) !gfx_mod.Buffer {
    const buffer = try device.createBuffer(.{
        .size = @intCast(@sizeOf(GizmoVertex) * vertices.len),
        .usage = gfx_types.BufferUsage.vertex,
    });
    errdefer {
        var owned = buffer;
        device.releaseBuffer(&owned);
    }
    try device.uploadBufferData(&buffer, std.mem.sliceAsBytes(vertices));
    return buffer;
}

fn buildTranslateAxisVertices() [48]GizmoVertex {
    var vertices: [48]GizmoVertex = undefined;
    var index: usize = 0;
    appendBox(vertices[0..], &index, .{ 0.0, -0.032, -0.032 }, .{ 0.76, 0.032, 0.032 });
    appendPyramidX(vertices[0..], &index, 0.76, 1.0, 0.12, 0.12);
    return vertices;
}

fn buildScaleAxisVertices() [72]GizmoVertex {
    var vertices: [72]GizmoVertex = undefined;
    var index: usize = 0;
    appendBox(vertices[0..], &index, .{ 0.0, -0.03, -0.03 }, .{ 0.82, 0.03, 0.03 });
    appendBox(vertices[0..], &index, .{ 0.82, -0.085, -0.085 }, .{ 1.0, 0.085, 0.085 });
    return vertices;
}

fn buildCenterCubeVertices() [36]GizmoVertex {
    var vertices: [36]GizmoVertex = undefined;
    var index: usize = 0;
    appendBox(vertices[0..], &index, .{ -0.18, -0.18, -0.18 }, .{ 0.18, 0.18, 0.18 });
    return vertices;
}

fn buildRingVertices() [ring_segment_count * 6]GizmoVertex {
    var vertices: [ring_segment_count * 6]GizmoVertex = undefined;
    var index: usize = 0;
    var segment: usize = 0;
    while (segment < ring_segment_count) : (segment += 1) {
        const angle_start = (@as(f32, @floatFromInt(segment)) / @as(f32, @floatFromInt(ring_segment_count))) * std.math.tau;
        const angle_end = (@as(f32, @floatFromInt(segment + 1)) / @as(f32, @floatFromInt(ring_segment_count))) * std.math.tau;
        const inner_start = [3]f32{ std.math.cos(angle_start) * 0.84, std.math.sin(angle_start) * 0.84, 0.0 };
        const outer_start = [3]f32{ std.math.cos(angle_start) * 0.98, std.math.sin(angle_start) * 0.98, 0.0 };
        const inner_end = [3]f32{ std.math.cos(angle_end) * 0.84, std.math.sin(angle_end) * 0.84, 0.0 };
        const outer_end = [3]f32{ std.math.cos(angle_end) * 0.98, std.math.sin(angle_end) * 0.98, 0.0 };
        appendQuad(vertices[0..], &index, inner_start, outer_start, outer_end, inner_end);
    }
    return vertices;
}

fn appendBox(vertices: []GizmoVertex, index: *usize, min_corner: [3]f32, max_corner: [3]f32) void {
    const p000 = [3]f32{ min_corner[0], min_corner[1], min_corner[2] };
    const p001 = [3]f32{ min_corner[0], min_corner[1], max_corner[2] };
    const p010 = [3]f32{ min_corner[0], max_corner[1], min_corner[2] };
    const p011 = [3]f32{ min_corner[0], max_corner[1], max_corner[2] };
    const p100 = [3]f32{ max_corner[0], min_corner[1], min_corner[2] };
    const p101 = [3]f32{ max_corner[0], min_corner[1], max_corner[2] };
    const p110 = [3]f32{ max_corner[0], max_corner[1], min_corner[2] };
    const p111 = [3]f32{ max_corner[0], max_corner[1], max_corner[2] };

    appendQuad(vertices, index, p001, p101, p111, p011);
    appendQuad(vertices, index, p100, p000, p010, p110);
    appendQuad(vertices, index, p000, p001, p011, p010);
    appendQuad(vertices, index, p101, p100, p110, p111);
    appendQuad(vertices, index, p010, p011, p111, p110);
    appendQuad(vertices, index, p000, p100, p101, p001);
}

fn appendPyramidX(vertices: []GizmoVertex, index: *usize, base_x: f32, tip_x: f32, half_y: f32, half_z: f32) void {
    const base00 = [3]f32{ base_x, -half_y, -half_z };
    const base01 = [3]f32{ base_x, -half_y, half_z };
    const base10 = [3]f32{ base_x, half_y, -half_z };
    const base11 = [3]f32{ base_x, half_y, half_z };
    const tip = [3]f32{ tip_x, 0.0, 0.0 };

    appendTriangle(vertices, index, base00, base01, tip);
    appendTriangle(vertices, index, base01, base11, tip);
    appendTriangle(vertices, index, base11, base10, tip);
    appendTriangle(vertices, index, base10, base00, tip);
}

fn appendQuad(vertices: []GizmoVertex, index: *usize, a: [3]f32, b: [3]f32, c: [3]f32, d: [3]f32) void {
    appendTriangle(vertices, index, a, b, c);
    appendTriangle(vertices, index, a, c, d);
}

fn appendTriangle(vertices: []GizmoVertex, index: *usize, a: [3]f32, b: [3]f32, c: [3]f32) void {
    vertices[index.*] = .{ .position = a };
    vertices[index.* + 1] = .{ .position = b };
    vertices[index.* + 2] = .{ .position = c };
    index.* += 3;
}

fn composeModelMatrix(
    translation: [3]f32,
    rotation: [3]f32,
    scale: [3]f32,
    extra_rotation: [3]f32,
) [16]f32 {
    const base_rotation = math.mul(
        math.mul(math.rotationZ(rotation[2]), math.rotationY(rotation[1])),
        math.rotationX(rotation[0]),
    );
    const local_rotation = math.mul(
        math.mul(math.rotationZ(extra_rotation[2]), math.rotationY(extra_rotation[1])),
        math.rotationX(extra_rotation[0]),
    );
    return math.mul(
        math.mul(math.translation(translation), math.mul(base_rotation, local_rotation)),
        math.scale(scale),
    );
}

pub fn scaleForSelection(camera_world_position: [4]f32, target_position: [3]f32) f32 {
    const dx = camera_world_position[0] - target_position[0];
    const dy = camera_world_position[1] - target_position[1];
    const dz = camera_world_position[2] - target_position[2];
    const distance = std.math.sqrt(dx * dx + dy * dy + dz * dz);
    return std.math.clamp(distance * 0.2, 0.9, 3.8);
}

pub fn rotationForSpace(selected_transform: components.Transform, space: EditorGizmoSpace) [3]f32 {
    const quat = @import("../../math/quat.zig");
    return switch (space) {
        .local => quat.toEuler(selected_transform.rotation),
        .world => .{ 0.0, 0.0, 0.0 },
    };
}

fn axisColor(axis: EditorGizmoAxis, constrained_axis: EditorGizmoAxis, mode: EditorGizmoMode) [4]f32 {
    var color: [4]f32 = switch (axis) {
        .free => .{ 1.0, 0.86, 0.32, 1.0 },
        .x => .{ 0.98, 0.3, 0.28, 1.0 },
        .y => .{ 0.3, 0.92, 0.38, 1.0 },
        .z => .{ 0.28, 0.58, 1.0, 1.0 },
    };

    if (constrained_axis != .free) {
        if (axis == constrained_axis) {
            color[0] = @min(color[0] * 1.2, 1.0);
            color[1] = @min(color[1] * 1.2, 1.0);
            color[2] = @min(color[2] * 1.2, 1.0);
        } else {
            color[0] *= 0.45;
            color[1] *= 0.45;
            color[2] *= 0.45;
        }
    } else if (mode == .idle) {
        color[0] *= 0.92;
        color[1] *= 0.92;
        color[2] *= 0.92;
    }

    return color;
}

fn centerColor(mode: EditorGizmoMode) [4]f32 {
    return switch (mode) {
        .idle => .{ 1.0, 0.78, 0.28, 1.0 },
        .translate => .{ 1.0, 0.92, 0.45, 1.0 },
        .rotate => .{ 1.0, 0.72, 0.32, 1.0 },
        .scale => .{ 0.95, 0.95, 0.98, 1.0 },
    };
}

test "scaleForSelection grows with distance and clamps" {
    try std.testing.expect(scaleForSelection(.{ 0.0, 0.0, 2.0, 1.0 }, .{ 0.0, 0.0, 0.0 }) >= 0.7);
    try std.testing.expectEqual(@as(f32, 3.4), scaleForSelection(.{ 0.0, 0.0, 50.0, 1.0 }, .{ 0.0, 0.0, 0.0 }));
}

test "axisColor dims unconstrained axes when locked" {
    const locked = axisColor(.y, .x, .translate);
    try std.testing.expect(locked[1] < 0.4);
    const highlighted = axisColor(.x, .x, .translate);
    try std.testing.expect(highlighted[0] >= 0.99);
}

test "rotationForSpace resets world gizmo orientation" {
    const quat = @import("../../math/quat.zig");
    const euler = [3]f32{ 0.25, 0.5, 0.75 };
    const selected = components.Transform{
        .rotation = quat.fromEuler(euler),
    };
    const local_rot = rotationForSpace(selected, .local);
    try std.testing.expectApproxEqAbs(euler[0], local_rot[0], 0.0001);
    try std.testing.expectApproxEqAbs(euler[1], local_rot[1], 0.0001);
    try std.testing.expectApproxEqAbs(euler[2], local_rot[2], 0.0001);
    try std.testing.expectEqualSlices(f32, &.{ 0.0, 0.0, 0.0 }, &rotationForSpace(selected, .world));
}
