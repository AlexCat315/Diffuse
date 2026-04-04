const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;
const state_mod = @import("../core/state.zig");

const AssetKind = state_mod.AssetKind;
const AssetEntry = state_mod.AssetEntry;
const HierarchyCategory = state_mod.HierarchyCategory;

pub fn assetKindForPath(path: []const u8) ?AssetKind {
    if (std.mem.endsWith(u8, path, ".guava_scene")) {
        return .scene;
    }
    if (std.mem.endsWith(u8, path, ".gltf")) {
        return .model;
    }
    if (std.mem.endsWith(u8, path, ".png") or std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg") or std.mem.endsWith(u8, path, ".svg")) {
        return .texture;
    }
    if (std.mem.endsWith(u8, path, ".glsl") or std.mem.endsWith(u8, path, ".spv") or std.mem.endsWith(u8, path, ".json")) {
        return .shader;
    }
    if (std.mem.endsWith(u8, path, ".cs") or std.mem.endsWith(u8, path, ".zig") or std.mem.endsWith(u8, path, ".csproj")) {
        return .script;
    }
    return null;
}

pub fn lessThanAssetEntry(_: void, lhs: AssetEntry, rhs: AssetEntry) bool {
    if (@intFromEnum(lhs.kind) != @intFromEnum(rhs.kind)) {
        return @intFromEnum(lhs.kind) < @intFromEnum(rhs.kind);
    }
    return std.mem.lessThan(u8, lhs.display_path, rhs.display_path);
}

fn assetKindMatchesTypeFilter(entry: AssetEntry, type_name: []const u8) bool {
    if (std.mem.eql(u8, type_name, "scene") or std.mem.eql(u8, type_name, "scenes")) {
        return entry.kind == .scene;
    }
    if (std.mem.eql(u8, type_name, "model") or std.mem.eql(u8, type_name, "models") or std.mem.eql(u8, type_name, "mesh")) {
        return entry.kind == .model;
    }
    if (std.mem.eql(u8, type_name, "material") or std.mem.eql(u8, type_name, "materials") or std.mem.eql(u8, type_name, "mat")) {
        return entry.kind == .material;
    }
    if (std.mem.eql(u8, type_name, "texture") or std.mem.eql(u8, type_name, "textures") or std.mem.eql(u8, type_name, "tex") or std.mem.eql(u8, type_name, "hdr")) {
        return entry.kind == .texture;
    }
    if (std.mem.eql(u8, type_name, "shader") or std.mem.eql(u8, type_name, "shaders")) {
        return entry.kind == .shader;
    }
    return false;
}

fn splitAssetFilter(filter: []const u8) ?struct { type_name: []const u8, remainder: []const u8 } {
    if (std.mem.startsWith(u8, filter, "t:")) {
        const body = filter[2..];
        const separator = std.mem.indexOfScalar(u8, body, ' ') orelse body.len;
        return .{
            .type_name = std.mem.trim(u8, body[0..separator], " \t"),
            .remainder = std.mem.trim(u8, body[@min(separator + 1, body.len)..], " \t"),
        };
    }
    if (std.mem.startsWith(u8, filter, "type:")) {
        const body = filter[5..];
        const separator = std.mem.indexOfScalar(u8, body, ' ') orelse body.len;
        return .{
            .type_name = std.mem.trim(u8, body[0..separator], " \t"),
            .remainder = std.mem.trim(u8, body[@min(separator + 1, body.len)..], " \t"),
        };
    }
    return null;
}

pub fn containsAsciiInsensitive(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) {
        return true;
    }
    if (needle.len > haystack.len) {
        return false;
    }

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matches = true;
        for (needle, 0..) |needle_char, offset| {
            if (std.ascii.toLower(haystack[start + offset]) != std.ascii.toLower(needle_char)) {
                matches = false;
                break;
            }
        }
        if (matches) {
            return true;
        }
    }
    return false;
}

pub fn startsWith(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) {
        return true;
    }
    if (needle.len > haystack.len) {
        return false;
    }
    return std.mem.eql(u8, haystack[0..needle.len], needle);
}

pub fn zeroTerminatedSlice(buffer: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, buffer, 0) orelse buffer.len;
    return buffer[0..end];
}

pub fn viewportDrawableSize(window: *const engine.platform.Window, logical_extent: [2]f32) [2]u32 {
    if (logical_extent[0] < 1.0 or logical_extent[1] < 1.0 or window.logical_width == 0 or window.logical_height == 0 or window.drawable_width == 0 or window.drawable_height == 0) {
        return .{ 0, 0 };
    }

    const scale_x = @as(f32, @floatFromInt(window.drawable_width)) / @as(f32, @floatFromInt(window.logical_width));
    const scale_y = @as(f32, @floatFromInt(window.drawable_height)) / @as(f32, @floatFromInt(window.logical_height));
    return .{
        @max(@as(u32, @intFromFloat(@max(logical_extent[0] * scale_x, 0.0))), 1),
        @max(@as(u32, @intFromFloat(@max(logical_extent[1] * scale_y, 0.0))), 1),
    };
}

pub fn swizzleRgbaToBgra(bytes: []u8) void {
    var index: usize = 0;
    while (index + 3 < bytes.len) : (index += 4) {
        const r = bytes[index];
        bytes[index] = bytes[index + 2];
        bytes[index + 2] = r;
    }
}

pub fn normalizeAngle(angle: f32) f32 {
    var normalized = angle;
    while (normalized > std.math.pi) {
        normalized -= std.math.tau;
    }
    while (normalized < -std.math.pi) {
        normalized += std.math.tau;
    }
    return normalized;
}

pub fn clampPitch(pitch: f32) f32 {
    return normalizeAngle(pitch);
}

pub fn clampDistance(distance: f32) f32 {
    return std.math.clamp(distance, 1.5, 40.0);
}

pub fn clampScale(scale: f32) f32 {
    return std.math.clamp(scale, 0.05, 100.0);
}

pub fn assetKindLabel(state: *const EditorState, kind: AssetKind) []const u8 {
    return switch (kind) {
        .scene => state.text(.scene),
        .model => state.text(.model),
        .material => state.text(.material_asset),
        .texture => state.text(.texture),
        .shader => state.text(.shader),
        .script => state.text(.script_asset),
        .directory => "Folder",
        .unknown => "File",
    };
}

pub fn primitiveLabel(state: *const EditorState, primitive: engine.scene.Primitive) []const u8 {
    return switch (primitive) {
        .cube => state.text(.cube),
        .sphere => state.text(.sphere),
        .plane => state.text(.plane),
        .custom => state.text(.custom),
    };
}

pub fn shadingLabel(state: *const EditorState, shading: engine.scene.ShadingModel) []const u8 {
    return switch (shading) {
        .unlit => state.text(.unlit),
        .lambert => state.text(.lambert),
        .pbr_metallic_roughness => state.text(.pbr),
    };
}

pub fn audioBusLabel(state: *const EditorState, bus: engine.scene.AudioBus) []const u8 {
    return switch (bus) {
        .master => state.text(.audio_bus_master),
        .music => state.text(.audio_bus_music),
        .sfx => state.text(.audio_bus_sfx),
    };
}

pub fn isEntitySelected(_: *const EditorState, layer_context: *const engine.core.LayerContext, entity_id: engine.scene.EntityId) bool {
    for (layer_context.renderer.selectedEntities()) |selected_id| {
        if (selected_id == entity_id) {
            return true;
        }
    }
    return false;
}

pub fn hasVisibleChildren(_: *const EditorState, world: *const engine.scene.World, entity_id: engine.scene.EntityId) bool {
    for (world.entities.items) |entity| {
        if (!entity.editor_only and entity.parent == entity_id) {
            return true;
        }
    }
    return false;
}

pub fn hasVisibleSceneTreeChildren(state: *const EditorState, world: *const engine.scene.World, entity_id: engine.scene.EntityId) bool {
    for (world.entities.items) |entity| {
        if (entity.editor_only or entity.parent != entity_id) {
            continue;
        }
        if (shouldShowEntityInSceneTree(state, world, entity.id)) {
            return true;
        }
    }
    return false;
}

pub fn shouldShowEntityInSceneTree(state: *const EditorState, world: *const engine.scene.World, entity_id: engine.scene.EntityId) bool {
    const scene_filter = zeroTerminatedSlice(state.scene_filter_buffer[0..]);
    if (scene_filter.len != 0) {
        // Show if self/descendants match, OR if any ancestor matches (keeps tree connected)
        if (!entityMatchesFilterRecursive(state, world, entity_id, scene_filter) and
            !ancestorMatchesFilter(state, world, entity_id, scene_filter))
        {
            return false;
        }
    }

    const hierarchy_filter = zeroTerminatedSlice(state.hierarchy_filter_buffer[0..]);
    if (hierarchy_filter.len != 0 or state.hierarchy_category != .all) {
        if (!entityMatchesHierarchyFilterRecursive(state, world, entity_id, hierarchy_filter) and
            !ancestorMatchesHierarchyFilter(state, world, entity_id, hierarchy_filter))
        {
            return false;
        }
    }
    return true;
}

/// Check if any ancestor of entity_id matches the filter text.
/// This ensures parent nodes remain visible when a deep child matches.
pub fn ancestorMatchesFilter(
    state: *const EditorState,
    world: *const engine.scene.World,
    entity_id: engine.scene.EntityId,
    filter: []const u8,
) bool {
    const entity = world.getEntityConst(entity_id) orelse return false;
    const parent_id = entity.parent orelse return false;
    const parent = world.getEntityConst(parent_id) orelse return false;
    if (parent.editor_only) return false;
    if (containsAsciiInsensitive(parent.name, filter)) return true;
    return ancestorMatchesFilter(state, world, parent_id, filter);
}

/// Check if any ancestor matches the hierarchy filter (text + category).
pub fn ancestorMatchesHierarchyFilter(
    state: *const EditorState,
    world: *const engine.scene.World,
    entity_id: engine.scene.EntityId,
    hierarchy_filter: []const u8,
) bool {
    const entity = world.getEntityConst(entity_id) orelse return false;
    const parent_id = entity.parent orelse return false;
    const parent = world.getEntityConst(parent_id) orelse return false;
    if (parent.editor_only) return false;
    if (hierarchy_filter.len == 0 or containsAsciiInsensitive(parent.name, hierarchy_filter)) {
        if (entityMatchesHierarchyCategory(state.hierarchy_category, parent)) return true;
    }
    return ancestorMatchesHierarchyFilter(state, world, parent_id, hierarchy_filter);
}

pub fn entityMatchesFilterRecursive(
    state: *const EditorState,
    world: *const engine.scene.World,
    entity_id: engine.scene.EntityId,
    filter: []const u8,
) bool {
    const entity = world.getEntityConst(entity_id) orelse return false;
    if (containsAsciiInsensitive(entity.name, filter)) {
        return true;
    }
    for (world.entities.items) |child| {
        if (!child.editor_only and child.parent == entity_id and entityMatchesFilterRecursive(state, world, child.id, filter)) {
            return true;
        }
    }
    return false;
}

pub fn entityMatchesHierarchyFilterRecursive(
    state: *const EditorState,
    world: *const engine.scene.World,
    entity_id: engine.scene.EntityId,
    hierarchy_filter: []const u8,
) bool {
    const entity = world.getEntityConst(entity_id) orelse return false;
    if (entityMatchesHierarchyFilter(state, entity, hierarchy_filter)) {
        return true;
    }
    for (world.entities.items) |child| {
        if (!child.editor_only and child.parent == entity_id and entityMatchesHierarchyFilterRecursive(state, world, child.id, hierarchy_filter)) {
            return true;
        }
    }
    return false;
}

pub fn entityMatchesHierarchyFilter(state: *const EditorState, entity: *const engine.scene.Entity, hierarchy_filter: []const u8) bool {
    if (hierarchy_filter.len != 0 and !containsAsciiInsensitive(entity.name, hierarchy_filter)) {
        return false;
    }
    return entityMatchesHierarchyCategory(state.hierarchy_category, entity);
}

pub fn entityMatchesHierarchyCategory(category: HierarchyCategory, entity: *const engine.scene.Entity) bool {
    return switch (category) {
        .all => true,
        .cameras => entity.camera != null,
        .lights => entity.light != null,
        .geometry => entity.mesh != null,
        .objects => entity.camera == null and entity.light == null and entity.mesh == null,
    };
}

pub fn assetMatchesFilter(state: *const EditorState, entry: AssetEntry) bool {
    const filter = zeroTerminatedSlice(state.asset_filter_buffer[0..]);
    if (filter.len == 0) {
        return true;
    }

    if (splitAssetFilter(filter)) |typed_filter| {
        if (typed_filter.type_name.len == 0 or !assetKindMatchesTypeFilter(entry, typed_filter.type_name)) {
            return false;
        }
        if (typed_filter.remainder.len == 0) {
            return true;
        }
        return containsAsciiInsensitive(entry.name, typed_filter.remainder) or containsAsciiInsensitive(entry.display_path, typed_filter.remainder);
    }

    return containsAsciiInsensitive(entry.name, filter) or containsAsciiInsensitive(entry.display_path, filter);
}

pub fn syncInspectorNameBuffer(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const selected = layer_context.renderer.selectedEntity();
    if (selected == state.inspector_name_entity) {
        return;
    }

    @memset(state.inspector_name_buffer[0..], 0);
    if (selected) |selected_id| {
        if (layer_context.world.getEntityConst(selected_id)) |entity| {
            const copy_len = @min(entity.name.len, state.inspector_name_buffer.len - 1);
            @memcpy(state.inspector_name_buffer[0..copy_len], entity.name[0..copy_len]);
        }
    }
    state.inspector_name_entity = selected;
}

pub fn entityPath(buffer: []u8, world: *const engine.scene.World, entity_id: engine.scene.EntityId) ![]const u8 {
    var segments: [64][]const u8 = undefined;
    var segment_count: usize = 0;
    var current: ?engine.scene.EntityId = entity_id;
    while (current) |current_id| {
        const entity = world.getEntityConst(current_id) orelse break;
        if (segment_count == segments.len) {
            return error.NoSpaceLeft;
        }
        segments[segment_count] = entity.name;
        segment_count += 1;
        current = entity.parent;
    }

    var stream = std.io.fixedBufferStream(buffer);
    const writer = stream.writer();
    if (segment_count == 0) {
        try writer.writeAll("/");
        return stream.getWritten();
    }

    var index = segment_count;
    while (index > 0) {
        index -= 1;
        try writer.writeAll("/");
        try writer.writeAll(segments[index]);
    }
    return stream.getWritten();
}

pub fn estimatedWorldMemoryBytes(world: *const engine.scene.World) usize {
    const MeshResourceType = std.meta.Child(@TypeOf(world.resources.meshes.items));
    const MaterialResourceType = std.meta.Child(@TypeOf(world.resources.materials.items));
    const TextureResourceType = std.meta.Child(@TypeOf(world.resources.textures.items));
    var total: usize = 0;
    total += world.entities.items.len * @sizeOf(engine.scene.Entity);
    for (world.entities.items) |entity| {
        total += entity.name.len;
    }

    total += world.resources.meshes.items.len * @sizeOf(MeshResourceType);
    for (world.resources.meshes.items) |mesh| {
        total += mesh.name.len;
        if (mesh.vertices.len > 0) {
            total += mesh.vertices.len * @sizeOf(@TypeOf(mesh.vertices[0]));
        }
        total += mesh.indices.len * @sizeOf(u32);
    }

    total += world.resources.materials.items.len * @sizeOf(MaterialResourceType);
    for (world.resources.materials.items) |material| {
        total += material.name.len;
    }

    total += world.resources.textures.items.len * @sizeOf(TextureResourceType);
    for (world.resources.textures.items) |texture| {
        total += texture.name.len;
        total += texture.pixels.len;
    }
    return total;
}

pub fn isEntitySelectionLocked(state: *const EditorState, entity_id: engine.scene.EntityId) bool {
    for (state.selection_locked_entities.items) |locked_entity_id| {
        if (locked_entity_id == entity_id) {
            return true;
        }
    }
    return false;
}

pub fn setEntitySelectionLocked(state: *EditorState, entity_id: engine.scene.EntityId, locked: bool) !bool {
    const allocator = state.allocator orelse return false;
    for (state.selection_locked_entities.items, 0..) |locked_entity_id, index| {
        if (locked_entity_id != entity_id) {
            continue;
        }
        if (!locked) {
            _ = state.selection_locked_entities.orderedRemove(index);
            return true;
        }
        return false;
    }
    if (!locked) {
        return false;
    }
    try state.selection_locked_entities.append(allocator, entity_id);
    return true;
}

pub fn toggleEntitySelectionLocked(state: *EditorState, entity_id: engine.scene.EntityId) !bool {
    const was_locked = isEntitySelectionLocked(state, entity_id);
    _ = try setEntitySelectionLocked(state, entity_id, !was_locked);
    return !was_locked;
}

pub fn pruneSelectionLockEntities(state: *EditorState, world: *const engine.scene.World) void {
    var index: usize = 0;
    while (index < state.selection_locked_entities.items.len) {
        if (world.hasEntity(state.selection_locked_entities.items[index])) {
            index += 1;
            continue;
        }
        _ = state.selection_locked_entities.orderedRemove(index);
    }
}

pub fn pruneLockedSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const current_selection = layer_context.renderer.selectedEntities();
    if (current_selection.len == 0) {
        return;
    }

    const allocator = state.allocator orelse return;
    var unlocked = std.ArrayList(engine.scene.EntityId).empty;
    defer unlocked.deinit(allocator);

    for (current_selection) |entity_id| {
        if (!isEntitySelectionLocked(state, entity_id)) {
            try unlocked.append(allocator, entity_id);
        }
    }

    if (unlocked.items.len == current_selection.len) {
        return;
    }

    try layer_context.renderer.replaceSelectionMany(unlocked.items);
    if (state.manipulation_entity) |entity_id| {
        if (isEntitySelectionLocked(state, entity_id)) {
            state.manipulation_mode = .none;
            state.manipulation_axis = .free;
            state.manipulation_entity = null;
        }
    }
}

pub fn isEntityFrozen(state: *const EditorState, entity_id: engine.scene.EntityId) bool {
    for (state.frozen_entities.items) |frozen_entity_id| {
        if (frozen_entity_id == entity_id) {
            return true;
        }
    }
    return false;
}

pub fn setEntityFrozen(state: *EditorState, entity_id: engine.scene.EntityId, frozen: bool) !bool {
    const allocator = state.allocator orelse return false;
    for (state.frozen_entities.items, 0..) |frozen_entity_id, index| {
        if (frozen_entity_id != entity_id) {
            continue;
        }
        if (!frozen) {
            _ = state.frozen_entities.orderedRemove(index);
            return true;
        }
        return false;
    }
    if (!frozen) {
        return false;
    }
    try state.frozen_entities.append(allocator, entity_id);
    return true;
}

pub fn toggleEntityFrozen(state: *EditorState, entity_id: engine.scene.EntityId) !bool {
    const was_frozen = isEntityFrozen(state, entity_id);
    _ = try setEntityFrozen(state, entity_id, !was_frozen);
    return !was_frozen;
}

pub fn pruneFrozenEntities(state: *EditorState, world: *const engine.scene.World) void {
    var index: usize = 0;
    while (index < state.frozen_entities.items.len) {
        if (world.hasEntity(state.frozen_entities.items[index])) {
            index += 1;
            continue;
        }
        _ = state.frozen_entities.orderedRemove(index);
    }
}

pub fn pruneFrozenSelection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const current_selection = layer_context.renderer.selectedEntities();
    if (current_selection.len == 0) {
        return;
    }

    const allocator = state.allocator orelse return;
    var unfrozen = std.ArrayList(engine.scene.EntityId).empty;
    defer unfrozen.deinit(allocator);

    for (current_selection) |entity_id| {
        if (!isEntityFrozen(state, entity_id)) {
            try unfrozen.append(allocator, entity_id);
        }
    }

    if (unfrozen.items.len == current_selection.len) {
        return;
    }

    try layer_context.renderer.replaceSelectionMany(unfrozen.items);
    if (state.manipulation_entity) |entity_id| {
        if (isEntityFrozen(state, entity_id)) {
            state.manipulation_mode = .none;
            state.manipulation_axis = .free;
            state.manipulation_entity = null;
        }
    }
}
