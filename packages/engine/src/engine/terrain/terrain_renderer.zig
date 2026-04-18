///! Terrain GPU renderer — manages vertex/index buffers and draws terrain chunks.
///!
///! Uses a dedicated "terrain" shader program (terrain.vert + terrain.frag)
///! with the same vertex layout as the mesh pass (GpuVertex).
const std = @import("std");
const terrain_mod = @import("terrain.zig");
const mesh_pass_mod = @import("../render/passes/mesh_pass.zig");
const gfx_mod = @import("engine/render/render_context.zig");
const gfx_types = @import("guava_gfx").types;
const shader_support = @import("../render/shader_support.zig");
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");

pub const TerrainRenderer = struct {
    allocator: std.mem.Allocator,
    vertex_buffer: ?gfx_mod.Buffer = null,
    index_buffer: ?gfx_mod.Buffer = null,
    index_count: u32 = 0,
    pipeline: ?gfx_mod.GraphicsPipeline = null,
    stages: ?shader_support.ProgramStages = null,
    pipeline_failed: bool = false,

    /// CPU-side terrain data (owned by renderer; rebuilt when component config changes).
    terrain: ?terrain_mod.Terrain = null,
    /// Snapshot of TerrainComponent config used to detect changes.
    cached_config: ?components.TerrainComponent = null,
    /// True when CPU mesh has been regenerated but not yet uploaded to GPU.
    gpu_dirty: bool = false,

    pub fn init(allocator: std.mem.Allocator) TerrainRenderer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *TerrainRenderer, device: *gfx_mod.RenderContext) void {
        if (self.pipeline) |*p| device.releaseGraphicsPipeline(p);
        if (self.stages) |*s| s.deinit(device);
        if (self.vertex_buffer) |*b| device.releaseBuffer(b);
        if (self.index_buffer) |*b| device.releaseBuffer(b);
        if (self.terrain) |*t| t.deinit();
    }

    pub fn isReady(self: *const TerrainRenderer) bool {
        return self.pipeline != null and self.vertex_buffer != null and self.index_buffer != null;
    }

    /// Create shader pipeline. Call once during init.
    pub fn createPipeline(self: *TerrainRenderer, device: *gfx_mod.RenderContext) !void {
        self.stages = try shader_support.loadProgramStages(device, "terrain");
        errdefer if (self.stages) |*s| s.deinit(device);

        const vertex_layouts = mesh_pass_mod.gpuVertexBufferLayouts();
        const vertex_attributes = mesh_pass_mod.gpuVertexAttributes();

        self.pipeline = try device.createGraphicsPipeline(.{
            .vertex_shader = &self.stages.?.vertex,
            .fragment_shader = &self.stages.?.fragment,
            .vertex_buffer_layouts = vertex_layouts[0..],
            .vertex_attributes = vertex_attributes[0..],
            .color_format = .rgba16_float,
            .depth_format = .d32_float,
            .primitive_type = .triangle_list,
            .fill_mode = .fill,
            .cull_mode = .back,
            .front_face = .counter_clockwise,
            .depth_compare = .less_or_equal,
            .depth_test = true,
            .depth_write = true,
        });
    }

    /// Upload terrain mesh to GPU. Call after terrain.rebuildMesh().
    pub fn uploadMesh(self: *TerrainRenderer, device: *gfx_mod.RenderContext, mesh: *const terrain_mod.TerrainMesh) !void {
        // Release old buffers if any.
        if (self.vertex_buffer) |*b| device.releaseBuffer(b);
        if (self.index_buffer) |*b| device.releaseBuffer(b);

        const vb_size: u32 = @intCast(mesh.vertices.len * @sizeOf(mesh_pass_mod.GpuVertex));
        self.vertex_buffer = try device.createBuffer(.{
            .size = vb_size,
            .usage = gfx_types.BufferUsage.vertex,
            .label = "terrain_vb",
        });
        try device.uploadBufferData(&self.vertex_buffer.?, std.mem.sliceAsBytes(mesh.vertices));

        const ib_size: u32 = @intCast(mesh.indices.len * @sizeOf(u32));
        self.index_buffer = try device.createBuffer(.{
            .size = ib_size,
            .usage = gfx_types.BufferUsage.index,
            .label = "terrain_ib",
        });
        try device.uploadBufferData(&self.index_buffer.?, std.mem.sliceAsBytes(mesh.indices));
        self.index_count = @intCast(mesh.indices.len);
    }

    /// Draw terrain. Call inside an active render pass after binding the scene.
    pub fn draw(
        self: *TerrainRenderer,
        device: *gfx_mod.RenderContext,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        view_projection: [16]f32,
        model: [16]f32,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};
        if (!self.isReady()) return stats;

        device.bindGraphicsPipeline(pass, &self.pipeline.?);
        device.bindVertexBuffer(pass, 0, &self.vertex_buffer.?, 0);
        device.bindIndexBuffer(pass, &self.index_buffer.?, .u32, 0);

        var vertex_uniforms = mesh_pass_mod.VertexUniforms{
            .view_projection = view_projection,
            .model = model,
            .skinning_meta = .{ 0, 0, 0, 0 },
            .skin_matrices = undefined,
        };
        // Zero out the skin matrix array (unused for terrain).
        @memset(std.mem.asBytes(&vertex_uniforms.skin_matrices), 0);

        device.pushVertexUniformData(frame, 0, std.mem.asBytes(&vertex_uniforms));
        device.drawIndexedPrimitives(pass, self.index_count, 1, 0, 0, 0);

        stats.draw_calls = 1;
        stats.triangles_drawn = self.index_count / 3;
        return stats;
    }

    /// High-level entry point called from Renderer.drawFrame().
    /// Iterates entities for TerrainComponent, lazily creates pipeline/mesh,
    /// and issues draw calls for each terrain entity.
    pub fn syncAndDraw(
        self: *TerrainRenderer,
        device: *gfx_mod.RenderContext,
        frame: gfx_mod.Frame,
        pass: gfx_mod.RenderPass,
        scene: *scene_mod.Scene,
        view_projection: [16]f32,
    ) mesh_pass_mod.DrawStats {
        var stats = mesh_pass_mod.DrawStats{};

        // Find first enabled terrain entity.
        var terrain_comp: ?components.TerrainComponent = null;
        var terrain_entity_id: scene_mod.EntityId = 0;
        for (scene.entities.items) |*entity| {
            if (entity.terrain) |tc| {
                if (tc.enabled) {
                    terrain_comp = tc;
                    terrain_entity_id = entity.id;
                    break;
                }
            }
        }

        const tc = terrain_comp orelse return stats;

        // Lazily create pipeline (attempt once; skip if shaders unavailable).
        if (self.pipeline == null and !self.pipeline_failed) {
            self.createPipeline(device) catch {
                self.pipeline_failed = true;
                return stats;
            };
        }
        if (self.pipeline == null) return stats;

        // Detect config change → rebuild terrain data.
        const config_changed = if (self.cached_config) |cc|
            cc.world_size[0] != tc.world_size[0] or
                cc.world_size[1] != tc.world_size[1] or
                cc.resolution != tc.resolution or
                cc.max_height != tc.max_height
        else
            true;

        if (config_changed) {
            if (self.terrain) |*t| t.deinit();
            self.terrain = terrain_mod.Terrain.init(
                self.allocator,
                tc.resolution,
                tc.world_size,
            ) catch return stats;
            self.terrain.?.max_height = tc.max_height;
            self.terrain.?.heightmap.generateHills(tc.max_height * 0.5, 2.0, 4);
            self.terrain.?.rebuildMesh(1) catch return stats;
            self.cached_config = tc;
            self.gpu_dirty = true;
        }

        // Upload mesh to GPU if dirty.
        if (self.gpu_dirty) {
            if (self.terrain.?.mesh) |*mesh| {
                self.uploadMesh(device, mesh) catch return stats;
                self.gpu_dirty = false;
            }
        }

        // Draw.
        const model = if (scene.worldTransformConst(terrain_entity_id)) |t|
            t.toMatrix()
        else blk: {
            const entity = scene.getEntityConst(terrain_entity_id) orelse return stats;
            break :blk entity.local_transform.toMatrix();
        };

        const s = self.draw(device, frame, pass, view_projection, model);
        stats.add(s);
        return stats;
    }
};
