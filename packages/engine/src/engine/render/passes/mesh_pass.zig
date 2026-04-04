const std = @import("std");
const handles = @import("../../assets/handles.zig");
const material_ast_mod = @import("../../assets/material_ast.zig");
const material_mod = @import("../../assets/material_resource.zig");
const mesh_mod = @import("../../assets/mesh_resource.zig");
const texture_mod = @import("../../assets/texture_resource.zig");
const math = @import("../../math/mat4.zig");
const vec3 = @import("../../math/vec3.zig");
const quat = @import("../../math/quat.zig");
const rhi_mod = @import("../../rhi/device.zig");
const rhi_types = @import("../../rhi/types.zig");
const components = @import("../../scene/components.zig");
const scene_mod = @import("../../scene/scene.zig");
const scene_extraction = @import("../scene_extraction.zig");
const ibl_precompute = @import("../ibl_precompute.zig");

const frustum_mod = @import("../../math/frustum.zig");

pub const max_skin_joints: usize = 64;

pub const GpuVertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    color: [4]f32,
    uv: [2]f32,
    joints: [4]f32,
    weights: [4]f32,
};

pub fn gpuVertexBufferLayouts() [1]rhi_mod.VertexBufferLayoutDesc {
    return .{
        .{
            .slot = 0,
            .stride = @sizeOf(GpuVertex),
            .input_rate = .per_vertex,
        },
    };
}

pub fn gpuVertexAttributes() [6]rhi_mod.VertexAttributeDesc {
    return .{
        .{
            .location = 0,
            .buffer_slot = 0,
            .format = .float3,
            .offset = @offsetOf(GpuVertex, "position"),
        },
        .{
            .location = 1,
            .buffer_slot = 0,
            .format = .float3,
            .offset = @offsetOf(GpuVertex, "normal"),
        },
        .{
            .location = 2,
            .buffer_slot = 0,
            .format = .float4,
            .offset = @offsetOf(GpuVertex, "color"),
        },
        .{
            .location = 3,
            .buffer_slot = 0,
            .format = .float2,
            .offset = @offsetOf(GpuVertex, "uv"),
        },
        .{
            .location = 4,
            .buffer_slot = 0,
            .format = .float4,
            .offset = @offsetOf(GpuVertex, "joints"),
        },
        .{
            .location = 5,
            .buffer_slot = 0,
            .format = .float4,
            .offset = @offsetOf(GpuVertex, "weights"),
        },
    };
}

pub const DrawStats = struct {
    draw_calls: usize = 0,
    triangles_drawn: usize = 0,

    pub fn add(self: *DrawStats, other: DrawStats) void {
        self.draw_calls += other.draw_calls;
        self.triangles_drawn += other.triangles_drawn;
    }
};

pub const VertexUniforms = extern struct {
    view_projection: [16]f32,
    model: [16]f32,
    skinning_meta: [4]u32,
    skin_matrices: [max_skin_joints][16]f32,
};

pub const csm_cascade_count = 4;
pub const max_directional_lights = 4;
pub const max_point_lights = 16;
pub const max_spot_lights = 16;

pub const BasePassUniforms = extern struct {
    base_color_factor: [4]f32,
    emissive_factor: [4]f32, // w is intensity
    pbr_factors: [4]f32, // x: metallic, y: roughness, z: alpha_cutoff, w: output alpha multiplier
    has_textures: [4]u32, // x: base_color, y: metallic_roughness, z: normal, w: occlusion
    camera_world_position: [4]f32,
    dir_light_directions: [max_directional_lights][4]f32, // xyz = direction, w = 0
    dir_light_colors: [max_directional_lights][4]f32, // rgb = color, w = intensity
    light_space_matrix: [16]f32,
    point_light_positions: [max_point_lights][4]f32, // xyz = position, w = range
    point_light_colors: [max_point_lights][4]f32, // rgb = color, w = intensity
    spot_light_positions: [max_spot_lights][4]f32, // xyz = position, w = range
    spot_light_directions: [max_spot_lights][4]f32, // xyz = direction, w = inner cone cos
    spot_light_colors: [max_spot_lights][4]f32, // rgb = color, w = intensity
    spot_light_angles: [max_spot_lights][4]f32, // x = outer cone cos
    light_counts: [4]u32, // x: dir_count, y: point_count, z: spot_count
    ambient_color: [4]f32,
    shadow_params: [4]f32, // x: bias, yzw: preview tint color
    rt_shadow_params: [4]f32, // x: enabled (0/1), y: strength, z: ambient floor, w: unused
    ibl_params: [4]f32, // x: use_ibl (0/1), y: ibl_intensity, z: preview tint strength, w: unused
    cascade_matrices: [csm_cascade_count][16]f32,
    cascade_splits: [4]f32, // view-space far distance per cascade
    view_matrix: [16]f32,
};

pub const DrawItem = struct {
    entity_id: scene_mod.EntityId,
    pickable: bool,
    mesh_handle: handles.MeshHandle = .invalid,
    vertex_buffer: rhi_mod.Buffer,
    index_buffer: rhi_mod.Buffer,
    index_count: u32,
    wireframe_index_buffer: rhi_mod.Buffer,
    wireframe_index_count: u32,
    bind_group: rhi_mod.BindGroup,
    material_textures: [5]*const rhi_mod.Texture, // [0]=base_color [1]=mr [2]=normal [3]=occlusion [4]=emissive
    base_color_factor: [4]f32,
    emissive_factor: [4]f32,
    pbr_factors: [4]f32,
    has_textures: [4]u32,
    ibl_params: [4]f32,
    model: [16]f32,
    world_position: [3]f32,
    skinning_meta: [4]u32,
    skin_matrices: [max_skin_joints][16]f32,
};

pub const CameraBlock = struct {
    transform: components.Transform,
    camera: components.Camera,
    is_primary: bool,
};

pub const DirectionalLightBlock = struct {
    direction: [3]f32,
    color: [3]f32,
    intensity: f32,
};

pub const PointLightBlock = struct {
    position: [3]f32,
    color: [3]f32,
    intensity: f32,
    range: f32,
};

pub const SpotLightBlock = struct {
    position: [3]f32,
    direction: [3]f32,
    color: [3]f32,
    intensity: f32,
    range: f32,
    inner_angle_cos: f32,
    outer_angle_cos: f32,
};

pub const LightBlock = struct {
    directional_lights: []DirectionalLightBlock,
    point_lights: []PointLightBlock,
    spot_lights: []SpotLightBlock,
};

pub const DebugBlock = struct {
    show_grid: bool = false,
    show_bones: bool = false,
    show_collision: bool = false,
};

pub const PreparedScene = struct {
    allocator: std.mem.Allocator,
    camera: CameraBlock,
    view_matrix: [16]f32,
    projection_matrix: [16]f32,
    view_projection: [16]f32,
    camera_world_position: [4]f32,
    lights: LightBlock,
    light_space_matrix: [16]f32,
    cascade_matrices: [csm_cascade_count][16]f32 = .{ math.identity(), math.identity(), math.identity(), math.identity() },
    cascade_splits: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    shadow_maps: [csm_cascade_count]?*const rhi_mod.Texture = .{ null, null, null, null },
    shadow_sampler: ?*const rhi_mod.Sampler,
    texture_sampler: ?*const rhi_mod.Sampler,
    rt_shadow_mask: ?*const rhi_mod.Texture = null,
    rt_shadow_strength: f32 = 1.0,
    rt_shadow_ambient_floor: f32 = 0.12,
    environment_map: ?*const rhi_mod.Texture = null,
    irradiance_map: ?*const rhi_mod.Texture = null,
    prefiltered_env_map: ?*const rhi_mod.Texture = null,
    brdf_lut: ?*const rhi_mod.Texture = null,
    ambient_color: [4]f32,
    opaque_meshes: []DrawItem,
    transparent_meshes: []DrawItem,
    debug: DebugBlock,

    pub fn deinit(self: *PreparedScene) void {
        self.allocator.free(self.lights.directional_lights);
        self.allocator.free(self.lights.point_lights);
        self.allocator.free(self.lights.spot_lights);
        self.allocator.free(self.opaque_meshes);
        self.allocator.free(self.transparent_meshes);
        self.* = undefined;
    }
};

const CameraState = struct {
    transform: components.Transform,
    camera: components.Camera,
};

const LightState = struct {
    direction: [3]f32,
    color: [3]f32,
    intensity: f32,
};

const PointLightState = struct {
    position: [3]f32,
    color: [3]f32,
    intensity: f32,
    range: f32,
};

const CachedMesh = struct {
    handle: handles.MeshHandle,
    vertex_buffer: rhi_mod.Buffer,
    index_buffer: rhi_mod.Buffer,
    index_count: u32,
    wireframe_index_buffer: rhi_mod.Buffer,
    wireframe_index_count: u32,
    primitive_type: rhi_types.PrimitiveType,
};

const CachedTexture = struct {
    handle: handles.TextureHandle,
    texture: rhi_mod.Texture,
    source_pixels_ptr: usize,
    source_pixels_len: usize,
    source_width: u32,
    source_height: u32,
    source_format: rhi_types.TextureFormat,
};

const CachedMaterial = struct {
    handle: handles.MaterialHandle,
    bind_group: rhi_mod.BindGroup,
};

const MaterialState = struct {
    bind_group: rhi_mod.BindGroup,
    material_textures: [5]*const rhi_mod.Texture, // [0]=base_color [1]=mr [2]=normal [3]=occlusion [4]=emissive
    base_color_factor: [4]f32,
    emissive_factor: [4]f32,
    pbr_factors: [4]f32,
    has_textures: [4]u32,
    ibl_params: [4]f32,
};

const SkinningState = struct {
    meta: [4]u32 = .{ 0, 0, 0, 0 },
    matrices: [max_skin_joints][16]f32 = identitySkinMatrices(),
};

const fallback_white_bgra = [_]u8{
    0xFF, 0xFF, 0xFF, 0xFF,
};

pub const MeshSceneCache = struct {
    allocator: std.mem.Allocator,
    meshes: std.ArrayList(CachedMesh) = .empty,
    textures: std.ArrayList(CachedTexture) = .empty,
    materials: std.ArrayList(CachedMaterial) = .empty,
    fallback_texture: ?rhi_mod.Texture = null,
    fallback_brdf_lut: ?rhi_mod.Texture = null,
    sampler: ?rhi_mod.Sampler = null,
    fallback_bind_group: ?rhi_mod.BindGroup = null,

    pub fn init(allocator: std.mem.Allocator, device: *rhi_mod.RhiDevice) !MeshSceneCache {
        var cache = MeshSceneCache{
            .allocator = allocator,
        };
        try cache.createFallbackResources(device);
        return cache;
    }

    pub fn deinit(self: *MeshSceneCache, device: *rhi_mod.RhiDevice) void {
        for (self.materials.items) |*material| {
            device.releaseBindGroup(&material.bind_group);
        }
        self.materials.deinit(self.allocator);

        for (self.textures.items) |*texture| {
            device.releaseTexture(&texture.texture);
        }
        self.textures.deinit(self.allocator);

        for (self.meshes.items) |*mesh| {
            device.releaseBuffer(&mesh.wireframe_index_buffer);
            device.releaseBuffer(&mesh.index_buffer);
            device.releaseBuffer(&mesh.vertex_buffer);
        }
        self.meshes.deinit(self.allocator);

        if (self.fallback_bind_group) |*bind_group| {
            device.releaseBindGroup(bind_group);
        }
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        if (self.fallback_brdf_lut) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.fallback_texture) |*texture| {
            device.releaseTexture(texture);
        }
        self.* = undefined;
    }

    pub fn invalidateMaterialResources(self: *MeshSceneCache, device: *rhi_mod.RhiDevice) void {
        for (self.materials.items) |*material| {
            device.releaseBindGroup(&material.bind_group);
        }
        self.materials.deinit(self.allocator);
        self.materials = .empty;

        for (self.textures.items) |*texture| {
            device.releaseTexture(&texture.texture);
        }
        self.textures.deinit(self.allocator);
        self.textures = .empty;
    }

    pub fn invalidateAllResources(self: *MeshSceneCache, device: *rhi_mod.RhiDevice) void {
        self.invalidateMaterialResources(device);
        for (self.meshes.items) |*cached_mesh| {
            device.releaseBuffer(&cached_mesh.wireframe_index_buffer);
            device.releaseBuffer(&cached_mesh.index_buffer);
            device.releaseBuffer(&cached_mesh.vertex_buffer);
        }
        self.meshes.deinit(self.allocator);
        self.meshes = .empty;
    }

    pub fn invalidateMeshResource(
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        handle: handles.MeshHandle,
    ) void {
        var index: usize = 0;
        while (index < self.meshes.items.len) {
            if (self.meshes.items[index].handle != handle) {
                index += 1;
                continue;
            }

            var cached = self.meshes.swapRemove(index);
            device.releaseBuffer(&cached.wireframe_index_buffer);
            device.releaseBuffer(&cached.index_buffer);
            device.releaseBuffer(&cached.vertex_buffer);
        }
    }

    pub fn resolvePrimaryCamera(self: *MeshSceneCache, render_world: *const scene_extraction.RenderWorld) ?CameraBlock {
        _ = self;
        for (render_world.cameras.items) |camera| {
            if (camera.camera.is_primary) {
                return .{
                    .transform = camera.transform,
                    .camera = camera.camera,
                    .is_primary = true,
                };
            }
        }
        if (render_world.cameras.items.len > 0) {
            const first = render_world.cameras.items[0];
            return .{
                .transform = first.transform,
                .camera = first.camera,
                .is_primary = false,
            };
        }
        return null;
    }

    pub fn calculateViewMatrix(self: *MeshSceneCache, camera: CameraBlock) [16]f32 {
        _ = self;
        return math.viewMatrix(camera.transform);
    }

    pub fn calculateProjectionMatrix(self: *MeshSceneCache, camera: CameraBlock, width: u32, height: u32) [16]f32 {
        _ = self;
        const aspect = if (height == 0) 1.0 else @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
        return math.projectionForCamera(camera.camera, aspect);
    }

    pub fn calculateViewProjection(self: *MeshSceneCache, camera: CameraBlock, width: u32, height: u32) [16]f32 {
        const view = self.calculateViewMatrix(camera);
        const projection = self.calculateProjectionMatrix(camera, width, height);
        return math.mul(projection, view);
    }

    pub fn prepareScene(
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        world: *const scene_mod.World,
        render_world: *const scene_extraction.RenderWorld,
        width: u32,
        height: u32,
    ) !PreparedScene {
        const camera_block = self.resolvePrimaryCamera(render_world) orelse {
            return error.NoPrimaryCamera;
        };

        const view_matrix = self.calculateViewMatrix(camera_block);
        const projection_matrix = self.calculateProjectionMatrix(camera_block, width, height);
        const view_projection = math.mul(projection_matrix, view_matrix);
        const frustum = frustum_mod.Frustum.fromViewProjection(view_projection);

        const lights = try self.collectPreparedLights(render_world, frustum);
        errdefer {
            self.allocator.free(lights.directional_lights);
            self.allocator.free(lights.point_lights);
            self.allocator.free(lights.spot_lights);
        }

        var opaque_meshes = std.ArrayList(DrawItem).empty;
        defer opaque_meshes.deinit(self.allocator);
        var transparent_meshes = std.ArrayList(DrawItem).empty;
        defer transparent_meshes.deinit(self.allocator);

        try self.appendPreparedMeshes(
            device,
            world,
            render_world,
            true,
            frustum,
            null,
            &opaque_meshes,
            &transparent_meshes,
        );
        sortTransparentMeshes(transparent_meshes.items, camera_block.transform.translation);

        return .{
            .allocator = self.allocator,
            .camera = camera_block,
            .view_matrix = view_matrix,
            .projection_matrix = projection_matrix,
            .view_projection = view_projection,
            .camera_world_position = .{
                camera_block.transform.translation[0],
                camera_block.transform.translation[1],
                camera_block.transform.translation[2],
                1.0,
            },
            .lights = lights,
            .light_space_matrix = math.identity(),
            .shadow_sampler = null,
            .texture_sampler = &self.sampler.?,
            .ambient_color = .{ 0.06, 0.06, 0.065, 1.0 },
            .opaque_meshes = try opaque_meshes.toOwnedSlice(self.allocator),
            .transparent_meshes = try transparent_meshes.toOwnedSlice(self.allocator),
            .debug = .{},
        };
    }

    pub fn preparePreviewScene(
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        world: *const scene_mod.World,
        render_world: *const scene_extraction.RenderWorld,
        reference: *const PreparedScene,
        preview_roots: []const scene_mod.EntityId,
    ) !PreparedScene {
        const frustum = frustum_mod.Frustum.fromViewProjection(reference.view_projection);
        const lights = try self.collectPreparedLights(render_world, frustum);
        errdefer {
            self.allocator.free(lights.directional_lights);
            self.allocator.free(lights.point_lights);
            self.allocator.free(lights.spot_lights);
        }
        var opaque_meshes = std.ArrayList(DrawItem).empty;
        defer opaque_meshes.deinit(self.allocator);
        var transparent_meshes = std.ArrayList(DrawItem).empty;
        defer transparent_meshes.deinit(self.allocator);

        try self.appendPreparedMeshes(
            device,
            world,
            render_world,
            false,
            frustum,
            preview_roots,
            &opaque_meshes,
            &transparent_meshes,
        );
        sortTransparentMeshes(transparent_meshes.items, .{
            reference.camera_world_position[0],
            reference.camera_world_position[1],
            reference.camera_world_position[2],
        });

        return .{
            .allocator = self.allocator,
            .camera = reference.camera,
            .view_matrix = reference.view_matrix,
            .projection_matrix = reference.projection_matrix,
            .view_projection = reference.view_projection,
            .camera_world_position = reference.camera_world_position,
            .lights = lights,
            .light_space_matrix = reference.light_space_matrix,
            .cascade_matrices = reference.cascade_matrices,
            .cascade_splits = reference.cascade_splits,
            .shadow_maps = reference.shadow_maps,
            .shadow_sampler = reference.shadow_sampler,
            .texture_sampler = reference.texture_sampler,
            .rt_shadow_mask = reference.rt_shadow_mask,
            .rt_shadow_strength = reference.rt_shadow_strength,
            .rt_shadow_ambient_floor = reference.rt_shadow_ambient_floor,
            .environment_map = reference.environment_map,
            .irradiance_map = reference.irradiance_map,
            .prefiltered_env_map = reference.prefiltered_env_map,
            .brdf_lut = reference.brdf_lut,
            .ambient_color = reference.ambient_color,
            .opaque_meshes = try opaque_meshes.toOwnedSlice(self.allocator),
            .transparent_meshes = try transparent_meshes.toOwnedSlice(self.allocator),
            .debug = .{},
        };
    }

    pub fn defaultSelectionEntity(self: *MeshSceneCache, scene: *const scene_mod.Scene) ?scene_mod.EntityId {
        _ = self;
        if (scene.findEntityByName("Spinner")) |entity| {
            return entity.id;
        }
        for (scene.entities.items) |entity| {
            if (entity.editor_only) {
                continue;
            }
            if (entity.mesh != null) {
                return entity.id;
            }
        }
        return null;
    }

    pub fn fallbackBrdfLut(self: *const MeshSceneCache) ?*const rhi_mod.Texture {
        if (self.fallback_brdf_lut) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn ensureTextureHandle(
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        world: *const scene_mod.World,
        handle: handles.TextureHandle,
    ) !*rhi_mod.Texture {
        const texture = world.resources.texture(handle) orelse return error.TextureNotFound;
        return self.ensureTexture(device, handle, texture);
    }

    fn createFallbackResources(self: *MeshSceneCache, device: *rhi_mod.RhiDevice) !void {
        self.fallback_texture = try device.createTexture(.{
            .width = 1,
            .height = 1,
            .format = .bgra8_unorm,
            .usage = rhi_types.TextureUsage.sampler,
        });
        try device.uploadTextureData(&self.fallback_texture.?, fallback_white_bgra[0..], 1, 1);

        const brdf_lut_bytes = try fallbackBrdfLutBytes(self.allocator, 128);
        defer self.allocator.free(brdf_lut_bytes);

        self.fallback_brdf_lut = try device.createTexture(.{
            .width = 128,
            .height = 128,
            .format = .rgba32_float,
            .usage = rhi_types.TextureUsage.sampler,
        });
        errdefer if (self.fallback_brdf_lut) |*texture| {
            device.releaseTexture(texture);
        };
        try device.uploadTextureData(&self.fallback_brdf_lut.?, brdf_lut_bytes, 128, 128);

        self.sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .repeat,
            .address_mode_v = .repeat,
            .address_mode_w = .repeat,
        });

        const bindings = [_]rhi_mod.TextureSamplerBinding{
            .{ .texture = &self.fallback_texture.?, .sampler = &self.sampler.? },
            .{ .texture = &self.fallback_texture.?, .sampler = &self.sampler.? },
            .{ .texture = &self.fallback_texture.?, .sampler = &self.sampler.? },
            .{ .texture = &self.fallback_texture.?, .sampler = &self.sampler.? },
            .{ .texture = &self.fallback_texture.?, .sampler = &self.sampler.? },
        };
        self.fallback_bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });
    }

    // 确保指定 mesh 的 GPU 缓存存在：
    // 1) 检查缓存，若存在直接返回 CachedMesh
    // 2) 创建 GPU 顶点/索引缓冲并上传数据（将 CPU `Vertex` 转换为 `GpuVertex`）
    // 3) 构建并上传线框索引（wireframe indices）以支持线框渲染
    // 4) 将结果写入缓存并返回
    fn ensureMesh(
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        handle: handles.MeshHandle,
        mesh: *const mesh_mod.MeshResource,
    ) !CachedMesh {
        // 查找缓存，避免重复创建 GPU 资源
        for (self.meshes.items) |cached| {
            if (cached.handle == handle) {
                return cached;
            }
        }

        // 创建顶点缓冲（GPU），大小按 GpuVertex * 顶点数
        const vertex_buffer = try device.createBuffer(.{
            .size = @intCast(@sizeOf(GpuVertex) * mesh.vertices.len),
            .usage = rhi_types.BufferUsage.vertex,
        });
        // 出错时释放已经创建的 buffer
        errdefer {
            var copy = vertex_buffer;
            device.releaseBuffer(&copy);
        }

        // 在临时内存中把 CPU 顶点打包为与 shader 匹配的 GpuVertex 布局
        const gpu_vertices = try self.allocator.alloc(GpuVertex, mesh.vertices.len);
        defer self.allocator.free(gpu_vertices);
        for (mesh.vertices, 0..) |vertex, index| {
            gpu_vertices[index] = .{
                .position = vertex.position,
                .normal = vertex.normal,
                .color = vertex.color,
                .uv = vertex.uv,
                // 注意：将 16-bit 的 joint 索引转换为 float，shader 端期望 float 存储（或根据 shader 修改）
                .joints = .{
                    @floatFromInt(vertex.joints[0]),
                    @floatFromInt(vertex.joints[1]),
                    @floatFromInt(vertex.joints[2]),
                    @floatFromInt(vertex.joints[3]),
                },
                .weights = vertex.weights,
            };
        }
        // 上传顶点数据到 GPU
        try device.uploadBufferData(&vertex_buffer, std.mem.sliceAsBytes(gpu_vertices));

        // 创建并上传索引缓冲（u32）
        const index_buffer = try device.createBuffer(.{
            .size = @intCast(@sizeOf(u32) * mesh.indices.len),
            .usage = rhi_types.BufferUsage.index,
        });
        errdefer {
            var copy = index_buffer;
            device.releaseBuffer(&copy);
        }
        try device.uploadBufferData(&index_buffer, std.mem.sliceAsBytes(mesh.indices));

        // 为线框渲染构建边索引并上传
        const wireframe_indices = try buildWireframeIndices(self.allocator, mesh.indices);
        defer self.allocator.free(wireframe_indices);
        const wireframe_index_buffer = try device.createBuffer(.{
            .size = @intCast(@sizeOf(u32) * wireframe_indices.len),
            .usage = rhi_types.BufferUsage.index,
        });
        errdefer {
            var copy = wireframe_index_buffer;
            device.releaseBuffer(&copy);
        }
        try device.uploadBufferData(&wireframe_index_buffer, std.mem.sliceAsBytes(wireframe_indices));

        // 构建缓存记录并保存
        const cached = CachedMesh{
            .handle = handle,
            .vertex_buffer = vertex_buffer,
            .index_buffer = index_buffer,
            .index_count = @intCast(mesh.indices.len),
            .wireframe_index_buffer = wireframe_index_buffer,
            .wireframe_index_count = @intCast(wireframe_indices.len),
            .primitive_type = mesh.primitive_type,
        };
        try self.meshes.append(self.allocator, cached);
        return cached;
    }

    fn buildWireframeIndices(allocator: std.mem.Allocator, triangle_indices: []const u32) ![]u32 {
        var edges = std.ArrayList(u32).empty;
        defer edges.deinit(allocator);
        var seen = std.AutoHashMap(u64, void).init(allocator);
        defer seen.deinit();

        var triangle_index: usize = 0;
        while (triangle_index + 2 < triangle_indices.len) : (triangle_index += 3) {
            const a = triangle_indices[triangle_index];
            const b = triangle_indices[triangle_index + 1];
            const c = triangle_indices[triangle_index + 2];
            try appendWireframeEdge(allocator, &edges, &seen, a, b);
            try appendWireframeEdge(allocator, &edges, &seen, b, c);
            try appendWireframeEdge(allocator, &edges, &seen, c, a);
        }

        return edges.toOwnedSlice(allocator);
    }

    fn appendWireframeEdge(
        allocator: std.mem.Allocator,
        edges: *std.ArrayList(u32),
        seen: *std.AutoHashMap(u64, void),
        first: u32,
        second: u32,
    ) !void {
        const edge_min = @min(first, second);
        const edge_max = @max(first, second);
        const key = (@as(u64, edge_min) << 32) | @as(u64, edge_max);
        const entry = try seen.getOrPut(key);
        if (entry.found_existing) {
            return;
        }
        try edges.append(allocator, first);
        try edges.append(allocator, second);
    }

    fn ensureTexture(
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        handle: handles.TextureHandle,
        texture: *const texture_mod.TextureResource,
    ) !*rhi_mod.Texture {
        for (self.textures.items) |*cached| {
            if (cached.handle == handle) {
                const src_ptr = if (texture.pixels.len > 0) @intFromPtr(texture.pixels.ptr) else 0;
                const source_changed = cached.source_pixels_ptr != src_ptr or
                    cached.source_pixels_len != texture.pixels.len or
                    cached.source_width != texture.width or
                    cached.source_height != texture.height or
                    cached.source_format != texture.format;

                if (source_changed) {
                    const size_or_format_changed =
                        cached.texture.desc.width != texture.width or
                        cached.texture.desc.height != texture.height or
                        cached.texture.desc.format != texture.format;

                    if (size_or_format_changed) {
                        device.releaseTexture(&cached.texture);
                        cached.texture = try device.createTexture(.{
                            .width = texture.width,
                            .height = texture.height,
                            .format = texture.format,
                            .usage = rhi_types.TextureUsage.sampler,
                        });
                    }
                    try device.uploadTextureData(&cached.texture, texture.pixels, texture.width, texture.height);
                    cached.source_pixels_ptr = src_ptr;
                    cached.source_pixels_len = texture.pixels.len;
                    cached.source_width = texture.width;
                    cached.source_height = texture.height;
                    cached.source_format = texture.format;
                }
                return &cached.texture;
            }
        }

        const gpu_texture = try device.createTexture(.{
            .width = texture.width,
            .height = texture.height,
            .format = texture.format,
            .usage = rhi_types.TextureUsage.sampler,
        });
        errdefer {
            var copy = gpu_texture;
            device.releaseTexture(&copy);
        }
        try device.uploadTextureData(&gpu_texture, texture.pixels, texture.width, texture.height);

        try self.textures.append(self.allocator, .{
            .handle = handle,
            .texture = gpu_texture,
            .source_pixels_ptr = if (texture.pixels.len > 0) @intFromPtr(texture.pixels.ptr) else 0,
            .source_pixels_len = texture.pixels.len,
            .source_width = texture.width,
            .source_height = texture.height,
            .source_format = texture.format,
        });
        return &self.textures.items[self.textures.items.len - 1].texture;
    }

    fn ensureMaterial(
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        handle: handles.MaterialHandle,
        material: *const material_mod.MaterialResource,
        scene: *const scene_mod.World,
    ) !?rhi_mod.BindGroup {
        for (self.materials.items) |cached| {
            if (cached.handle == handle) {
                return cached.bind_group;
            }
        }

        const base_color_tex = if (material.base_color_texture) |h| try self.ensureTexture(device, h, scene.resources.texture(h).?) else &self.fallback_texture.?;
        const metallic_roughness_tex = if (material.metallic_roughness_texture) |h| try self.ensureTexture(device, h, scene.resources.texture(h).?) else &self.fallback_texture.?;
        const normal_tex = if (material.normal_texture) |h| try self.ensureTexture(device, h, scene.resources.texture(h).?) else &self.fallback_texture.?;
        const occlusion_tex = if (material.occlusion_texture) |h| try self.ensureTexture(device, h, scene.resources.texture(h).?) else &self.fallback_texture.?;
        const emissive_tex = if (material.emissive_texture) |h| try self.ensureTexture(device, h, scene.resources.texture(h).?) else &self.fallback_texture.?;

        const bindings = [_]rhi_mod.TextureSamplerBinding{
            .{ .texture = base_color_tex, .sampler = &self.sampler.? },
            .{ .texture = metallic_roughness_tex, .sampler = &self.sampler.? },
            .{ .texture = normal_tex, .sampler = &self.sampler.? },
            .{ .texture = occlusion_tex, .sampler = &self.sampler.? },
            .{ .texture = emissive_tex, .sampler = &self.sampler.? },
        };

        const bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = bindings[0..],
        });
        try self.materials.append(self.allocator, .{
            .handle = handle,
            .bind_group = bind_group,
        });
        return bind_group;
    }

    fn resolveMaterial(
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        scene: *const scene_mod.World,
        material_component: ?components.Material,
    ) !MaterialState {
        var state = MaterialState{
            .bind_group = self.fallback_bind_group.?,
            .material_textures = .{
                &self.fallback_texture.?,
                &self.fallback_texture.?,
                &self.fallback_texture.?,
                &self.fallback_texture.?,
                &self.fallback_texture.?,
            },
            .base_color_factor = [4]f32{ 1.0, 1.0, 1.0, 1.0 },
            .emissive_factor = .{ 0.0, 0.0, 0.0, 0.0 },
            .pbr_factors = .{ 1.0, 1.0, 0.5, 0.0 },
            .has_textures = .{ 0, 0, 0, 0 },
            .ibl_params = .{ 1.0, 1.0, 0.0, 0.0 },
        };

        const material_value = material_component orelse return state;
        state.base_color_factor = material_value.base_color_factor;

        const material_handle = material_value.handle orelse return state;
        const material = scene.resources.material(material_handle) orelse return state;
        const material_ast = material_ast_mod.MaterialAst.fromResource(material);

        state.base_color_factor = .{
            material_ast.base_color_factor[0] * material_value.base_color_factor[0],
            material_ast.base_color_factor[1] * material_value.base_color_factor[1],
            material_ast.base_color_factor[2] * material_value.base_color_factor[2],
            material_ast.base_color_factor[3] * material_value.base_color_factor[3],
        };
        state.emissive_factor = .{
            material_ast.emissive_factor[0],
            material_ast.emissive_factor[1],
            material_ast.emissive_factor[2],
            1.0,
        };
        state.pbr_factors = .{ material_ast.metallic_factor, material_ast.roughness_factor, material_ast.alpha_cutoff, 0.0 };
        state.has_textures = .{
            if (material_ast.textures.base_color != null) 1 else 0,
            if (material_ast.textures.metallic_roughness != null) 1 else 0,
            if (material_ast.textures.normal != null) 1 else 0,
            if (material_ast.textures.occlusion != null) 1 else 0,
        };
        state.ibl_params = .{
            if (material_ast.use_ibl) 1.0 else 0.0,
            material_ast.ibl_intensity,
            0.0,
            0.0,
        };
        state.material_textures = .{
            if (material_ast.textures.base_color) |h| try self.ensureTexture(device, h, scene.resources.texture(h).?) else &self.fallback_texture.?,
            if (material_ast.textures.metallic_roughness) |h| try self.ensureTexture(device, h, scene.resources.texture(h).?) else &self.fallback_texture.?,
            if (material_ast.textures.normal) |h| try self.ensureTexture(device, h, scene.resources.texture(h).?) else &self.fallback_texture.?,
            if (material_ast.textures.occlusion) |h| try self.ensureTexture(device, h, scene.resources.texture(h).?) else &self.fallback_texture.?,
            if (material_ast.textures.emissive) |h| try self.ensureTexture(device, h, scene.resources.texture(h).?) else &self.fallback_texture.?,
        };

        if (try self.ensureMaterial(device, material_handle, material, scene)) |bind_group| {
            state.bind_group = bind_group;
        }
        return state;
    }

    fn collectPreparedLights(
        self: *MeshSceneCache,
        render_world: *const scene_extraction.RenderWorld,
        frustum: frustum_mod.Frustum,
    ) !LightBlock {
        const spot_inner_angle_cos: f32 = 0.9063078; // cos(25 deg)
        const spot_outer_angle_cos: f32 = 0.81915206; // cos(35 deg)
        var directional_lights = std.ArrayList(DirectionalLightBlock).empty;
        defer directional_lights.deinit(self.allocator);
        var point_lights = std.ArrayList(PointLightBlock).empty;
        defer point_lights.deinit(self.allocator);
        var spot_lights = std.ArrayList(SpotLightBlock).empty;
        defer spot_lights.deinit(self.allocator);

        for (render_world.lights.directional.items) |render_light| {
            const light = render_light.light;
            const world_transform = render_light.transform;
            const direction = quat.rotateVec3(world_transform.rotation, .{ 0.0, 0.0, -1.0 });
            try directional_lights.append(self.allocator, .{
                .direction = direction,
                .color = light.color,
                .intensity = light.intensity,
            });
        }

        for (render_world.lights.point.items) |render_light| {
            const light = render_light.light;
            const world_transform = render_light.transform;
            const light_bounds = @import("../../math/aabb.zig").AABB{
                .min = .{
                    world_transform.translation[0] - light.range,
                    world_transform.translation[1] - light.range,
                    world_transform.translation[2] - light.range,
                },
                .max = .{
                    world_transform.translation[0] + light.range,
                    world_transform.translation[1] + light.range,
                    world_transform.translation[2] + light.range,
                },
            };
            if (!frustum.intersectsAABB(light_bounds)) continue;

            try point_lights.append(self.allocator, .{
                .position = world_transform.translation,
                .color = light.color,
                .intensity = light.intensity,
                .range = light.range,
            });
        }

        for (render_world.lights.spot.items) |render_light| {
            const light = render_light.light;
            const world_transform = render_light.transform;
            const light_bounds = @import("../../math/aabb.zig").AABB{
                .min = .{
                    world_transform.translation[0] - light.range,
                    world_transform.translation[1] - light.range,
                    world_transform.translation[2] - light.range,
                },
                .max = .{
                    world_transform.translation[0] + light.range,
                    world_transform.translation[1] + light.range,
                    world_transform.translation[2] + light.range,
                },
            };
            if (!frustum.intersectsAABB(light_bounds)) continue;

            try spot_lights.append(self.allocator, .{
                .position = world_transform.translation,
                .direction = quat.rotateVec3(world_transform.rotation, .{ 0.0, 0.0, -1.0 }),
                .color = light.color,
                .intensity = light.intensity,
                .range = light.range,
                .inner_angle_cos = spot_inner_angle_cos,
                .outer_angle_cos = spot_outer_angle_cos,
            });
        }

        return .{
            .directional_lights = try directional_lights.toOwnedSlice(self.allocator),
            .point_lights = try point_lights.toOwnedSlice(self.allocator),
            .spot_lights = try spot_lights.toOwnedSlice(self.allocator),
        };
    }

    fn appendPreparedMeshes(
        self: *MeshSceneCache,
        device: *rhi_mod.RhiDevice,
        world: *const scene_mod.World,
        render_world: *const scene_extraction.RenderWorld,
        pickable: bool,
        frustum: frustum_mod.Frustum,
        preview_roots: ?[]const scene_mod.EntityId,
        opaque_meshes: *std.ArrayList(DrawItem),
        transparent_meshes: *std.ArrayList(DrawItem),
    ) !void {
        // Pre-warm the texture cache so that all unique textures are uploaded
        // before any DrawItem stores a pointer into self.textures.items.
        // Without this, ensureTexture() may grow the ArrayList during DrawItem
        // creation, invalidating pointers stored in earlier DrawItems.
        for (render_world.meshes.items) |render_mesh| {
            if (render_mesh.material) |material_comp| {
                if (material_comp.handle) |mat_handle| {
                    if (world.resources.material(mat_handle)) |material| {
                        inline for (.{
                            material.base_color_texture,
                            material.metallic_roughness_texture,
                            material.normal_texture,
                            material.occlusion_texture,
                            material.emissive_texture,
                        }) |maybe_tex| {
                            if (maybe_tex) |h| {
                                if (world.resources.texture(h)) |tex| {
                                    _ = try self.ensureTexture(device, h, tex);
                                }
                            }
                        }
                    }
                }
            }
        }

        for (render_world.meshes.items) |render_mesh| {
            if (preview_roots) |roots| {
                if (!entityMatchesPreviewRoots(world, render_mesh.entity_id, roots)) {
                    continue;
                }
            }
            if (world.worldBoundsConst(render_mesh.entity_id)) |bounds| {
                if (!frustum.intersectsAABB(bounds)) {
                    continue;
                }
            }

            const mesh_component = render_mesh.mesh;
            const mesh_handle = mesh_component.handle orelse continue;
            const mesh = world.resources.mesh(mesh_handle) orelse continue;
            if (mesh.primitive_type != .triangle_list) continue;

            const gpu_mesh = try self.ensureMesh(device, mesh_handle, mesh);
            const material_state = try self.resolveMaterial(device, world, render_mesh.material);
            const skinning_state = buildSkinningState(world, render_mesh.entity_id, render_mesh.transform);

            const draw_item = DrawItem{
                .entity_id = render_mesh.entity_id,
                .pickable = pickable,
                .mesh_handle = mesh_handle,
                .vertex_buffer = gpu_mesh.vertex_buffer,
                .index_buffer = gpu_mesh.index_buffer,
                .index_count = gpu_mesh.index_count,
                .wireframe_index_buffer = gpu_mesh.wireframe_index_buffer,
                .wireframe_index_count = gpu_mesh.wireframe_index_count,
                .bind_group = material_state.bind_group,
                .material_textures = material_state.material_textures,
                .base_color_factor = material_state.base_color_factor,
                .emissive_factor = material_state.emissive_factor,
                .pbr_factors = material_state.pbr_factors,
                .has_textures = material_state.has_textures,
                .ibl_params = material_state.ibl_params,
                .model = render_mesh.transform.toMatrix(),
                .world_position = render_mesh.transform.translation,
                .skinning_meta = skinning_state.meta,
                .skin_matrices = skinning_state.matrices,
            };

            if (isTransparentMaterial(material_state)) {
                try transparent_meshes.append(self.allocator, draw_item);
            } else {
                try opaque_meshes.append(self.allocator, draw_item);
            }
        }
    }
};

fn isTransparentMaterial(material_state: MaterialState) bool {
    return material_state.base_color_factor[3] < 0.999;
}

fn entityMatchesPreviewRoots(
    world: *const scene_mod.World,
    entity_id: scene_mod.EntityId,
    preview_roots: []const scene_mod.EntityId,
) bool {
    var current_id: ?scene_mod.EntityId = entity_id;
    var guard: usize = 0;
    while (current_id) |resolved_id| : (guard += 1) {
        if (guard > world.entities.items.len) {
            return false;
        }
        for (preview_roots) |root_id| {
            if (root_id == resolved_id) {
                return true;
            }
        }
        const entity = world.getEntityConst(resolved_id) orelse return false;
        current_id = entity.parent;
    }
    return false;
}

fn sortTransparentMeshes(items: []DrawItem, camera_position: [3]f32) void {
    std.sort.heap(DrawItem, items, camera_position, lessThanTransparentDistance);
}

fn lessThanTransparentDistance(camera_position: [3]f32, a: DrawItem, b: DrawItem) bool {
    return distanceSquared(camera_position, a.world_position) > distanceSquared(camera_position, b.world_position);
}

fn distanceSquared(a: [3]f32, b: [3]f32) f32 {
    const dx = a[0] - b[0];
    const dy = a[1] - b[1];
    const dz = a[2] - b[2];
    return dx * dx + dy * dy + dz * dz;
}

fn buildSkinningState(
    world: *const scene_mod.World,
    entity_id: scene_mod.EntityId,
    model_transform: components.Transform,
) SkinningState {
    const entity = world.getEntityConst(entity_id) orelse return .{};
    const skinned_mesh = entity.skinned_mesh orelse return .{};
    const skin_handle = skinned_mesh.skin_handle orelse return .{};
    const targets = world.skinnedMeshTargets(entity_id) orelse return .{};
    const skin = world.resources.skin(skin_handle) orelse return .{};

    var state = SkinningState{};
    const joint_count = @min(skin.joint_entity_indices.len, max_skin_joints);
    if (joint_count == 0) {
        return state;
    }

    const inverse_model = math.inverseTransformMatrix(model_transform);
    state.meta[0] = 1;
    state.meta[1] = @intCast(joint_count);

    var joint_index: usize = 0;
    while (joint_index < joint_count) : (joint_index += 1) {
        const target_index = skin.joint_entity_indices[joint_index];
        if (target_index >= targets.len) {
            continue;
        }
        const joint_transform = world.worldTransformConst(targets[target_index]) orelse continue;
        const joint_matrix = joint_transform.toMatrix();
        state.matrices[joint_index] = math.mul(
            inverse_model,
            math.mul(joint_matrix, skin.inverse_bind_matrices[joint_index]),
        );
    }

    return state;
}

fn identitySkinMatrices() [max_skin_joints][16]f32 {
    var matrices: [max_skin_joints][16]f32 = undefined;
    for (&matrices) |*matrix_value| {
        matrix_value.* = math.identity();
    }
    return matrices;
}

fn fallbackBrdfLutBytes(allocator: std.mem.Allocator, size: u32) ![]u8 {
    const lut = try ibl_precompute.generateBRDFLUT(allocator, size);
    defer allocator.free(lut);

    const pixel_count = size * size;
    var rgba = try allocator.alloc(f32, pixel_count * 4);
    errdefer allocator.free(rgba);

    var index: usize = 0;
    while (index < pixel_count) : (index += 1) {
        const src = index * 2;
        const dst = index * 4;
        rgba[dst] = lut[src];
        rgba[dst + 1] = lut[src + 1];
        rgba[dst + 2] = 0.0;
        rgba[dst + 3] = 1.0;
    }

    const bytes = try allocator.alloc(u8, rgba.len * @sizeOf(f32));
    @memcpy(bytes, std.mem.sliceAsBytes(rgba));
    allocator.free(rgba);
    return bytes;
}
