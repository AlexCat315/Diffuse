const std = @import("std");
const assets_lib = @import("../assets/library.zig");
const gltf_import = @import("../assets/gltf_import.zig");
const handles = @import("../assets/handles.zig");
const material_ast_mod = @import("../assets/material_ast.zig");
const material_resource_mod = @import("../assets/material_resource.zig");
const mesh_resource_mod = @import("../assets/mesh_resource.zig");
const registry_mod = @import("../assets/registry.zig");
const texture_resource_mod = @import("../assets/texture_resource.zig");
const aabb_mod = @import("../math/aabb.zig");
const mesh_pass_mod = @import("passes/mesh_pass.zig");
const scene_extraction = @import("scene_extraction.zig");
const gfx_mod = @import("render_context.zig");
const gfx_types = @import("guava_gfx").types;
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");
const types = @import("types.zig");
const quat_mod = @import("../math/quat.zig");
const vec3 = @import("../math/vec3.zig");

const log = std.log.scoped(.renderer_thumbnails);

pub const material_thumbnail_dimension: u32 = 128;
pub const material_thumbnail_jobs_per_frame: usize = 2;
pub const material_thumbnail_cache_limit: usize = 48;
pub const material_thumbnail_clear_color = [4]f32{ 0.075, 0.08, 0.09, 1.0 };
pub const thumbnail_viewport_state = types.EditorViewportState{
    .render_mode = .textured,
    .show_grid = false,
    .show_bones = false,
    .show_collision = false,
};

// ════════════════════════════════════════════════════════════════════
// Model thumbnail constants and types
// ════════════════════════════════════════════════════════════════════

pub const model_thumbnail_dimension: u32 = 128;
pub const model_thumbnail_jobs_per_frame: usize = 1;
pub const model_thumbnail_cache_limit: usize = 32;
pub const model_thumbnail_clear_color = [4]f32{ 0.10, 0.11, 0.13, 1.0 };

pub const ModelThumbnailCacheEntry = struct {
    path: []u8,
    target: ThumbnailRenderTarget,
    ready: bool = false,
    queued: bool = false,
    last_requested_frame: usize = 0,

    pub fn deinit(self: *ModelThumbnailCacheEntry, allocator: std.mem.Allocator, device: *gfx_mod.RenderContext) void {
        allocator.free(self.path);
        self.target.deinit(device);
        self.* = undefined;
    }
};

pub const MaterialThumbnailTextureFingerprint = struct {
    handle: ?handles.TextureHandle = null,
    width: u32 = 0,
    height: u32 = 0,
    format: gfx_types.TextureFormat = .unknown,
};

pub const MaterialThumbnailSignature = struct {
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
    use_ibl: bool = true,
    ibl_intensity: f32 = 1.0,
    textures: struct {
        base_color: MaterialThumbnailTextureFingerprint = .{},
        metallic_roughness: MaterialThumbnailTextureFingerprint = .{},
        normal: MaterialThumbnailTextureFingerprint = .{},
        occlusion: MaterialThumbnailTextureFingerprint = .{},
        emissive: MaterialThumbnailTextureFingerprint = .{},
    } = .{},
};

pub const MaterialPreviewTextureSources = struct {
    base_color: ?*const texture_resource_mod.TextureResource = null,
    metallic_roughness: ?*const texture_resource_mod.TextureResource = null,
    normal: ?*const texture_resource_mod.TextureResource = null,
    occlusion: ?*const texture_resource_mod.TextureResource = null,
    emissive: ?*const texture_resource_mod.TextureResource = null,
};

pub const MaterialThumbnailSource = struct {
    ast: material_ast_mod.MaterialAst,
    textures: MaterialPreviewTextureSources = .{},
    signature: MaterialThumbnailSignature,
};

pub const ThumbnailRenderTarget = struct {
    color_texture: gfx_mod.Texture,
    depth_texture: gfx_mod.Texture,

    pub fn init(device: *gfx_mod.RenderContext) !ThumbnailRenderTarget {
        const color_texture = try device.createTexture(.{
            .width = material_thumbnail_dimension,
            .height = material_thumbnail_dimension,
            .format = .bgra8_unorm_srgb,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
        });
        errdefer {
            var owned = color_texture;
            device.releaseTexture(&owned);
        }

        const depth_texture = try device.createTexture(.{
            .width = material_thumbnail_dimension,
            .height = material_thumbnail_dimension,
            .format = .d32_float,
            .usage = gfx_types.TextureUsage.depth_stencil_target,
        });
        errdefer {
            var owned = depth_texture;
            device.releaseTexture(&owned);
        }

        return .{
            .color_texture = color_texture,
            .depth_texture = depth_texture,
        };
    }

    pub fn deinit(self: *ThumbnailRenderTarget, device: *gfx_mod.RenderContext) void {
        device.releaseTexture(&self.color_texture);
        device.releaseTexture(&self.depth_texture);
        self.* = undefined;
    }
};

pub const MaterialThumbnailCacheEntry = struct {
    asset_id: []u8,
    target: ThumbnailRenderTarget,
    signature: MaterialThumbnailSignature = .{},
    dirty: bool = true,
    queued: bool = false,
    ready: bool = false,
    last_requested_frame: usize = 0,

    pub fn deinit(self: *MaterialThumbnailCacheEntry, allocator: std.mem.Allocator, device: *gfx_mod.RenderContext) void {
        allocator.free(self.asset_id);
        self.target.deinit(device);
        self.* = undefined;
    }
};

pub const MaterialThumbnailPreview = struct {
    world: scene_mod.World,
    preview_entity: scene_mod.EntityId,
    preview_material_handle: handles.MaterialHandle,
    preview_texture_handles: material_ast_mod.TextureSlots = .{},

    pub fn init(allocator: std.mem.Allocator) !MaterialThumbnailPreview {
        var world = scene_mod.World.init(allocator, null);
        errdefer world.deinit();

        const sphere_mesh = try world.assets().ensurePrimitiveMesh(.sphere);
        const preview_material_handle = try world.assets().createMaterial(.{
            .name = "ThumbnailMaterial",
            .shading = .pbr_metallic_roughness,
            .base_color_factor = .{ 1.0, 1.0, 1.0, 1.0 },
        });

        const preview_entity = try world.createEntity(.{
            .name = "ThumbnailSphere",
            .local_transform = .{
                .rotation = quat_mod.fromEuler(.{ 0.0, 0.42, 0.0 }),
                .scale = .{ 1.08, 1.08, 1.08 },
            },
            .mesh = .{
                .handle = sphere_mesh,
                .primitive = .sphere,
            },
            .material = .{
                .handle = preview_material_handle,
            },
        });

        const camera_position = [3]f32{ 1.8, 1.05, 2.45 };
        _ = try world.createEntity(.{
            .name = "ThumbnailCamera",
            .camera = .{
                .is_primary = true,
                .projection = .{
                    .perspective = .{
                        .fov_y_radians = 0.68,
                        .near_clip = 0.1,
                        .far_clip = 32.0,
                    },
                },
            },
            .local_transform = .{
                .translation = camera_position,
                .rotation = quat_mod.fromEuler(lookRotationEuler(camera_position, .{ 0.0, 0.0, 0.0 })),
            },
        });

        _ = try world.createEntity(.{
            .name = "ThumbnailKeyLight",
            .light = .{
                .kind = .directional,
                .color = .{ 1.0, 0.98, 0.94 },
                .intensity = 2.6,
            },
            .local_transform = .{
                .rotation = quat_mod.fromEuler(.{ -0.88, 0.68, 0.0 }),
            },
        });

        _ = try world.createEntity(.{
            .name = "ThumbnailFillLight",
            .light = .{
                .kind = .point,
                .color = .{ 0.72, 0.82, 1.0 },
                .intensity = 5.8,
                .range = 8.0,
            },
            .local_transform = .{
                .translation = .{ 1.7, 1.25, 1.2 },
            },
        });

        return .{
            .world = world,
            .preview_entity = preview_entity,
            .preview_material_handle = preview_material_handle,
        };
    }

    pub fn deinit(self: *MaterialThumbnailPreview) void {
        self.world.deinit();
        self.* = undefined;
    }

    pub fn syncFromSource(self: *MaterialThumbnailPreview, source: MaterialThumbnailSource) !void {
        const preview_base_color_texture = try self.syncPreviewTextureSlot(.base_color, source.textures.base_color);
        const preview_metallic_roughness_texture = try self.syncPreviewTextureSlot(.metallic_roughness, source.textures.metallic_roughness);
        const preview_normal_texture = try self.syncPreviewTextureSlot(.normal, source.textures.normal);
        const preview_occlusion_texture = try self.syncPreviewTextureSlot(.occlusion, source.textures.occlusion);
        const preview_emissive_texture = try self.syncPreviewTextureSlot(.emissive, source.textures.emissive);

        const material_index = handles.indexOf(self.preview_material_handle);
        const preview_material = &self.world.resources.materials.items[material_index];
        preview_material.shading = source.ast.shading;
        preview_material.base_color_factor = source.ast.base_color_factor;
        preview_material.base_color_texture = preview_base_color_texture;
        preview_material.metallic_roughness_texture = preview_metallic_roughness_texture;
        preview_material.normal_texture = preview_normal_texture;
        preview_material.occlusion_texture = preview_occlusion_texture;
        preview_material.emissive_texture = preview_emissive_texture;
        preview_material.emissive_factor = source.ast.emissive_factor;
        preview_material.metallic_factor = source.ast.metallic_factor;
        preview_material.roughness_factor = source.ast.roughness_factor;
        preview_material.alpha_cutoff = source.ast.alpha_cutoff;
        preview_material.double_sided = source.ast.double_sided;
        preview_material.use_ibl = source.ast.use_ibl;
        preview_material.ibl_intensity = source.ast.ibl_intensity;

        if (self.world.getEntity(self.preview_entity)) |entity| {
            entity.material = .{
                .handle = self.preview_material_handle,
                .shading = source.ast.shading,
                .base_color_factor = source.ast.base_color_factor,
                .emissive_factor = source.ast.emissive_factor,
                .metallic_factor = source.ast.metallic_factor,
                .roughness_factor = source.ast.roughness_factor,
                .alpha_cutoff = source.ast.alpha_cutoff,
                .double_sided = source.ast.double_sided,
            };
        }
    }

    pub fn setPreviewPrimitive(self: *MaterialThumbnailPreview, primitive: components.Primitive) !void {
        const mesh_handle = try self.world.assets().ensurePrimitiveMesh(primitive);
        if (self.world.getEntity(self.preview_entity)) |entity| {
            entity.local_transform = previewTransformForPrimitive(primitive);
            if (entity.mesh) |*mesh_component| {
                mesh_component.primitive = primitive;
                mesh_component.handle = mesh_handle;
            } else {
                entity.mesh = .{
                    .handle = mesh_handle,
                    .primitive = primitive,
                };
            }
        }
    }

    fn syncPreviewTextureSlot(
        self: *MaterialThumbnailPreview,
        slot: MaterialTextureSlot,
        source_texture: ?*const texture_resource_mod.TextureResource,
    ) !?handles.TextureHandle {
        const resolved_texture = source_texture orelse return null;
        return try self.upsertPreviewTexture(slot, resolved_texture);
    }

    fn upsertPreviewTexture(
        self: *MaterialThumbnailPreview,
        slot: MaterialTextureSlot,
        source_texture: *const texture_resource_mod.TextureResource,
    ) !handles.TextureHandle {
        if (previewTextureHandleForSlot(&self.preview_texture_handles, slot)) |handle| {
            const owned_pixels = try self.world.allocator.dupe(u8, source_texture.pixels);
            errdefer self.world.allocator.free(owned_pixels);

            const preview_texture = &self.world.resources.textures.items[handles.indexOf(handle)];
            self.world.allocator.free(preview_texture.pixels);
            preview_texture.width = source_texture.width;
            preview_texture.height = source_texture.height;
            preview_texture.format = source_texture.format;
            preview_texture.pixels = owned_pixels;
            return handle;
        }

        const created = try self.world.assets().createTexture(.{
            .name = "ThumbnailTexture",
            .width = source_texture.width,
            .height = source_texture.height,
            .format = source_texture.format,
            .pixels = source_texture.pixels,
        });
        setPreviewTextureHandleForSlot(&self.preview_texture_handles, slot, created);
        return created;
    }
};

const MaterialTextureSlot = enum {
    base_color,
    metallic_roughness,
    normal,
    occlusion,
    emissive,
};

pub fn requestMaterialThumbnail(self: anytype, scene: *const scene_mod.Scene, asset_id: []const u8, frame_index: usize) !void {
    const source = resolveMaterialThumbnailSource(&scene.resources, asset_id) orelse {
        removeMaterialThumbnail(self, asset_id);
        return;
    };

    const entry = try ensureMaterialThumbnailEntry(self, asset_id);
    const signature_changed = !std.meta.eql(entry.signature, source.signature);
    if (signature_changed) {
        entry.signature = source.signature;
        entry.dirty = true;
        entry.ready = false;
    }
    entry.last_requested_frame = frame_index;
    if (entry.dirty and !entry.queued) {
        try enqueueMaterialThumbnailRequest(self, entry);
    }
}

pub fn materialThumbnailTexture(self: anytype, asset_id: []const u8) ?*const gfx_mod.Texture {
    const entry = findMaterialThumbnailCacheIndex(self, asset_id) orelse return null;
    if (!entry.ready) return null;
    return &entry.target.color_texture;
}

pub fn processMaterialThumbnailRequests(
    self: anytype,
    frame: gfx_mod.Frame,
    scene: *const scene_mod.Scene,
) !mesh_pass_mod.DrawStats {
    var stats = mesh_pass_mod.DrawStats{};
    if (!self.depth_prepass.isReady() or !self.base_pass.isReady()) {
        return stats;
    }

    var processed: usize = 0;
    while (processed < material_thumbnail_jobs_per_frame and self.material_thumbnail_requests.items.len > 0) : (processed += 1) {
        const asset_id = self.material_thumbnail_requests.orderedRemove(0);
        defer self.allocator.free(asset_id);

        const entry_ptr = findMaterialThumbnailCacheIndex(self, asset_id) orelse continue;
        entry_ptr.queued = false;

        const source = resolveMaterialThumbnailSource(&scene.resources, asset_id) orelse {
            removeMaterialThumbnail(self, asset_id);
            continue;
        };

        try self.material_thumbnail_preview.syncFromSource(source);
        self.thumbnail_scene_cache.invalidateMaterialResources(&self.gfx);
        const preview_stats = try renderMaterialPreviewTarget(self, frame, &entry_ptr.target);
        stats.add(preview_stats);

        entry_ptr.signature = source.signature;
        entry_ptr.dirty = false;
        entry_ptr.ready = true;
    }

    return stats;
}

pub fn renderMaterialPreviewTarget(
    self: anytype,
    frame: gfx_mod.Frame,
    target: *ThumbnailRenderTarget,
) !mesh_pass_mod.DrawStats {
    var stats = mesh_pass_mod.DrawStats{};

    _ = try scene_extraction.extractWorld(
        &self.material_thumbnail_preview.world,
        &self.thumbnail_render_world,
        null,
        &.{},
        null,
    );

    var prepared_scene = try self.thumbnail_scene_cache.prepareScene(
        &self.gfx,
        &self.material_thumbnail_preview.world,
        &self.thumbnail_render_world,
        material_thumbnail_dimension,
        material_thumbnail_dimension,
    );
    defer prepared_scene.deinit();

    const render_pass = try self.gfx.beginRenderPassWithDesc(frame, .{
        .color = .{
            .target = .{ .texture = &target.color_texture },
            .clear_color = material_thumbnail_clear_color,
            .load_op = .clear,
            .store_op = .store,
        },
        .depth = .{
            .texture = &target.depth_texture,
            .clear_depth = 1.0,
            .clear_stencil = 0,
            .load_op = .clear,
            .store_op = .dont_care,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
        },
    });

    const depth_stats = self.depth_prepass.draw(&self.gfx, frame, render_pass, &prepared_scene);
    stats.add(depth_stats);
    const base_stats = try self.base_pass.draw(&self.gfx, frame, render_pass, &prepared_scene, .{
        .render_mode = thumbnail_viewport_state.render_mode,
        .target = .ldr,
    });
    stats.add(base_stats);
    self.gfx.endRenderPass(render_pass);

    return stats;
}

pub fn makeMaterialThumbnailSourceFromAst(
    resources: *const assets_lib.ResourceLibrary,
    ast: *const material_ast_mod.MaterialAst,
) MaterialThumbnailSource {
    const texture_sources = MaterialPreviewTextureSources{
        .base_color = resolveTextureSource(resources, ast.textures.base_color),
        .metallic_roughness = resolveTextureSource(resources, ast.textures.metallic_roughness),
        .normal = resolveTextureSource(resources, ast.textures.normal),
        .occlusion = resolveTextureSource(resources, ast.textures.occlusion),
        .emissive = resolveTextureSource(resources, ast.textures.emissive),
    };

    return .{
        .ast = ast.*,
        .textures = texture_sources,
        .signature = .{
            .shading = ast.shading,
            .base_color_factor = ast.base_color_factor,
            .emissive_factor = ast.emissive_factor,
            .metallic_factor = ast.metallic_factor,
            .roughness_factor = ast.roughness_factor,
            .alpha_cutoff = ast.alpha_cutoff,
            .double_sided = ast.double_sided,
            .use_ibl = ast.use_ibl,
            .ibl_intensity = ast.ibl_intensity,
            .textures = .{
                .base_color = textureFingerprint(ast.textures.base_color, texture_sources.base_color),
                .metallic_roughness = textureFingerprint(ast.textures.metallic_roughness, texture_sources.metallic_roughness),
                .normal = textureFingerprint(ast.textures.normal, texture_sources.normal),
                .occlusion = textureFingerprint(ast.textures.occlusion, texture_sources.occlusion),
                .emissive = textureFingerprint(ast.textures.emissive, texture_sources.emissive),
            },
        },
    };
}

pub fn findMaterialThumbnailCacheIndex(self: anytype, asset_id: []const u8) ?*MaterialThumbnailCacheEntry {
    return self.material_thumbnail_cache.getPtr(asset_id);
}

pub fn ensureMaterialThumbnailEntry(self: anytype, asset_id: []const u8) !*MaterialThumbnailCacheEntry {
    if (self.material_thumbnail_cache.getPtr(asset_id)) |entry| {
        return entry;
    }

    if (self.material_thumbnail_cache.count() >= material_thumbnail_cache_limit) {
        evictMaterialThumbnailEntry(self, asset_id);
    }

    const owned_asset_id = try self.allocator.dupe(u8, asset_id);
    errdefer self.allocator.free(owned_asset_id);

    const target = try ThumbnailRenderTarget.init(&self.gfx);
    errdefer {
        var owned = target;
        owned.deinit(&self.gfx);
    }

    const entry = MaterialThumbnailCacheEntry{
        .asset_id = owned_asset_id,
        .target = target,
    };
    try self.material_thumbnail_cache.put(owned_asset_id, entry);
    return self.material_thumbnail_cache.getPtr(owned_asset_id).?;
}

pub fn enqueueMaterialThumbnailRequest(self: anytype, entry: *MaterialThumbnailCacheEntry) !void {
    const queued_asset_id = try self.allocator.dupe(u8, entry.asset_id);
    errdefer self.allocator.free(queued_asset_id);

    try self.material_thumbnail_requests.append(self.allocator, queued_asset_id);
    entry.queued = true;
}

pub fn evictMaterialThumbnailEntry(self: anytype, keep_asset_id: []const u8) void {
    var oldest_unqueued_key: ?[]const u8 = null;
    var oldest_any_key: ?[]const u8 = null;
    var min_frame_unqueued: u64 = std.math.maxInt(u64);
    var min_frame_any: u64 = std.math.maxInt(u64);

    var it = self.material_thumbnail_cache.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr;
        if (std.mem.eql(u8, key, keep_asset_id)) {
            continue;
        }
        if (value.last_requested_frame < min_frame_any) {
            min_frame_any = value.last_requested_frame;
            oldest_any_key = key;
        }
        if (!value.queued and value.last_requested_frame < min_frame_unqueued) {
            min_frame_unqueued = value.last_requested_frame;
            oldest_unqueued_key = key;
        }
    }

    const key_to_remove = oldest_unqueued_key orelse oldest_any_key;
    if (key_to_remove) |key| {
        if (self.material_thumbnail_cache.fetchRemove(key)) |kv| {
            var value = kv.value;
            value.deinit(self.allocator, &self.gfx);
        }
    }
}

pub fn removeMaterialThumbnail(self: anytype, asset_id: []const u8) void {
    if (self.material_thumbnail_cache.fetchRemove(asset_id)) |kv| {
        var value = kv.value;
        value.deinit(self.allocator, &self.gfx);
    }
}

pub fn releaseMaterialThumbnailCache(self: anytype) void {
    var it = self.material_thumbnail_cache.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(self.allocator, &self.gfx);
    }
    self.material_thumbnail_cache.deinit();
    self.material_thumbnail_cache = undefined;
}

pub fn releaseMaterialThumbnailRequests(self: anytype) void {
    for (self.material_thumbnail_requests.items) |asset_id| {
        self.allocator.free(asset_id);
    }
    self.material_thumbnail_requests.deinit(self.allocator);
    self.material_thumbnail_requests = .empty;
}

pub fn resolveMaterialThumbnailSource(
    resources: *const assets_lib.ResourceLibrary,
    asset_id: []const u8,
) ?MaterialThumbnailSource {
    const material_handle = resources.materialHandleByAssetId(asset_id) orelse return null;
    const material = resources.material(material_handle) orelse return null;
    const ast = material_ast_mod.MaterialAst.fromResource(material);
    return makeMaterialThumbnailSourceFromAst(resources, &ast);
}

fn resolveTextureSource(
    resources: *const assets_lib.ResourceLibrary,
    handle: ?handles.TextureHandle,
) ?*const texture_resource_mod.TextureResource {
    const texture_handle = handle orelse return null;
    return resources.texture(texture_handle);
}

fn textureFingerprint(
    handle: ?handles.TextureHandle,
    texture: ?*const texture_resource_mod.TextureResource,
) MaterialThumbnailTextureFingerprint {
    const resolved_texture = texture orelse return .{};
    return .{
        .handle = handle,
        .width = resolved_texture.width,
        .height = resolved_texture.height,
        .format = resolved_texture.format,
    };
}

fn previewTextureHandleForSlot(
    slots: *const material_ast_mod.TextureSlots,
    slot: MaterialTextureSlot,
) ?handles.TextureHandle {
    return switch (slot) {
        .base_color => slots.base_color,
        .metallic_roughness => slots.metallic_roughness,
        .normal => slots.normal,
        .occlusion => slots.occlusion,
        .emissive => slots.emissive,
    };
}

fn setPreviewTextureHandleForSlot(
    slots: *material_ast_mod.TextureSlots,
    slot: MaterialTextureSlot,
    handle: handles.TextureHandle,
) void {
    switch (slot) {
        .base_color => slots.base_color = handle,
        .metallic_roughness => slots.metallic_roughness = handle,
        .normal => slots.normal = handle,
        .occlusion => slots.occlusion = handle,
        .emissive => slots.emissive = handle,
    }
}

fn previewTransformForPrimitive(primitive: components.Primitive) components.Transform {
    return switch (primitive) {
        .plane => .{
            .rotation = quat_mod.fromEuler(.{ -0.82, 0.42, 0.0 }),
            .scale = .{ 1.52, 1.52, 1.52 },
        },
        else => .{
            .rotation = quat_mod.fromEuler(.{ 0.0, 0.42, 0.0 }),
            .scale = .{ 1.08, 1.08, 1.08 },
        },
    };
}

fn lookRotationEuler(from: [3]f32, to: [3]f32) [3]f32 {
    const direction = vec3.normalize(vec3.sub(to, from));
    return .{
        std.math.asin(std.math.clamp(direction[1], -1.0, 1.0)),
        std.math.atan2(-direction[0], -direction[2]),
        0.0,
    };
}

pub fn makeOwnedTestAssetRecord(
    allocator: std.mem.Allocator,
    asset_type: registry_mod.AssetType,
    id: []const u8,
    source_path: []const u8,
    display_name: []const u8,
) !registry_mod.AssetRecord {
    return .{
        .id = try allocator.dupe(u8, id),
        .type = asset_type,
        .source_path = try allocator.dupe(u8, source_path),
        .source_hash = try allocator.dupe(u8, "thumbnail-test-source"),
        .import_settings_hash = try allocator.dupe(u8, "thumbnail-test-settings"),
        .import_version = asset_type.importVersion(),
        .dependency_ids = try allocator.alloc([]u8, 0),
        .outputs = try allocator.alloc(registry_mod.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, display_name),
            .importer = try allocator.dupe(u8, asset_type.importerName()),
            .source_extension = try allocator.dupe(u8, ".thumb"),
        },
    };
}

// ════════════════════════════════════════════════════════════════════
// Model thumbnail functions
// ════════════════════════════════════════════════════════════════════

pub fn requestModelThumbnail(self: anytype, model_path: []const u8, frame_index: usize) !void {
    const entry = try ensureModelThumbnailEntry(self, model_path);
    entry.last_requested_frame = frame_index;
    if (!entry.ready and !entry.queued) {
        try enqueueModelThumbnailRequest(self, entry);
    }
}

pub fn modelThumbnailTexture(self: anytype, model_path: []const u8) ?*const gfx_mod.Texture {
    const entry = findModelThumbnailCacheEntry(self, model_path) orelse return null;
    if (!entry.ready) return null;
    return &entry.target.color_texture;
}

pub fn processModelThumbnailRequests(
    self: anytype,
    frame: gfx_mod.Frame,
) !mesh_pass_mod.DrawStats {
    var stats = mesh_pass_mod.DrawStats{};
    if (!self.depth_prepass.isReady() or !self.base_pass.isReady()) {
        return stats;
    }

    var processed: usize = 0;
    while (processed < model_thumbnail_jobs_per_frame and self.model_thumbnail_requests.items.len > 0) : (processed += 1) {
        const model_path = self.model_thumbnail_requests.orderedRemove(0);
        defer self.allocator.free(model_path);

        const entry_ptr = findModelThumbnailCacheEntry(self, model_path) orelse continue;
        entry_ptr.queued = false;

        const render_result = renderModelThumbnail(self, frame, model_path, &entry_ptr.target);
        if (render_result) |render_stats| {
            stats.add(render_stats);
            entry_ptr.ready = true;
        } else |err| {
            log.warn("model thumbnail render failed for '{s}': {s}", .{ model_path, @errorName(err) });
            entry_ptr.ready = false;
        }
    }

    return stats;
}

fn renderModelThumbnail(
    self: anytype,
    frame: gfx_mod.Frame,
    model_path: []const u8,
    target: *ThumbnailRenderTarget,
) !mesh_pass_mod.DrawStats {
    var stats = mesh_pass_mod.DrawStats{};

    // Create temporary world and import the model
    var temp_world = scene_mod.World.init(self.allocator, null);
    defer temp_world.deinit();

    const report = try gltf_import.importStaticModel(&temp_world, model_path, .{});
    if (report.mesh_count == 0) return error.NoMeshes;

    // Compute bounding box from all mesh resources
    var bounds = aabb_mod.AABB.empty();
    for (temp_world.resources.meshes.items) |mesh| {
        bounds.expandAABB(mesh.local_bounds);
    }
    if (!bounds.isValid()) return error.InvalidBounds;

    // Compute camera position to frame the model
    const center = bounds.centroid();
    const ext = bounds.extent();
    const max_extent = @max(@max(ext[0], ext[1]), ext[2]);
    const cam_dist = max_extent * 1.8;
    const cam_height = center[1] + max_extent * 0.35;
    const cam_pos = [3]f32{
        center[0] + cam_dist * 0.7,
        cam_height,
        center[2] + cam_dist * 0.7,
    };

    // Add camera
    _ = try temp_world.createEntity(.{
        .name = "ModelThumbCam",
        .camera = .{
            .is_primary = true,
            .projection = .{
                .perspective = .{
                    .fov_y_radians = 0.65,
                    .near_clip = cam_dist * 0.01,
                    .far_clip = cam_dist * 10.0,
                },
            },
        },
        .local_transform = .{
            .translation = cam_pos,
            .rotation = quat_mod.fromEuler(lookRotationEuler(cam_pos, center)),
        },
    });

    // Add key light
    _ = try temp_world.createEntity(.{
        .name = "ModelThumbKeyLight",
        .light = .{
            .kind = .directional,
            .color = .{ 1.0, 0.98, 0.94 },
            .intensity = 2.8,
        },
        .local_transform = .{
            .rotation = quat_mod.fromEuler(.{ -0.85, 0.65, 0.0 }),
        },
    });

    // Add fill light
    _ = try temp_world.createEntity(.{
        .name = "ModelThumbFillLight",
        .light = .{
            .kind = .point,
            .color = .{ 0.72, 0.82, 1.0 },
            .intensity = cam_dist * 3.0,
            .range = cam_dist * 4.0,
        },
        .local_transform = .{
            .translation = .{
                center[0] + cam_dist * 0.5,
                center[1] + cam_dist * 0.6,
                center[2] - cam_dist * 0.3,
            },
        },
    });

    // Invalidate scene cache (new geometry each time)
    self.model_thumbnail_scene_cache.invalidateAllResources(&self.gfx);

    // Extract world to render world
    _ = try scene_extraction.extractWorld(
        &temp_world,
        &self.model_thumbnail_render_world,
        null,
        &.{},
        null,
    );

    // Prepare scene and render
    var prepared_scene = try self.model_thumbnail_scene_cache.prepareScene(
        &self.gfx,
        &temp_world,
        &self.model_thumbnail_render_world,
        model_thumbnail_dimension,
        model_thumbnail_dimension,
    );
    defer prepared_scene.deinit();

    const render_pass = try self.gfx.beginRenderPassWithDesc(frame, .{
        .color = .{
            .target = .{ .texture = &target.color_texture },
            .clear_color = model_thumbnail_clear_color,
            .load_op = .clear,
            .store_op = .store,
        },
        .depth = .{
            .texture = &target.depth_texture,
            .clear_depth = 1.0,
            .clear_stencil = 0,
            .load_op = .clear,
            .store_op = .dont_care,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
        },
    });

    const depth_stats = self.depth_prepass.draw(&self.gfx, frame, render_pass, &prepared_scene);
    stats.add(depth_stats);
    const base_stats = try self.base_pass.draw(&self.gfx, frame, render_pass, &prepared_scene, .{
        .render_mode = thumbnail_viewport_state.render_mode,
        .target = .ldr,
    });
    stats.add(base_stats);
    self.gfx.endRenderPass(render_pass);

    return stats;
}

pub fn findModelThumbnailCacheEntry(self: anytype, model_path: []const u8) ?*ModelThumbnailCacheEntry {
    return self.model_thumbnail_cache.getPtr(model_path);
}

pub fn ensureModelThumbnailEntry(self: anytype, model_path: []const u8) !*ModelThumbnailCacheEntry {
    if (self.model_thumbnail_cache.getPtr(model_path)) |entry| {
        return entry;
    }

    if (self.model_thumbnail_cache.count() >= model_thumbnail_cache_limit) {
        evictModelThumbnailEntry(self, model_path);
    }

    const owned_path = try self.allocator.dupe(u8, model_path);
    errdefer self.allocator.free(owned_path);

    const target = try ThumbnailRenderTarget.init(&self.gfx);
    errdefer {
        var owned = target;
        owned.deinit(&self.gfx);
    }

    const entry = ModelThumbnailCacheEntry{
        .path = owned_path,
        .target = target,
    };
    try self.model_thumbnail_cache.put(owned_path, entry);
    return self.model_thumbnail_cache.getPtr(owned_path).?;
}

fn enqueueModelThumbnailRequest(self: anytype, entry: *ModelThumbnailCacheEntry) !void {
    const queued_path = try self.allocator.dupe(u8, entry.path);
    errdefer self.allocator.free(queued_path);
    try self.model_thumbnail_requests.append(self.allocator, queued_path);
    entry.queued = true;
}

fn evictModelThumbnailEntry(self: anytype, keep_path: []const u8) void {
    var oldest_key: ?[]const u8 = null;
    var min_frame: u64 = std.math.maxInt(u64);
    var it = self.model_thumbnail_cache.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        if (std.mem.eql(u8, key, keep_path)) continue;
        if (!kv.value_ptr.queued and kv.value_ptr.last_requested_frame < min_frame) {
            min_frame = kv.value_ptr.last_requested_frame;
            oldest_key = key;
        }
    }
    if (oldest_key) |key| {
        if (self.model_thumbnail_cache.fetchRemove(key)) |kv| {
            var value = kv.value;
            value.deinit(self.allocator, &self.gfx);
        }
    }
}

pub fn releaseModelThumbnailCache(self: anytype) void {
    var it = self.model_thumbnail_cache.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit(self.allocator, &self.gfx);
    }
    self.model_thumbnail_cache.deinit();
    self.model_thumbnail_cache = undefined;
}

pub fn releaseModelThumbnailRequests(self: anytype) void {
    for (self.model_thumbnail_requests.items) |path| {
        self.allocator.free(path);
    }
    self.model_thumbnail_requests.deinit(self.allocator);
    self.model_thumbnail_requests = .empty;
}

test "resolveMaterialThumbnailSource captures loaded material signatures" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const texture_handle = try world.assets().createTexture(.{
        .name = "PreviewAlbedo",
        .width = 4,
        .height = 2,
        .pixels = &[_]u8{
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
            255, 255, 255, 255,
        },
    });
    _ = try world.assets().bindTextureAssetRecord(
        texture_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .texture, "texture://preview", "assets/textures/preview.png", "Preview Texture"),
    );

    const material_handle = try world.assets().createMaterial(.{
        .name = "PreviewMaterial",
        .shading = .lambert,
        .base_color_factor = .{ 0.2, 0.4, 0.6, 1.0 },
        .base_color_texture = texture_handle,
    });
    _ = try world.assets().bindMaterialAssetRecord(
        material_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .material, "material://preview", "assets/materials/preview.guava_material", "Preview Material"),
    );

    const source = resolveMaterialThumbnailSource(world.assets(), "material://preview").?;
    try std.testing.expectEqual(components.ShadingModel.lambert, source.signature.shading);
    try std.testing.expectEqualDeep([4]f32{ 0.2, 0.4, 0.6, 1.0 }, source.signature.base_color_factor);
    try std.testing.expectEqual(texture_handle, source.signature.textures.base_color.handle.?);
    try std.testing.expectEqual(@as(u32, 4), source.signature.textures.base_color.width);
    try std.testing.expectEqual(@as(u32, 2), source.signature.textures.base_color.height);
}

test "material thumbnail preview scene mirrors source material resources" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const texture_handle = try world.assets().createTexture(.{
        .name = "PreviewSyncTexture",
        .width = 2,
        .height = 2,
        .pixels = &[_]u8{
            255, 128, 0, 255,
            255, 128, 0, 255,
            255, 128, 0, 255,
            255, 128, 0, 255,
        },
    });
    _ = try world.assets().bindTextureAssetRecord(
        texture_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .texture, "texture://sync", "assets/textures/sync.png", "Sync Texture"),
    );

    const material_handle = try world.assets().createMaterial(.{
        .name = "PreviewSyncMaterial",
        .shading = .unlit,
        .base_color_factor = .{ 0.9, 0.3, 0.1, 1.0 },
        .base_color_texture = texture_handle,
        .metallic_roughness_texture = texture_handle,
        .normal_texture = texture_handle,
        .occlusion_texture = texture_handle,
        .emissive_texture = texture_handle,
        .emissive_factor = .{ 0.1, 0.2, 0.3 },
        .metallic_factor = 0.45,
        .roughness_factor = 0.2,
        .alpha_cutoff = 0.33,
        .double_sided = true,
        .use_ibl = false,
        .ibl_intensity = 0.5,
    });
    _ = try world.assets().bindMaterialAssetRecord(
        material_handle,
        try makeOwnedTestAssetRecord(std.testing.allocator, .material, "material://sync", "assets/materials/sync.guava_material", "Sync Material"),
    );

    var preview = try MaterialThumbnailPreview.init(std.testing.allocator);
    defer preview.deinit();

    const source = resolveMaterialThumbnailSource(world.assets(), "material://sync").?;
    try preview.syncFromSource(source);

    const preview_material = preview.world.resources.material(preview.preview_material_handle).?;
    try std.testing.expectEqual(components.ShadingModel.unlit, preview_material.shading);
    try std.testing.expectEqualDeep([4]f32{ 0.9, 0.3, 0.1, 1.0 }, preview_material.base_color_factor);
    try std.testing.expectEqualDeep([3]f32{ 0.1, 0.2, 0.3 }, preview_material.emissive_factor);
    try std.testing.expectEqual(@as(f32, 0.45), preview_material.metallic_factor);
    try std.testing.expectEqual(@as(f32, 0.2), preview_material.roughness_factor);
    try std.testing.expectEqual(@as(f32, 0.33), preview_material.alpha_cutoff);
    try std.testing.expect(preview_material.double_sided);
    try std.testing.expect(!preview_material.use_ibl);
    try std.testing.expectEqual(@as(f32, 0.5), preview_material.ibl_intensity);
    try std.testing.expect(preview_material.base_color_texture != null);
    try std.testing.expect(preview_material.metallic_roughness_texture != null);
    try std.testing.expect(preview_material.normal_texture != null);
    try std.testing.expect(preview_material.occlusion_texture != null);
    try std.testing.expect(preview_material.emissive_texture != null);

    const preview_texture = preview.world.resources.texture(preview_material.base_color_texture.?).?;
    try std.testing.expectEqual(@as(u32, 2), preview_texture.width);
    try std.testing.expectEqual(@as(u32, 2), preview_texture.height);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        255, 128, 0, 255,
        255, 128, 0, 255,
        255, 128, 0, 255,
        255, 128, 0, 255,
    }, preview_texture.pixels);
}

test "material thumbnail preview can switch preview primitive without mutating source scene" {
    var preview = try MaterialThumbnailPreview.init(std.testing.allocator);
    defer preview.deinit();

    try preview.setPreviewPrimitive(.plane);
    const entity = preview.world.getEntity(preview.preview_entity).?;
    try std.testing.expect(entity.mesh != null);
    try std.testing.expectEqual(components.Primitive.plane, entity.mesh.?.primitive);
}
