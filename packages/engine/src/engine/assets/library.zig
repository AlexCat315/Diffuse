const std = @import("std");
const animation_clip_mod = @import("animation_clip_resource.zig");
const handles = @import("handles.zig");
const material_mod = @import("material_resource.zig");
const mesh_mod = @import("mesh_resource.zig");
const registry_mod = @import("registry.zig");
const skeleton_mod = @import("skeleton_resource.zig");
const skin_mod = @import("skin_resource.zig");
const texture_mod = @import("texture_resource.zig");
const script_mod = @import("script_resource.zig");
const components = @import("../scene/components.zig");
const job_system_mod = @import("../core/job_system.zig");

pub const ResourceLibrary = struct {
    allocator: std.mem.Allocator,
    job_system: ?*job_system_mod.JobSystem = null,
    meshes: std.ArrayList(mesh_mod.MeshResource) = .empty,
    materials: std.ArrayList(material_mod.MaterialResource) = .empty,
    textures: std.ArrayList(texture_mod.TextureResource) = .empty,
    skeletons: std.ArrayList(skeleton_mod.SkeletonResource) = .empty,
    skins: std.ArrayList(skin_mod.SkinResource) = .empty,
    animation_clips: std.ArrayList(animation_clip_mod.AnimationClipResource) = .empty,
    scripts: std.ArrayList(script_mod.ScriptResource) = .empty,
    asset_registry: registry_mod.AssetRegistry,
    mesh_records: std.AutoHashMap(handles.MeshHandle, usize),
    material_records: std.AutoHashMap(handles.MaterialHandle, usize),
    texture_records: std.AutoHashMap(handles.TextureHandle, usize),
    skeleton_records: std.AutoHashMap(handles.SkeletonHandle, usize),
    skin_records: std.AutoHashMap(handles.SkinHandle, usize),
    animation_clip_records: std.AutoHashMap(handles.AnimationClipHandle, usize),
    script_records: std.AutoHashMap(handles.ScriptHandle, usize),
    mesh_handles_by_asset_id: std.StringHashMap(handles.MeshHandle),
    material_handles_by_asset_id: std.StringHashMap(handles.MaterialHandle),
    texture_handles_by_asset_id: std.StringHashMap(handles.TextureHandle),
    skeleton_handles_by_asset_id: std.StringHashMap(handles.SkeletonHandle),
    skin_handles_by_asset_id: std.StringHashMap(handles.SkinHandle),
    animation_clip_handles_by_asset_id: std.StringHashMap(handles.AnimationClipHandle),
    script_handles_by_asset_id: std.StringHashMap(handles.ScriptHandle),
    cube_mesh: ?handles.MeshHandle = null,
    sphere_mesh: ?handles.MeshHandle = null,
    plane_mesh: ?handles.MeshHandle = null,
    default_material: ?handles.MaterialHandle = null,
    white_texture: ?handles.TextureHandle = null,
    default_albedo_texture: ?handles.TextureHandle = null,
    scene_environment_asset_id: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, job_system: ?*job_system_mod.JobSystem) ResourceLibrary {
        return .{
            .allocator = allocator,
            .job_system = job_system,
            .asset_registry = registry_mod.AssetRegistry.init(allocator),
            .mesh_records = std.AutoHashMap(handles.MeshHandle, usize).init(allocator),
            .material_records = std.AutoHashMap(handles.MaterialHandle, usize).init(allocator),
            .texture_records = std.AutoHashMap(handles.TextureHandle, usize).init(allocator),
            .skeleton_records = std.AutoHashMap(handles.SkeletonHandle, usize).init(allocator),
            .skin_records = std.AutoHashMap(handles.SkinHandle, usize).init(allocator),
            .animation_clip_records = std.AutoHashMap(handles.AnimationClipHandle, usize).init(allocator),
            .script_records = std.AutoHashMap(handles.ScriptHandle, usize).init(allocator),
            .mesh_handles_by_asset_id = std.StringHashMap(handles.MeshHandle).init(allocator),
            .material_handles_by_asset_id = std.StringHashMap(handles.MaterialHandle).init(allocator),
            .texture_handles_by_asset_id = std.StringHashMap(handles.TextureHandle).init(allocator),
            .skeleton_handles_by_asset_id = std.StringHashMap(handles.SkeletonHandle).init(allocator),
            .skin_handles_by_asset_id = std.StringHashMap(handles.SkinHandle).init(allocator),
            .animation_clip_handles_by_asset_id = std.StringHashMap(handles.AnimationClipHandle).init(allocator),
            .script_handles_by_asset_id = std.StringHashMap(handles.ScriptHandle).init(allocator),
        };
    }

    pub fn deinit(self: *ResourceLibrary) void {
        if (self.scene_environment_asset_id) |asset_id| {
            self.allocator.free(asset_id);
            self.scene_environment_asset_id = null;
        }
        freeHandleKeys(self.allocator, handles.AnimationClipHandle, &self.animation_clip_handles_by_asset_id);
        self.animation_clip_handles_by_asset_id.deinit();
        freeHandleKeys(self.allocator, handles.SkinHandle, &self.skin_handles_by_asset_id);
        self.skin_handles_by_asset_id.deinit();
        freeHandleKeys(self.allocator, handles.SkeletonHandle, &self.skeleton_handles_by_asset_id);
        self.skeleton_handles_by_asset_id.deinit();
        freeHandleKeys(self.allocator, handles.TextureHandle, &self.texture_handles_by_asset_id);
        self.texture_handles_by_asset_id.deinit();
        freeHandleKeys(self.allocator, handles.MaterialHandle, &self.material_handles_by_asset_id);
        self.material_handles_by_asset_id.deinit();
        freeHandleKeys(self.allocator, handles.MeshHandle, &self.mesh_handles_by_asset_id);
        self.mesh_handles_by_asset_id.deinit();
        freeHandleKeys(self.allocator, handles.ScriptHandle, &self.script_handles_by_asset_id);
        self.script_handles_by_asset_id.deinit();
        self.animation_clip_records.deinit();
        self.skin_records.deinit();
        self.skeleton_records.deinit();
        self.texture_records.deinit();
        self.material_records.deinit();
        self.mesh_records.deinit();
        self.script_records.deinit();
        self.asset_registry.deinit();

        for (self.meshes.items) |*mesh_resource| {
            mesh_resource.deinit(self.allocator);
        }
        self.meshes.deinit(self.allocator);

        for (self.materials.items) |*material_resource| {
            material_resource.deinit(self.allocator);
        }
        self.materials.deinit(self.allocator);

        for (self.textures.items) |*texture_resource| {
            texture_resource.deinit(self.allocator);
        }
        self.textures.deinit(self.allocator);

        for (self.skeletons.items) |*skeleton_resource| {
            skeleton_resource.deinit(self.allocator);
        }
        self.skeletons.deinit(self.allocator);

        for (self.skins.items) |*skin_resource| {
            skin_resource.deinit(self.allocator);
        }
        self.skins.deinit(self.allocator);

        for (self.animation_clips.items) |*clip_resource| {
            clip_resource.deinit(self.allocator);
        }
        self.animation_clips.deinit(self.allocator);

        for (self.scripts.items) |*script_resource| {
            script_mod.deinit(script_resource, self.allocator);
        }
        self.scripts.deinit(self.allocator);
    }

    pub fn createMesh(self: *ResourceLibrary, desc: mesh_mod.MeshResourceDesc) !handles.MeshHandle {
        const resource = try mesh_mod.clone(self.allocator, desc);
        try self.meshes.append(self.allocator, resource);
        return handles.meshHandle(self.meshes.items.len - 1);
    }

    pub fn createMaterial(self: *ResourceLibrary, desc: material_mod.MaterialResourceDesc) !handles.MaterialHandle {
        const resource = try material_mod.clone(self.allocator, desc);
        try self.materials.append(self.allocator, resource);
        return handles.materialHandle(self.materials.items.len - 1);
    }

    pub fn createTexture(self: *ResourceLibrary, desc: texture_mod.TextureResourceDesc) !handles.TextureHandle {
        const resource = try texture_mod.clone(self.allocator, desc);
        try self.textures.append(self.allocator, resource);
        return handles.textureHandle(self.textures.items.len - 1);
    }

    pub fn createSkeleton(self: *ResourceLibrary, desc: skeleton_mod.SkeletonResourceDesc) !handles.SkeletonHandle {
        const resource = try skeleton_mod.clone(self.allocator, desc);
        try self.skeletons.append(self.allocator, resource);
        return handles.skeletonHandle(self.skeletons.items.len - 1);
    }

    pub fn createSkin(self: *ResourceLibrary, desc: skin_mod.SkinResourceDesc) !handles.SkinHandle {
        const resource = try skin_mod.clone(self.allocator, desc);
        try self.skins.append(self.allocator, resource);
        return handles.skinHandle(self.skins.items.len - 1);
    }

    pub fn createAnimationClip(self: *ResourceLibrary, desc: animation_clip_mod.AnimationClipResourceDesc) !handles.AnimationClipHandle {
        const resource = try animation_clip_mod.clone(self.allocator, desc);
        try self.animation_clips.append(self.allocator, resource);
        return handles.animationClipHandle(self.animation_clips.items.len - 1);
    }

    pub fn createScript(self: *ResourceLibrary, desc: script_mod.ScriptResourceDesc) !handles.ScriptHandle {
        const resource = try script_mod.clone(self.allocator, desc);
        try self.scripts.append(self.allocator, resource);
        return handles.scriptHandle(self.scripts.items.len - 1);
    }

    pub fn sceneEnvironmentAssetId(self: *const ResourceLibrary) ?[]const u8 {
        return self.scene_environment_asset_id;
    }

    pub fn setSceneEnvironmentAssetId(self: *ResourceLibrary, asset_id: ?[]const u8) !bool {
        if (asset_id) |resolved_id| {
            if (self.scene_environment_asset_id) |existing| {
                if (std.mem.eql(u8, existing, resolved_id)) {
                    return false;
                }
            }

            const owned = try self.allocator.dupe(u8, resolved_id);
            if (self.scene_environment_asset_id) |existing| {
                self.allocator.free(existing);
            }
            self.scene_environment_asset_id = owned;
            return true;
        }

        if (self.scene_environment_asset_id) |existing| {
            self.allocator.free(existing);
            self.scene_environment_asset_id = null;
            return true;
        }
        return false;
    }

    pub fn mesh(self: *const ResourceLibrary, handle: handles.MeshHandle) ?*const mesh_mod.MeshResource {
        if (!handles.isValid(handle)) {
            return null;
        }
        const index = handles.indexOf(handle);
        if (index >= self.meshes.items.len) {
            return null;
        }
        return &self.meshes.items[index];
    }

    pub fn meshMutable(self: *ResourceLibrary, handle: handles.MeshHandle) ?*mesh_mod.MeshResource {
        if (!handles.isValid(handle)) {
            return null;
        }
        const index = handles.indexOf(handle);
        if (index >= self.meshes.items.len) {
            return null;
        }
        return &self.meshes.items[index];
    }

    pub fn material(self: *const ResourceLibrary, handle: handles.MaterialHandle) ?*const material_mod.MaterialResource {
        if (!handles.isValid(handle)) {
            return null;
        }
        const index = handles.indexOf(handle);
        if (index >= self.materials.items.len) {
            return null;
        }
        return &self.materials.items[index];
    }

    pub fn texture(self: *const ResourceLibrary, handle: handles.TextureHandle) ?*const texture_mod.TextureResource {
        if (!handles.isValid(handle)) {
            return null;
        }
        const index = handles.indexOf(handle);
        if (index >= self.textures.items.len) {
            return null;
        }
        return &self.textures.items[index];
    }

    pub fn skeleton(self: *const ResourceLibrary, handle: handles.SkeletonHandle) ?*const skeleton_mod.SkeletonResource {
        if (!handles.isValid(handle)) {
            return null;
        }
        const index = handles.indexOf(handle);
        if (index >= self.skeletons.items.len) {
            return null;
        }
        return &self.skeletons.items[index];
    }

    pub fn skin(self: *const ResourceLibrary, handle: handles.SkinHandle) ?*const skin_mod.SkinResource {
        if (!handles.isValid(handle)) {
            return null;
        }
        const index = handles.indexOf(handle);
        if (index >= self.skins.items.len) {
            return null;
        }
        return &self.skins.items[index];
    }

    pub fn animationClip(self: *const ResourceLibrary, handle: handles.AnimationClipHandle) ?*const animation_clip_mod.AnimationClipResource {
        if (!handles.isValid(handle)) {
            return null;
        }
        const index = handles.indexOf(handle);
        if (index >= self.animation_clips.items.len) {
            return null;
        }
        return &self.animation_clips.items[index];
    }

    pub fn script(self: *const ResourceLibrary, handle: handles.ScriptHandle) ?*const script_mod.ScriptResource {
        if (!handles.isValid(handle)) {
            return null;
        }
        const index = handles.indexOf(handle);
        if (index >= self.scripts.items.len) {
            return null;
        }
        return &self.scripts.items[index];
    }

    pub fn scriptMutable(self: *ResourceLibrary, handle: handles.ScriptHandle) ?*script_mod.ScriptResource {
        if (!handles.isValid(handle)) {
            return null;
        }
        const index = handles.indexOf(handle);
        if (index >= self.scripts.items.len) {
            return null;
        }
        return &self.scripts.items[index];
    }

    pub fn assetRecordById(self: *const ResourceLibrary, asset_id: []const u8) ?*const registry_mod.AssetRecord {
        return self.asset_registry.recordById(asset_id);
    }

    pub fn meshAssetId(self: *const ResourceLibrary, handle: handles.MeshHandle) ?[]const u8 {
        const record_index = self.mesh_records.get(handle) orelse return null;
        return self.asset_registry.records.items[record_index].id;
    }

    pub fn materialAssetId(self: *const ResourceLibrary, handle: handles.MaterialHandle) ?[]const u8 {
        const record_index = self.material_records.get(handle) orelse return null;
        return self.asset_registry.records.items[record_index].id;
    }

    pub fn textureAssetId(self: *const ResourceLibrary, handle: handles.TextureHandle) ?[]const u8 {
        const record_index = self.texture_records.get(handle) orelse return null;
        return self.asset_registry.records.items[record_index].id;
    }

    pub fn skeletonAssetId(self: *const ResourceLibrary, handle: handles.SkeletonHandle) ?[]const u8 {
        const record_index = self.skeleton_records.get(handle) orelse return null;
        return self.asset_registry.records.items[record_index].id;
    }

    pub fn skinAssetId(self: *const ResourceLibrary, handle: handles.SkinHandle) ?[]const u8 {
        const record_index = self.skin_records.get(handle) orelse return null;
        return self.asset_registry.records.items[record_index].id;
    }

    pub fn animationClipAssetId(self: *const ResourceLibrary, handle: handles.AnimationClipHandle) ?[]const u8 {
        const record_index = self.animation_clip_records.get(handle) orelse return null;
        return self.asset_registry.records.items[record_index].id;
    }

    pub fn scriptAssetId(self: *const ResourceLibrary, handle: handles.ScriptHandle) ?[]const u8 {
        const record_index = self.script_records.get(handle) orelse return null;
        return self.asset_registry.records.items[record_index].id;
    }

    pub fn meshHandleByAssetId(self: *const ResourceLibrary, asset_id: []const u8) ?handles.MeshHandle {
        return self.mesh_handles_by_asset_id.get(asset_id);
    }

    pub fn materialHandleByAssetId(self: *const ResourceLibrary, asset_id: []const u8) ?handles.MaterialHandle {
        return self.material_handles_by_asset_id.get(asset_id);
    }

    pub fn textureHandleByAssetId(self: *const ResourceLibrary, asset_id: []const u8) ?handles.TextureHandle {
        return self.texture_handles_by_asset_id.get(asset_id);
    }

    pub fn skeletonHandleByAssetId(self: *const ResourceLibrary, asset_id: []const u8) ?handles.SkeletonHandle {
        return self.skeleton_handles_by_asset_id.get(asset_id);
    }

    pub fn skinHandleByAssetId(self: *const ResourceLibrary, asset_id: []const u8) ?handles.SkinHandle {
        return self.skin_handles_by_asset_id.get(asset_id);
    }

    pub fn animationClipHandleByAssetId(self: *const ResourceLibrary, asset_id: []const u8) ?handles.AnimationClipHandle {
        return self.animation_clip_handles_by_asset_id.get(asset_id);
    }

    pub fn scriptHandleByAssetId(self: *const ResourceLibrary, asset_id: []const u8) ?handles.ScriptHandle {
        return self.script_handles_by_asset_id.get(asset_id);
    }

    pub fn bindMeshAssetRecord(self: *ResourceLibrary, handle: handles.MeshHandle, record: registry_mod.AssetRecord) ![]const u8 {
        const previous_id = if (self.meshAssetId(handle)) |value| try self.allocator.dupe(u8, value) else null;
        defer if (previous_id) |value| self.allocator.free(value);
        const resolved = try self.asset_registry.upsertOwned(record);
        try self.mesh_records.put(handle, indexForRecord(self, resolved.id).?);
        try bindHandleByAssetId(self.allocator, handles.MeshHandle, &self.mesh_handles_by_asset_id, handle, resolved.id, previous_id);
        return resolved.id;
    }

    pub fn bindMaterialAssetRecord(self: *ResourceLibrary, handle: handles.MaterialHandle, record: registry_mod.AssetRecord) ![]const u8 {
        const previous_id = if (self.materialAssetId(handle)) |value| try self.allocator.dupe(u8, value) else null;
        defer if (previous_id) |value| self.allocator.free(value);
        const resolved = try self.asset_registry.upsertOwned(record);
        try self.material_records.put(handle, indexForRecord(self, resolved.id).?);
        try bindHandleByAssetId(self.allocator, handles.MaterialHandle, &self.material_handles_by_asset_id, handle, resolved.id, previous_id);
        return resolved.id;
    }

    pub fn bindTextureAssetRecord(self: *ResourceLibrary, handle: handles.TextureHandle, record: registry_mod.AssetRecord) ![]const u8 {
        const previous_id = if (self.textureAssetId(handle)) |value| try self.allocator.dupe(u8, value) else null;
        defer if (previous_id) |value| self.allocator.free(value);
        const resolved = try self.asset_registry.upsertOwned(record);
        try self.texture_records.put(handle, indexForRecord(self, resolved.id).?);
        try bindHandleByAssetId(self.allocator, handles.TextureHandle, &self.texture_handles_by_asset_id, handle, resolved.id, previous_id);
        return resolved.id;
    }

    pub fn bindSkeletonAssetRecord(self: *ResourceLibrary, handle: handles.SkeletonHandle, record: registry_mod.AssetRecord) ![]const u8 {
        const previous_id = if (self.skeletonAssetId(handle)) |value| try self.allocator.dupe(u8, value) else null;
        defer if (previous_id) |value| self.allocator.free(value);
        const resolved = try self.asset_registry.upsertOwned(record);
        try self.skeleton_records.put(handle, indexForRecord(self, resolved.id).?);
        try bindHandleByAssetId(self.allocator, handles.SkeletonHandle, &self.skeleton_handles_by_asset_id, handle, resolved.id, previous_id);
        return resolved.id;
    }

    pub fn bindSkinAssetRecord(self: *ResourceLibrary, handle: handles.SkinHandle, record: registry_mod.AssetRecord) ![]const u8 {
        const previous_id = if (self.skinAssetId(handle)) |value| try self.allocator.dupe(u8, value) else null;
        defer if (previous_id) |value| self.allocator.free(value);
        const resolved = try self.asset_registry.upsertOwned(record);
        try self.skin_records.put(handle, indexForRecord(self, resolved.id).?);
        try bindHandleByAssetId(self.allocator, handles.SkinHandle, &self.skin_handles_by_asset_id, handle, resolved.id, previous_id);
        return resolved.id;
    }

    pub fn bindAnimationClipAssetRecord(self: *ResourceLibrary, handle: handles.AnimationClipHandle, record: registry_mod.AssetRecord) ![]const u8 {
        const previous_id = if (self.animationClipAssetId(handle)) |value| try self.allocator.dupe(u8, value) else null;
        defer if (previous_id) |value| self.allocator.free(value);
        const resolved = try self.asset_registry.upsertOwned(record);
        try self.animation_clip_records.put(handle, indexForRecord(self, resolved.id).?);
        try bindHandleByAssetId(self.allocator, handles.AnimationClipHandle, &self.animation_clip_handles_by_asset_id, handle, resolved.id, previous_id);
        return resolved.id;
    }

    pub fn bindScriptAssetRecord(self: *ResourceLibrary, handle: handles.ScriptHandle, record: registry_mod.AssetRecord) ![]const u8 {
        const previous_id = if (self.scriptAssetId(handle)) |value| try self.allocator.dupe(u8, value) else null;
        defer if (previous_id) |value| self.allocator.free(value);
        const resolved = try self.asset_registry.upsertOwned(record);
        try self.script_records.put(handle, indexForRecord(self, resolved.id).?);
        try bindHandleByAssetId(self.allocator, handles.ScriptHandle, &self.script_handles_by_asset_id, handle, resolved.id, previous_id);
        return resolved.id;
    }

    pub fn ensurePrimitiveMesh(self: *ResourceLibrary, primitive: components.Primitive) !handles.MeshHandle {
        return switch (primitive) {
            .cube => blk: {
                if (self.cube_mesh) |handle| break :blk handle;
                self.cube_mesh = try self.createMesh(.{
                    .name = "BuiltinCube",
                    .vertices = cube_vertices[0..],
                    .indices = cube_indices[0..],
                });
                _ = try self.bindMeshAssetRecord(self.cube_mesh.?, try builtinRecord(
                    self,
                    .mesh,
                    "builtin://mesh/cube",
                    "BuiltinCube",
                ));
                break :blk self.cube_mesh.?;
            },
            .sphere => blk: {
                if (self.sphere_mesh) |handle| break :blk handle;
                self.sphere_mesh = try self.createUvSphereMesh();
                _ = try self.bindMeshAssetRecord(self.sphere_mesh.?, try builtinRecord(
                    self,
                    .mesh,
                    "builtin://mesh/sphere",
                    "BuiltinSphere",
                ));
                break :blk self.sphere_mesh.?;
            },
            .plane => blk: {
                if (self.plane_mesh) |handle| break :blk handle;
                self.plane_mesh = try self.createMesh(.{
                    .name = "BuiltinPlane",
                    .vertices = plane_vertices[0..],
                    .indices = plane_indices[0..],
                });
                _ = try self.bindMeshAssetRecord(self.plane_mesh.?, try builtinRecord(
                    self,
                    .mesh,
                    "builtin://mesh/plane",
                    "BuiltinPlane",
                ));
                break :blk self.plane_mesh.?;
            },
            else => error.UnsupportedPrimitive,
        };
    }

    pub fn ensureWhiteTexture(self: *ResourceLibrary) !handles.TextureHandle {
        if (self.white_texture) |handle| {
            return handle;
        }

        const pixels = [_]u8{
            0xFF, 0xFF, 0xFF, 0xFF,
        };

        self.white_texture = try self.createTexture(.{
            .name = "White1x1",
            .width = 1,
            .height = 1,
            .pixels = pixels[0..],
        });
        _ = try self.bindTextureAssetRecord(self.white_texture.?, try builtinRecord(
            self,
            .texture,
            "builtin://texture/white",
            "White1x1",
        ));
        return self.white_texture.?;
    }

    pub fn ensureDefaultAlbedoTexture(self: *ResourceLibrary) !handles.TextureHandle {
        if (self.default_albedo_texture) |handle| {
            return handle;
        }

        const pixels = [_]u8{
            0xDB, 0xDB, 0xE0, 0xFF,
            0xBE, 0xC2, 0xC8, 0xFF,
            0xBE, 0xC2, 0xC8, 0xFF,
            0xDB, 0xDB, 0xE0, 0xFF,
        };

        self.default_albedo_texture = try self.createTexture(.{
            .name = "DefaultAlbedo2x2",
            .width = 2,
            .height = 2,
            .pixels = pixels[0..],
        });
        _ = try self.bindTextureAssetRecord(self.default_albedo_texture.?, try builtinRecord(
            self,
            .texture,
            "builtin://texture/default-albedo",
            "DefaultAlbedo2x2",
        ));
        return self.default_albedo_texture.?;
    }

    pub fn ensureDefaultMaterial(self: *ResourceLibrary) !handles.MaterialHandle {
        if (self.default_material) |handle| {
            return handle;
        }

        self.default_material = try self.createMaterial(.{
            .name = "DefaultMaterial",
            .base_color_factor = .{ 1.0, 1.0, 1.0, 1.0 },
            .base_color_texture = try self.ensureDefaultAlbedoTexture(),
            .metallic_factor = 0.0,
            .roughness_factor = 0.82,
            .ibl_intensity = 0.18,
        });
        _ = try self.bindMaterialAssetRecord(self.default_material.?, try builtinRecord(
            self,
            .material,
            "builtin://material/default",
            "DefaultMaterial",
        ));
        return self.default_material.?;
    }

    fn createUvSphereMesh(self: *ResourceLibrary) !handles.MeshHandle {
        const latitude_segments: usize = 16;
        const longitude_segments: usize = 24;
        const vertex_count = (latitude_segments + 1) * (longitude_segments + 1);

        var vertices = try self.allocator.alloc(mesh_mod.Vertex, vertex_count);
        defer self.allocator.free(vertices);

        var indices = std.ArrayList(u32).empty;
        defer indices.deinit(self.allocator);

        var vertex_index: usize = 0;
        var lat: usize = 0;
        while (lat <= latitude_segments) : (lat += 1) {
            const v = @as(f32, @floatFromInt(lat)) / @as(f32, @floatFromInt(latitude_segments));
            const theta = v * std.math.pi;
            const sin_theta = std.math.sin(theta);
            const cos_theta = std.math.cos(theta);

            var lon: usize = 0;
            while (lon <= longitude_segments) : (lon += 1) {
                const u = @as(f32, @floatFromInt(lon)) / @as(f32, @floatFromInt(longitude_segments));
                const phi = u * std.math.tau;
                const sin_phi = std.math.sin(phi);
                const cos_phi = std.math.cos(phi);

                const normal = [3]f32{
                    sin_theta * cos_phi,
                    cos_theta,
                    sin_theta * sin_phi,
                };
                vertices[vertex_index] = makeVertex(
                    .{
                        normal[0] * 0.5,
                        normal[1] * 0.5,
                        normal[2] * 0.5,
                    },
                    .{
                        0.55 + normal[0] * 0.2,
                        0.7 + normal[1] * 0.15,
                        0.9 + normal[2] * 0.1,
                        1.0,
                    },
                    .{ u, 1.0 - v },
                    normal,
                    .{ -sin_phi, 0.0, cos_phi, 1.0 },
                );
                vertex_index += 1;
            }
        }

        lat = 0;
        while (lat < latitude_segments) : (lat += 1) {
            var lon: usize = 0;
            while (lon < longitude_segments) : (lon += 1) {
                const row_start = lat * (longitude_segments + 1);
                const next_row_start = (lat + 1) * (longitude_segments + 1);

                const a: u32 = @intCast(row_start + lon);
                const b: u32 = @intCast(next_row_start + lon);
                const c: u32 = @intCast(next_row_start + lon + 1);
                const d: u32 = @intCast(row_start + lon + 1);

                try indices.appendSlice(self.allocator, &.{ a, b, c, a, c, d });
            }
        }

        return self.createMesh(.{
            .name = "BuiltinSphere",
            .vertices = vertices,
            .indices = indices.items,
        });
    }
};

fn builtinRecord(
    library: *ResourceLibrary,
    asset_type: registry_mod.AssetType,
    source_path: []const u8,
    display_name: []const u8,
) !registry_mod.AssetRecord {
    const asset_id = try registry_mod.makeDerivedAssetIdAlloc(library.allocator, "guava.builtin.v1", &.{source_path});
    errdefer library.allocator.free(asset_id);

    const source_hash = try registry_mod.hashStringAlloc(library.allocator, source_path);
    errdefer library.allocator.free(source_hash);

    const import_settings_hash = try registry_mod.defaultImportSettingsHashAlloc(library.allocator, asset_type);
    errdefer library.allocator.free(import_settings_hash);

    return .{
        .id = asset_id,
        .type = asset_type,
        .source_path = try library.allocator.dupe(u8, source_path),
        .source_hash = source_hash,
        .import_settings_hash = import_settings_hash,
        .import_version = asset_type.importVersion(),
        .dependency_ids = try library.allocator.alloc([]u8, 0),
        .outputs = try library.allocator.alloc(registry_mod.AssetOutput, 0),
        .metadata = .{
            .display_name = try library.allocator.dupe(u8, display_name),
            .importer = try library.allocator.dupe(u8, asset_type.importerName()),
            .source_extension = try library.allocator.dupe(u8, std.fs.path.extension(source_path)),
        },
    };
}

fn indexForRecord(library: *const ResourceLibrary, asset_id: []const u8) ?usize {
    for (library.asset_registry.records.items, 0..) |record, index| {
        if (std.mem.eql(u8, record.id, asset_id)) {
            return index;
        }
    }
    return null;
}

fn bindHandleByAssetId(
    allocator: std.mem.Allocator,
    comptime Handle: type,
    map: *std.StringHashMap(Handle),
    handle: Handle,
    asset_id: []const u8,
    previous_id: ?[]const u8,
) !void {
    if (previous_id) |old_id| {
        if (!std.mem.eql(u8, old_id, asset_id)) {
            if (map.fetchRemove(old_id)) |removed| {
                allocator.free(removed.key);
            }
        }
    }

    const owned_id = try allocator.dupe(u8, asset_id);
    errdefer allocator.free(owned_id);
    if (try map.fetchPut(owned_id, handle)) |replaced| {
        allocator.free(replaced.key);
    }
}

fn freeHandleKeys(
    allocator: std.mem.Allocator,
    comptime Handle: type,
    map: *const std.StringHashMap(Handle),
) void {
    var iterator = map.keyIterator();
    while (iterator.next()) |key| {
        allocator.free(key.*);
    }
}

test "resource library resolves handles by stable asset id" {
    var library = ResourceLibrary.init(std.testing.allocator, null);
    defer library.deinit();

    const mesh_handle = try library.createMesh(.{
        .name = "TestMesh",
        .vertices = cube_vertices[0..],
        .indices = cube_indices[0..],
    });
    const asset_id = try library.bindMeshAssetRecord(
        mesh_handle,
        try builtinRecord(&library, .mesh, "builtin://mesh/test", "TestMesh"),
    );

    try std.testing.expectEqual(mesh_handle, library.meshHandleByAssetId(asset_id).?);
    try std.testing.expectEqualStrings(asset_id, library.meshAssetId(mesh_handle).?);
}

test "resource library resolves animation resource handles by stable asset id" {
    var library = ResourceLibrary.init(std.testing.allocator, null);
    defer library.deinit();

    const skeleton_handle = try library.createSkeleton(.{
        .name = "Rig",
        .joints = &.{
            .{
                .name = "Root",
                .node_entity_index = 0,
            },
        },
    });
    const skeleton_asset_id = try library.bindSkeletonAssetRecord(
        skeleton_handle,
        try builtinRecord(&library, .skeleton, "builtin://skeleton/rig", "Rig"),
    );

    const skin_handle = try library.createSkin(.{
        .name = "RigSkin",
        .skeleton = skeleton_handle,
        .joint_entity_indices = &.{0},
        .inverse_bind_matrices = &.{.{ 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0 }},
    });
    const skin_asset_id = try library.bindSkinAssetRecord(
        skin_handle,
        try builtinRecord(&library, .skin, "builtin://skin/rig", "RigSkin"),
    );

    const clip_handle = try library.createAnimationClip(.{
        .name = "Idle",
        .duration = 1.0,
        .translation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 1.0 },
                .values = &.{ .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.1, 0.0 } },
            },
        },
    });
    const clip_asset_id = try library.bindAnimationClipAssetRecord(
        clip_handle,
        try builtinRecord(&library, .animation_clip, "builtin://animation/idle", "Idle"),
    );

    try std.testing.expectEqual(skeleton_handle, library.skeletonHandleByAssetId(skeleton_asset_id).?);
    try std.testing.expectEqual(skin_handle, library.skinHandleByAssetId(skin_asset_id).?);
    try std.testing.expectEqual(clip_handle, library.animationClipHandleByAssetId(clip_asset_id).?);
    try std.testing.expectEqualStrings(skeleton_asset_id, library.skeletonAssetId(skeleton_handle).?);
    try std.testing.expectEqualStrings(skin_asset_id, library.skinAssetId(skin_handle).?);
    try std.testing.expectEqualStrings(clip_asset_id, library.animationClipAssetId(clip_handle).?);
}

const cube_vertices = [_]mesh_mod.Vertex{
    makeVertex(.{ -0.5, -0.5, 0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 0.0, 1.0 }, .{ 0.0, 0.0, 1.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ 0.5, -0.5, 0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 1.0, 1.0 }, .{ 0.0, 0.0, 1.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ 0.5, 0.5, 0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 1.0, 0.0 }, .{ 0.0, 0.0, 1.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ -0.5, 0.5, 0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0, 1.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ 0.5, -0.5, -0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 0.0, 1.0 }, .{ 0.0, 0.0, -1.0 }, .{ -1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ -0.5, -0.5, -0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 1.0, 1.0 }, .{ 0.0, 0.0, -1.0 }, .{ -1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ -0.5, 0.5, -0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 1.0, 0.0 }, .{ 0.0, 0.0, -1.0 }, .{ -1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ 0.5, 0.5, -0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 0.0, 0.0 }, .{ 0.0, 0.0, -1.0 }, .{ -1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ -0.5, -0.5, -0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 0.0, 1.0 }, .{ -1.0, 0.0, 0.0 }, .{ 0.0, 0.0, 1.0, 1.0 }),
    makeVertex(.{ -0.5, -0.5, 0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 1.0, 1.0 }, .{ -1.0, 0.0, 0.0 }, .{ 0.0, 0.0, 1.0, 1.0 }),
    makeVertex(.{ -0.5, 0.5, 0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 1.0, 0.0 }, .{ -1.0, 0.0, 0.0 }, .{ 0.0, 0.0, 1.0, 1.0 }),
    makeVertex(.{ -0.5, 0.5, -0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 0.0, 0.0 }, .{ -1.0, 0.0, 0.0 }, .{ 0.0, 0.0, 1.0, 1.0 }),
    makeVertex(.{ 0.5, -0.5, 0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 0.0, 1.0 }, .{ 1.0, 0.0, 0.0 }, .{ 0.0, 0.0, -1.0, 1.0 }),
    makeVertex(.{ 0.5, -0.5, -0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 1.0, 1.0 }, .{ 1.0, 0.0, 0.0 }, .{ 0.0, 0.0, -1.0, 1.0 }),
    makeVertex(.{ 0.5, 0.5, -0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 1.0, 0.0 }, .{ 1.0, 0.0, 0.0 }, .{ 0.0, 0.0, -1.0, 1.0 }),
    makeVertex(.{ 0.5, 0.5, 0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 0.0, 0.0 }, .{ 1.0, 0.0, 0.0 }, .{ 0.0, 0.0, -1.0, 1.0 }),
    makeVertex(.{ -0.5, 0.5, 0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 0.0, 1.0 }, .{ 0.0, 1.0, 0.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ 0.5, 0.5, 0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 1.0, 1.0 }, .{ 0.0, 1.0, 0.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ 0.5, 0.5, -0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 1.0, 0.0 }, .{ 0.0, 1.0, 0.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ -0.5, 0.5, -0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ -0.5, -0.5, -0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 0.0, 1.0 }, .{ 0.0, -1.0, 0.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ 0.5, -0.5, -0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 1.0, 1.0 }, .{ 0.0, -1.0, 0.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ 0.5, -0.5, 0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 1.0, 0.0 }, .{ 0.0, -1.0, 0.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ -0.5, -0.5, 0.5 }, .{ 1.0, 1.0, 1.0, 1.0 }, .{ 0.0, 0.0 }, .{ 0.0, -1.0, 0.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
};

const cube_indices = [_]u32{
    0,  1,  2,  0,  2,  3,
    4,  5,  6,  4,  6,  7,
    8,  9,  10, 8,  10, 11,
    12, 13, 14, 12, 14, 15,
    16, 17, 18, 16, 18, 19,
    20, 21, 22, 20, 22, 23,
};

const plane_vertices = [_]mesh_mod.Vertex{
    makeVertex(.{ -0.5, 0.0, -0.5 }, .{ 0.85, 0.88, 0.9, 1.0 }, .{ 0.0, 1.0 }, .{ 0.0, 1.0, 0.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ 0.5, 0.0, -0.5 }, .{ 0.85, 0.88, 0.9, 1.0 }, .{ 1.0, 1.0 }, .{ 0.0, 1.0, 0.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ 0.5, 0.0, 0.5 }, .{ 0.85, 0.88, 0.9, 1.0 }, .{ 1.0, 0.0 }, .{ 0.0, 1.0, 0.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
    makeVertex(.{ -0.5, 0.0, 0.5 }, .{ 0.85, 0.88, 0.9, 1.0 }, .{ 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 }, .{ 1.0, 0.0, 0.0, 1.0 }),
};

const plane_indices = [_]u32{
    0, 2, 1,
    0, 3, 2,
};

fn makeVertex(
    position: [3]f32,
    color: [4]f32,
    uv: [2]f32,
    normal: [3]f32,
    tangent: [4]f32,
) mesh_mod.Vertex {
    return .{
        .position = position,
        .normal = normal,
        .tangent = tangent,
        .color = color,
        .uv = uv,
    };
}
