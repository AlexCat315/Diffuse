const std = @import("std");
const components = @import("../scene/components.zig");
const scene_mod = @import("../scene/scene.zig");

const frustum_mod = @import("../math/frustum.zig");

pub const ExtractionStats = struct {
    frustum_candidates: usize = 0,
    total_meshes: usize = 0,
    extracted_meshes: usize = 0,
    total_vfxs: usize = 0,
    extracted_vfxs: usize = 0,

    pub fn culledMeshes(self: *const ExtractionStats) usize {
        return self.total_meshes - self.extracted_meshes;
    }

    pub fn culledVfxs(self: *const ExtractionStats) usize {
        return self.total_vfxs - self.extracted_vfxs;
    }
};

pub const RenderCamera = struct {
    entity_id: scene_mod.EntityId,
    transform: components.Transform,
    camera: components.Camera,
};

pub const RenderLight = struct {
    entity_id: scene_mod.EntityId,
    transform: components.Transform,
    light: components.Light,
};

pub const RenderLightArray = struct {
    allocator: std.mem.Allocator,
    directional: std.ArrayList(RenderLight) = .empty,
    point: std.ArrayList(RenderLight) = .empty,
    spot: std.ArrayList(RenderLight) = .empty,

    pub fn init(allocator: std.mem.Allocator) RenderLightArray {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RenderLightArray) void {
        self.directional.deinit(self.allocator);
        self.point.deinit(self.allocator);
        self.spot.deinit(self.allocator);
    }

    pub fn clear(self: *RenderLightArray) void {
        self.directional.clearRetainingCapacity();
        self.point.clearRetainingCapacity();
        self.spot.clearRetainingCapacity();
    }

    pub fn add(self: *RenderLightArray, render_light: RenderLight) !void {
        const kind = render_light.light.kind;
        if (kind == .directional) {
            try self.directional.append(self.allocator, render_light);
        } else if (kind == .point) {
            try self.point.append(self.allocator, render_light);
        } else if (kind == .spot) {
            try self.spot.append(self.allocator, render_light);
        }
    }

    pub fn len(self: *const RenderLightArray) usize {
        return self.directional.items.len + self.point.items.len + self.spot.items.len;
    }
};

pub const RenderMesh = struct {
    entity_id: scene_mod.EntityId,
    transform: components.Transform,
    mesh: components.Mesh,
    material: ?components.Material,
    selected: bool = false,
};

pub const RenderVfx = struct {
    entity_id: scene_mod.EntityId,
    transform: components.Transform,
    vfx: components.Vfx,
    selected: bool = false,
};

pub const RenderEntity = struct {
    id: scene_mod.EntityId,
    parent: ?scene_mod.EntityId,
    world_transform: components.Transform,
};

pub const RenderWorld = struct {
    allocator: std.mem.Allocator,
    entities: std.ArrayList(RenderEntity) = .empty,
    cameras: std.ArrayList(RenderCamera) = .empty,
    lights: RenderLightArray,
    meshes: std.ArrayList(RenderMesh) = .empty,
    vfxs: std.ArrayList(RenderVfx) = .empty,

    pub fn init(allocator: std.mem.Allocator) RenderWorld {
        return .{
            .allocator = allocator,
            .lights = RenderLightArray.init(allocator),
        };
    }

    pub fn deinit(self: *RenderWorld) void {
        self.entities.deinit(self.allocator);
        self.cameras.deinit(self.allocator);
        self.lights.deinit();
        self.meshes.deinit(self.allocator);
        self.vfxs.deinit(self.allocator);
    }

    pub fn clear(self: *RenderWorld) void {
        self.entities.clearRetainingCapacity();
        self.cameras.clearRetainingCapacity();
        self.lights.clear();
        self.meshes.clearRetainingCapacity();
        self.vfxs.clearRetainingCapacity();
    }
};

pub fn extractWorld(
    world: *scene_mod.World,
    render_world: *RenderWorld,
    primary_selection: ?scene_mod.EntityId,
    selection_list: []const scene_mod.EntityId,
    frustum: ?frustum_mod.Frustum,
) !ExtractionStats {
    render_world.clear();
    var stats = ExtractionStats{};
    var visible_renderables: ?std.AutoHashMap(scene_mod.EntityId, void) = null;
    defer {
        if (visible_renderables) |*set| {
            set.deinit();
        }
    }

    if (frustum) |resolved_frustum| {
        const visible_bounds = try world.queryRenderableBoundsInFrustum(render_world.allocator, resolved_frustum);
        defer render_world.allocator.free(visible_bounds);

        var candidate_set = std.AutoHashMap(scene_mod.EntityId, void).init(render_world.allocator);
        errdefer candidate_set.deinit();
        try candidate_set.ensureTotalCapacity(@intCast(visible_bounds.len));
        for (visible_bounds) |candidate| {
            candidate_set.putAssumeCapacity(candidate.id, {});
        }
        stats.frustum_candidates = visible_bounds.len;
        visible_renderables = candidate_set;
    }

    for (world.entities.items) |entity| {
        const world_transform = world.worldTransformConst(entity.id) orelse entity.local_transform;

        try render_world.entities.append(render_world.allocator, .{
            .id = entity.id,
            .parent = entity.parent,
            .world_transform = world_transform,
        });

        if (!entity.visible) {
            continue;
        }

        const is_selected = isEntitySelected(entity.id, primary_selection, selection_list);
        // 在 extraction 阶段优先复用 renderable 空间索引，避免逐 mesh/vfx 线性做 frustum test。
        const entity_visible_in_frustum = if (visible_renderables) |*candidate_set|
            if (entity.mesh != null or entity.skinned_mesh != null or entity.vfx != null)
                if (world.worldBoundsConst(entity.id) != null)
                    candidate_set.contains(entity.id)
                else
                    true
            else
                true
        else if (frustum) |f|
            if (world.worldBoundsConst(entity.id)) |bounds|
                f.intersectsAABB(bounds)
            else
                true
        else
            true;

        if (entity.camera) |camera| {
            try render_world.cameras.append(render_world.allocator, .{
                .entity_id = entity.id,
                .transform = world_transform,
                .camera = camera,
            });
        }

        if (entity.light) |light| {
            try render_world.lights.add(.{
                .entity_id = entity.id,
                .transform = world_transform,
                .light = light,
            });
        }

        if (entity.mesh != null or entity.skinned_mesh != null) {
            stats.total_meshes += 1;
            if (!entity_visible_in_frustum) {
                continue;
            }

            const extracted_mesh = if (entity.mesh) |mesh|
                mesh
            else
                components.Mesh{
                    .handle = entity.skinned_mesh.?.mesh_handle,
                    .primitive = entity.skinned_mesh.?.primitive,
                };
            try render_world.meshes.append(render_world.allocator, .{
                .entity_id = entity.id,
                .transform = world_transform,
                .mesh = extracted_mesh,
                .material = entity.material,
                .selected = is_selected,
            });
            stats.extracted_meshes += 1;
        }

        if (entity.vfx) |vfx| {
            stats.total_vfxs += 1;
            if (!entity_visible_in_frustum) {
                continue;
            }

            try render_world.vfxs.append(render_world.allocator, .{
                .entity_id = entity.id,
                .transform = world_transform,
                .vfx = vfx,
                .selected = is_selected,
            });
            stats.extracted_vfxs += 1;
        }
    }

    return stats;
}

fn isEntitySelected(
    id: scene_mod.EntityId,
    primary_selection: ?scene_mod.EntityId,
    selection_list: []const scene_mod.EntityId,
) bool {
    if (primary_selection != null and primary_selection.? == id) {
        return true;
    }
    for (selection_list) |selected_id| {
        if (selected_id == id) {
            return true;
        }
    }
    return false;
}
