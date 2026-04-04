///! handlers/material.zig — material editing via RPC.
///!
///! Reads/writes Material component + MaterialResource for the selected entity.
///! Follows the same ensureEditable pattern as the old material editor.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

const handles = @import("../../assets/handles.zig");
const material_resource_mod = @import("../../assets/material_resource.zig");
const material_ast_mod = @import("../../assets/material_ast.zig");
const material_model = @import("../../assets/material_model.zig");
const components = @import("../../scene/components.zig");

// ── Preview state (shared via EditorSettings) ──────────────────
const PreviewPrimitive = @import("../settings.zig").EditorSettings.PreviewPrimitive;

// ── Helpers ─────────────────────────────────────────────────────

fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn handleToU32(comptime T: type, h: ?T) u32 {
    return if (h) |v| @intFromEnum(v) else 0;
}

fn u32ToHandle(comptime T: type, v: u32) ?T {
    if (v == 0) return null;
    return @enumFromInt(v);
}

/// Get the entity's material component (mutable).
fn getMaterialEntity(ctx: *Ctx) !struct { eid: u64, entity: *ctx_mod.Entity, mat: *components.Material } {
    const eid = try ctx.param(u64, "entityId");
    const entity = ctx.layer.world.getEntity(eid) orelse return error.EntityNotFound;
    const mat = if (entity.material) |*m| m else return error.InvalidArguments;
    return .{ .eid = eid, .entity = entity, .mat = mat };
}

/// Ensure a mutable MaterialResource exists for the entity.
/// If there's a handle, return the resource mutably (via constCast like the editor).
/// If no handle, create a new embedded one.
fn ensureEditableResource(ctx: *Ctx, entity: *ctx_mod.Entity, mat: *components.Material) !*material_resource_mod.MaterialResource {
    if (mat.handle) |h| {
        if (ctx.layer.world.assets().material(h)) |res| {
            return @constCast(res);
        }
    }
    // No handle or handle invalid → create new resource
    const new_handle = try ctx.layer.world.assets().createMaterial(.{
        .name = entity.name,
        .shading = mat.shading,
        .base_color_factor = mat.base_color_factor,
        .emissive_factor = mat.emissive_factor,
        .metallic_factor = mat.metallic_factor,
        .roughness_factor = mat.roughness_factor,
        .alpha_cutoff = mat.alpha_cutoff,
        .double_sided = mat.double_sided,
    });
    mat.handle = new_handle;
    return @constCast(ctx.layer.world.assets().material(new_handle).?);
}

/// Sync component fields from resource after a resource change.
fn syncComponentFromResource(mat: *components.Material, res: *const material_resource_mod.MaterialResource) void {
    mat.shading = res.shading;
    mat.base_color_factor = res.base_color_factor;
    mat.emissive_factor = res.emissive_factor;
    mat.metallic_factor = res.metallic_factor;
    mat.roughness_factor = res.roughness_factor;
    mat.alpha_cutoff = res.alpha_cutoff;
    mat.double_sided = res.double_sided;
}

// ═══════════════════════════════════════════════════════════════════
//  RPC handlers — one pub fn per method
// ═══════════════════════════════════════════════════════════════════

/// material.getState(entityId) → full material snapshot
pub fn getState(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const entity = ctx.layer.world.getEntityConst(eid) orelse return error.EntityNotFound;
    const mat = entity.material orelse {
        try ctx.reply(.{ .hasMaterial = false });
        return;
    };

    // Base component data
    var result_shading: []const u8 = "pbr_metallic_roughness";
    if (mat.shading == .unlit) result_shading = "unlit";
    if (mat.shading == .lambert) result_shading = "lambert";

    // Texture handles + resource data
    var tex_base_color: u32 = 0;
    var tex_metallic_roughness: u32 = 0;
    var tex_normal: u32 = 0;
    var tex_occlusion: u32 = 0;
    var tex_emissive: u32 = 0;
    var use_ibl: bool = true;
    var ibl_intensity: f32 = 1.0;
    var material_name: []const u8 = "";
    var is_shared: bool = false;
    var parent_handle: u32 = 0;
    var generation: u32 = 0;

    if (mat.handle) |h| {
        if (ctx.layer.world.assets().material(h)) |res| {
            tex_base_color = handleToU32(handles.TextureHandle, res.base_color_texture);
            tex_metallic_roughness = handleToU32(handles.TextureHandle, res.metallic_roughness_texture);
            tex_normal = handleToU32(handles.TextureHandle, res.normal_texture);
            tex_occlusion = handleToU32(handles.TextureHandle, res.occlusion_texture);
            tex_emissive = handleToU32(handles.TextureHandle, res.emissive_texture);
            use_ibl = res.use_ibl;
            ibl_intensity = res.ibl_intensity;
            material_name = res.name;
            parent_handle = handleToU32(handles.MaterialHandle, res.inheritance.parent_material_handle);
            generation = res.inheritance.generation;
        }
        // Count usage across all entities
        is_shared = countUsage(ctx.layer.world, h) > 1;
    }

    try ctx.reply(.{
        .hasMaterial = true,
        .name = material_name,
        .shading = result_shading,
        .baseColor = &mat.base_color_factor,
        .emissive = &mat.emissive_factor,
        .metallic = mat.metallic_factor,
        .roughness = mat.roughness_factor,
        .alphaCutoff = mat.alpha_cutoff,
        .doubleSided = mat.double_sided,
        .useIBL = use_ibl,
        .iblIntensity = ibl_intensity,
        .texBaseColor = tex_base_color,
        .texMetallicRoughness = tex_metallic_roughness,
        .texNormal = tex_normal,
        .texOcclusion = tex_occlusion,
        .texEmissive = tex_emissive,
        .isShared = is_shared,
        .materialHandle = handleToU32(handles.MaterialHandle, mat.handle),
        .parentHandle = parent_handle,
        .generation = generation,
        .previewPrimitive = @tagName(ctx.settings.material.preview_primitive),
    });
}

fn countUsage(world: *ctx_mod.World, target: handles.MaterialHandle) usize {
    var count: usize = 0;
    for (world.entities.items) |entity| {
        if (entity.material) |m| {
            if (m.handle) |h| {
                if (h == target) count += 1;
            }
        }
    }
    return count;
}

/// material.setShading(entityId, mode)
pub fn setShading(ctx: *Ctx) !void {
    const r = try getMaterialEntity(ctx);
    const mode_str = try ctx.param([]const u8, "mode");
    const shading: components.ShadingModel = if (strEql(mode_str, "unlit"))
        .unlit
    else if (strEql(mode_str, "lambert"))
        .lambert
    else if (strEql(mode_str, "pbr_metallic_roughness"))
        .pbr_metallic_roughness
    else
        return error.InvalidArguments;

    r.mat.shading = shading;
    const res = try ensureEditableResource(ctx, r.entity, r.mat);
    res.shading = shading;
    ctx.layer.world.markDirty(r.eid);
    try ctx.reply(.{});
}

/// material.setColor(entityId, property, value)
pub fn setColor(ctx: *Ctx) !void {
    const r = try getMaterialEntity(ctx);
    const prop = try ctx.param([]const u8, "property");
    const arr = try ctx.paramArray("value");
    if (arr.items.len < 3) return error.InvalidArguments;

    const res = try ensureEditableResource(ctx, r.entity, r.mat);

    if (strEql(prop, "base_color")) {
        const a: f32 = if (arr.items.len >= 4) floatFromJson(arr.items[3]) else r.mat.base_color_factor[3];
        r.mat.base_color_factor = .{ floatFromJson(arr.items[0]), floatFromJson(arr.items[1]), floatFromJson(arr.items[2]), a };
        res.base_color_factor = r.mat.base_color_factor;
    } else if (strEql(prop, "emissive")) {
        r.mat.emissive_factor = .{ floatFromJson(arr.items[0]), floatFromJson(arr.items[1]), floatFromJson(arr.items[2]) };
        res.emissive_factor = r.mat.emissive_factor;
    } else return error.InvalidArguments;

    ctx.layer.world.markDirty(r.eid);
    try ctx.reply(.{});
}

/// material.setScalar(entityId, property, value)
pub fn setScalar(ctx: *Ctx) !void {
    const r = try getMaterialEntity(ctx);
    const prop = try ctx.param([]const u8, "property");
    const val = try ctx.param(f32, "value");

    const res = try ensureEditableResource(ctx, r.entity, r.mat);

    if (strEql(prop, "metallic")) {
        r.mat.metallic_factor = val;
        res.metallic_factor = val;
    } else if (strEql(prop, "roughness")) {
        r.mat.roughness_factor = val;
        res.roughness_factor = val;
    } else if (strEql(prop, "alpha_cutoff")) {
        r.mat.alpha_cutoff = val;
        res.alpha_cutoff = val;
    } else if (strEql(prop, "ibl_intensity")) {
        res.ibl_intensity = val;
    } else return error.InvalidArguments;

    ctx.layer.world.markDirty(r.eid);
    try ctx.reply(.{});
}

/// material.setFlag(entityId, property, value)
pub fn setFlag(ctx: *Ctx) !void {
    const r = try getMaterialEntity(ctx);
    const prop = try ctx.param([]const u8, "property");
    const val = try ctx.param(bool, "value");

    const res = try ensureEditableResource(ctx, r.entity, r.mat);

    if (strEql(prop, "double_sided")) {
        r.mat.double_sided = val;
        res.double_sided = val;
    } else if (strEql(prop, "use_ibl")) {
        res.use_ibl = val;
    } else return error.InvalidArguments;

    ctx.layer.world.markDirty(r.eid);
    try ctx.reply(.{});
}

/// material.assignTexture(entityId, slot, textureHandle)
pub fn assignTexture(ctx: *Ctx) !void {
    const r = try getMaterialEntity(ctx);
    const slot = try ctx.param([]const u8, "slot");
    const raw_handle: u32 = @intCast(try ctx.param(u64, "textureHandle"));
    const tex_handle = u32ToHandle(handles.TextureHandle, raw_handle);

    // Validate handle if non-null
    if (tex_handle) |h| {
        if (ctx.layer.world.assets().texture(h) == null) return error.InvalidArguments;
    }

    const res = try ensureEditableResource(ctx, r.entity, r.mat);

    if (strEql(slot, "base_color")) {
        res.base_color_texture = tex_handle;
    } else if (strEql(slot, "metallic_roughness")) {
        res.metallic_roughness_texture = tex_handle;
    } else if (strEql(slot, "normal")) {
        res.normal_texture = tex_handle;
    } else if (strEql(slot, "occlusion")) {
        res.occlusion_texture = tex_handle;
    } else if (strEql(slot, "emissive")) {
        res.emissive_texture = tex_handle;
    } else return error.InvalidArguments;

    ctx.layer.world.markDirty(r.eid);
    try ctx.reply(.{});
}

/// material.clearTexture(entityId, slot)
pub fn clearTexture(ctx: *Ctx) !void {
    const r = try getMaterialEntity(ctx);
    const slot = try ctx.param([]const u8, "slot");

    const res = try ensureEditableResource(ctx, r.entity, r.mat);

    if (strEql(slot, "base_color")) {
        res.base_color_texture = null;
    } else if (strEql(slot, "metallic_roughness")) {
        res.metallic_roughness_texture = null;
    } else if (strEql(slot, "normal")) {
        res.normal_texture = null;
    } else if (strEql(slot, "occlusion")) {
        res.occlusion_texture = null;
    } else if (strEql(slot, "emissive")) {
        res.emissive_texture = null;
    } else return error.InvalidArguments;

    ctx.layer.world.markDirty(r.eid);
    try ctx.reply(.{});
}

/// material.makeUnique(entityId) — clone shared material to entity-local instance
pub fn makeUnique(ctx: *Ctx) !void {
    const r = try getMaterialEntity(ctx);
    const current_handle = r.mat.handle orelse {
        // Already embedded (no handle). Create new resource.
        _ = try ensureEditableResource(ctx, r.entity, r.mat);
        try ctx.reply(.{ .newHandle = handleToU32(handles.MaterialHandle, r.mat.handle), .wasShared = false });
        return;
    };

    const source = ctx.layer.world.assets().material(current_handle) orelse return error.InvalidArguments;

    // Create clone with inheritance linkage
    const new_handle = try ctx.layer.world.assets().createMaterial(.{
        .name = r.entity.name,
        .shading = source.shading,
        .base_color_factor = source.base_color_factor,
        .base_color_texture = source.base_color_texture,
        .metallic_roughness_texture = source.metallic_roughness_texture,
        .normal_texture = source.normal_texture,
        .occlusion_texture = source.occlusion_texture,
        .emissive_texture = source.emissive_texture,
        .emissive_factor = source.emissive_factor,
        .metallic_factor = source.metallic_factor,
        .roughness_factor = source.roughness_factor,
        .alpha_cutoff = source.alpha_cutoff,
        .double_sided = source.double_sided,
        .use_ibl = source.use_ibl,
        .ibl_intensity = source.ibl_intensity,
        .inheritance = .{
            .parent_material_handle = current_handle,
            .parent_material_name_hint = source.name,
            .generation = source.inheritance.generation + 1,
        },
        .graph = source.graph,
    });

    r.mat.handle = new_handle;
    syncComponentFromResource(r.mat, ctx.layer.world.assets().material(new_handle).?);
    ctx.layer.world.markDirty(r.eid);

    try ctx.reply(.{
        .newHandle = handleToU32(handles.MaterialHandle, new_handle),
        .wasShared = true,
        .generation = source.inheritance.generation + 1,
    });
}

/// material.getTextureInfo(textureHandle) → texture metadata
pub fn getTextureInfo(ctx: *Ctx) !void {
    const raw_handle: u32 = @intCast(try ctx.param(u64, "textureHandle"));
    const tex_handle = u32ToHandle(handles.TextureHandle, raw_handle) orelse return error.InvalidArguments;
    const tex = ctx.layer.world.assets().texture(tex_handle) orelse {
        try ctx.reply(.{ .found = false });
        return;
    };
    try ctx.reply(.{
        .found = true,
        .name = tex.name,
        .width = tex.width,
        .height = tex.height,
        .format = @tagName(tex.format),
    });
}

/// material.listTextures() → all loaded texture handles + names
pub fn listTextures(ctx: *Ctx) !void {
    const lib = ctx.layer.world.assets();
    const textures = lib.textures.items;

    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(ctx.allocator);

    try appendSlice(&buf, ctx.allocator, "{\"textures\":[");
    var first = true;
    for (textures, 0..) |*tex, i| {
        const h = handles.textureHandle(i);
        if (!handles.isValid(h)) continue;
        if (!first) try appendSlice(&buf, ctx.allocator, ",");
        first = false;
        // Manual JSON for performance
        try appendSlice(&buf, ctx.allocator, "{\"handle\":");
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{@intFromEnum(h)}) catch "0";
        try appendSlice(&buf, ctx.allocator, num_str);
        try appendSlice(&buf, ctx.allocator, ",\"name\":\"");
        try appendSlice(&buf, ctx.allocator, tex.name);
        try appendSlice(&buf, ctx.allocator, "\",\"width\":");
        const w_str = std.fmt.bufPrint(&num_buf, "{d}", .{tex.width}) catch "0";
        try appendSlice(&buf, ctx.allocator, w_str);
        try appendSlice(&buf, ctx.allocator, ",\"height\":");
        const h_str = std.fmt.bufPrint(&num_buf, "{d}", .{tex.height}) catch "0";
        try appendSlice(&buf, ctx.allocator, h_str);
        try appendSlice(&buf, ctx.allocator, "}");
    }
    try appendSlice(&buf, ctx.allocator, "]}");

    ctx.replyRaw(try buf.toOwnedSlice(ctx.allocator));
}

/// material.setPreviewPrimitive(primitive)
pub fn setPreviewPrimitive(ctx: *Ctx) !void {
    const prim_str = try ctx.param([]const u8, "primitive");
    if (strEql(prim_str, "sphere")) {
        ctx.settings.material.preview_primitive = .sphere;
    } else if (strEql(prim_str, "plane")) {
        ctx.settings.material.preview_primitive = .plane;
    } else return error.InvalidArguments;
    try ctx.reply(.{});
}

// ═══════════════════════════════════════════════════════════════════
//  Material graph editing handlers
// ═══════════════════════════════════════════════════════════════════

/// Node positions keyed by (entityId ^ (nodeId << 32)).
var node_positions: std.AutoHashMap(u64, [2]f32) = std.AutoHashMap(u64, [2]f32).init(std.heap.page_allocator);

fn posKey(eid: u64, node_id: u32) u64 {
    return eid ^ (@as(u64, node_id) << 32);
}

fn getNodePos(eid: u64, node_id: u32) [2]f32 {
    return node_positions.get(posKey(eid, node_id)) orelse .{ 0, 0 };
}

fn nodeKindStr(kind: material_model.MaterialGraphNodeKind) []const u8 {
    return @tagName(kind);
}

fn socketTypeStr(st: material_model.MaterialGraphSocketType) []const u8 {
    return @tagName(st);
}

fn channelStr(ch: ?material_model.MaterialChannel) ?[]const u8 {
    return if (ch) |c| @tagName(c) else null;
}

fn valueKindStr(vk: material_model.MaterialGraphValueKind) []const u8 {
    return @tagName(vk);
}

fn parseNodeKind(s: []const u8) ?material_model.MaterialGraphNodeKind {
    inline for (@typeInfo(material_model.MaterialGraphNodeKind).@"enum".fields) |f| {
        if (strEql(s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

fn parseSocketType(s: []const u8) ?material_model.MaterialGraphSocketType {
    inline for (@typeInfo(material_model.MaterialGraphSocketType).@"enum".fields) |f| {
        if (strEql(s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

fn parseChannel(s: []const u8) ?material_model.MaterialChannel {
    inline for (@typeInfo(material_model.MaterialChannel).@"enum".fields) |f| {
        if (strEql(s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

fn parseValueKind(s: []const u8) ?material_model.MaterialGraphValueKind {
    inline for (@typeInfo(material_model.MaterialGraphValueKind).@"enum".fields) |f| {
        if (strEql(s, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

/// Get the graph from a material resource (or null).
fn getGraphFromEntity(ctx: *Ctx) !struct { eid: u64, res: *material_resource_mod.MaterialResource, graph: *material_model.MaterialGraph } {
    const r = try getMaterialEntity(ctx);
    const res = try ensureEditableResource(ctx, r.entity, r.mat);
    if (res.graph) |*g| return .{ .eid = r.eid, .res = res, .graph = g };
    return error.InvalidArguments;
}

/// material.getGraph(entityId) → full MaterialGraph snapshot
pub fn getGraph(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const entity = ctx.layer.world.getEntityConst(eid) orelse return error.EntityNotFound;
    const mat = entity.material orelse {
        try ctx.reply(.{ .hasGraph = false });
        return;
    };

    const graph_opt: ?material_model.MaterialGraph = blk: {
        if (mat.handle) |h| {
            if (ctx.layer.world.assets().material(h)) |res| {
                break :blk res.graph;
            }
        }
        break :blk null;
    };

    const graph = graph_opt orelse {
        try ctx.reply(.{ .hasGraph = false });
        return;
    };

    // Build JSON manually for performance
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(ctx.allocator);

    try appendSlice(&buf, ctx.allocator, "{\"hasGraph\":true,\"nodes\":[");
    for (graph.nodes, 0..) |node, i| {
        if (i > 0) try appendSlice(&buf, ctx.allocator, ",");
        try appendSlice(&buf, ctx.allocator, "{\"id\":");
        try appendNum(&buf, ctx.allocator, @as(i64, node.id));
        try appendSlice(&buf, ctx.allocator, ",\"kind\":\"");
        try appendSlice(&buf, ctx.allocator, nodeKindStr(node.kind));
        try appendSlice(&buf, ctx.allocator, "\",\"outputType\":\"");
        try appendSlice(&buf, ctx.allocator, socketTypeStr(node.output_type));
        try appendSlice(&buf, ctx.allocator, "\"");
        if (channelStr(node.channel)) |ch| {
            try appendSlice(&buf, ctx.allocator, ",\"channel\":\"");
            try appendSlice(&buf, ctx.allocator, ch);
            try appendSlice(&buf, ctx.allocator, "\"");
        }
        try appendSlice(&buf, ctx.allocator, ",\"valueKind\":\"");
        try appendSlice(&buf, ctx.allocator, valueKindStr(node.value.kind));
        try appendSlice(&buf, ctx.allocator, "\",\"scalar\":");
        try appendFloat(&buf, ctx.allocator, node.value.scalar);
        try appendSlice(&buf, ctx.allocator, ",\"vec2\":[");
        try appendFloat(&buf, ctx.allocator, node.value.vec2[0]);
        try appendSlice(&buf, ctx.allocator, ",");
        try appendFloat(&buf, ctx.allocator, node.value.vec2[1]);
        try appendSlice(&buf, ctx.allocator, "],\"vec3\":[");
        try appendFloat(&buf, ctx.allocator, node.value.vec3[0]);
        try appendSlice(&buf, ctx.allocator, ",");
        try appendFloat(&buf, ctx.allocator, node.value.vec3[1]);
        try appendSlice(&buf, ctx.allocator, ",");
        try appendFloat(&buf, ctx.allocator, node.value.vec3[2]);
        try appendSlice(&buf, ctx.allocator, "],\"vec4\":[");
        try appendFloat(&buf, ctx.allocator, node.value.vec4[0]);
        try appendSlice(&buf, ctx.allocator, ",");
        try appendFloat(&buf, ctx.allocator, node.value.vec4[1]);
        try appendSlice(&buf, ctx.allocator, ",");
        try appendFloat(&buf, ctx.allocator, node.value.vec4[2]);
        try appendSlice(&buf, ctx.allocator, ",");
        try appendFloat(&buf, ctx.allocator, node.value.vec4[3]);
        try appendSlice(&buf, ctx.allocator, "]");
        if (node.value.texture) |th| {
            try appendSlice(&buf, ctx.allocator, ",\"textureHandle\":");
            try appendNum(&buf, ctx.allocator, @as(i64, @intFromEnum(th)));
        }
        const pos = getNodePos(eid, node.id);
        try appendSlice(&buf, ctx.allocator, ",\"posX\":");
        try appendFloat(&buf, ctx.allocator, pos[0]);
        try appendSlice(&buf, ctx.allocator, ",\"posY\":");
        try appendFloat(&buf, ctx.allocator, pos[1]);
        try appendSlice(&buf, ctx.allocator, "}");
    }

    try appendSlice(&buf, ctx.allocator, "],\"connections\":[");
    for (graph.connections, 0..) |conn, i| {
        if (i > 0) try appendSlice(&buf, ctx.allocator, ",");
        try appendSlice(&buf, ctx.allocator, "{\"fromNodeId\":");
        try appendNum(&buf, ctx.allocator, @as(i64, conn.from_node_id));
        try appendSlice(&buf, ctx.allocator, ",\"fromSlot\":");
        try appendNum(&buf, ctx.allocator, @as(i64, conn.from_slot));
        try appendSlice(&buf, ctx.allocator, ",\"toNodeId\":");
        try appendNum(&buf, ctx.allocator, @as(i64, conn.to_node_id));
        try appendSlice(&buf, ctx.allocator, ",\"toSlot\":");
        try appendNum(&buf, ctx.allocator, @as(i64, conn.to_slot));
        try appendSlice(&buf, ctx.allocator, "}");
    }

    try appendSlice(&buf, ctx.allocator, "],\"outputs\":[");
    for (graph.outputs, 0..) |out, i| {
        if (i > 0) try appendSlice(&buf, ctx.allocator, ",");
        try appendSlice(&buf, ctx.allocator, "{\"channel\":\"");
        try appendSlice(&buf, ctx.allocator, @tagName(out.channel));
        try appendSlice(&buf, ctx.allocator, "\",\"sourceNodeId\":");
        try appendNum(&buf, ctx.allocator, @as(i64, out.source_node_id));
        try appendSlice(&buf, ctx.allocator, ",\"sourceSlot\":");
        try appendNum(&buf, ctx.allocator, @as(i64, out.source_slot));
        try appendSlice(&buf, ctx.allocator, "}");
    }

    try appendSlice(&buf, ctx.allocator, "]}");
    ctx.replyRaw(try buf.toOwnedSlice(ctx.allocator));
}

/// material.addGraphNode(entityId, kind, posX?, posY?)
pub fn addGraphNode(ctx: *Ctx) !void {
    const r = try getMaterialEntity(ctx);
    const res = try ensureEditableResource(ctx, r.entity, r.mat);

    const kind_str = try ctx.param([]const u8, "kind");
    const kind = parseNodeKind(kind_str) orelse return error.InvalidArguments;
    const pos_x: f32 = @floatCast(try ctx.paramOpt(f64, "posX") orelse 0.0);
    const pos_y: f32 = @floatCast(try ctx.paramOpt(f64, "posY") orelse 0.0);

    // Determine next node ID
    var max_id: u32 = 0;
    if (res.graph) |graph| {
        for (graph.nodes) |n| {
            if (n.id > max_id) max_id = n.id;
        }
    }
    const new_id = max_id + 1;

    // Default output type based on kind
    const default_output_type: material_model.MaterialGraphSocketType = switch (kind) {
        .texture_sample => .vec4,
        .normal_map => .vec3,
        .split_channels => .scalar,
        .output => .surface,
        else => .scalar,
    };

    const new_node = material_model.MaterialGraphNode{
        .id = new_id,
        .kind = kind,
        .output_type = default_output_type,
    };

    // Ensure graph exists
    if (res.graph == null) {
        res.graph = .{};
    }

    // Grow the nodes array
    var graph = &res.graph.?;
    const old_nodes = graph.nodes;
    const new_nodes = try ctx.allocator.alloc(material_model.MaterialGraphNode, old_nodes.len + 1);
    @memcpy(new_nodes[0..old_nodes.len], old_nodes);
    new_nodes[old_nodes.len] = new_node;
    if (old_nodes.len > 0) ctx.allocator.free(old_nodes);
    graph.nodes = new_nodes;

    // Save position
    try node_positions.put(posKey(r.eid, new_id), .{ pos_x, pos_y });

    ctx.layer.world.markDirty(r.eid);
    try ctx.reply(.{ .nodeId = new_id });
}

/// material.removeGraphNode(entityId, nodeId)
pub fn removeGraphNode(ctx: *Ctx) !void {
    const g = try getGraphFromEntity(ctx);
    const node_id: u32 = @intCast(try ctx.param(u64, "nodeId"));

    // Remove the node
    var new_nodes = try ctx.allocator.alloc(material_model.MaterialGraphNode, g.graph.nodes.len);
    var write: usize = 0;
    for (g.graph.nodes) |n| {
        if (n.id != node_id) {
            new_nodes[write] = n;
            write += 1;
        }
    }
    if (write == g.graph.nodes.len) {
        ctx.allocator.free(new_nodes);
        return error.InvalidArguments; // node not found
    }
    if (g.graph.nodes.len > 0) ctx.allocator.free(g.graph.nodes);
    g.graph.nodes = new_nodes[0..write];

    // Remove connections referencing this node
    var new_conns = try ctx.allocator.alloc(material_model.MaterialGraphConnection, g.graph.connections.len);
    var cw: usize = 0;
    for (g.graph.connections) |c| {
        if (c.from_node_id != node_id and c.to_node_id != node_id) {
            new_conns[cw] = c;
            cw += 1;
        }
    }
    if (g.graph.connections.len > 0) ctx.allocator.free(g.graph.connections);
    g.graph.connections = new_conns[0..cw];

    // Remove outputs referencing this node
    var new_outs = try ctx.allocator.alloc(material_model.MaterialGraphOutput, g.graph.outputs.len);
    var ow: usize = 0;
    for (g.graph.outputs) |o| {
        if (o.source_node_id != node_id) {
            new_outs[ow] = o;
            ow += 1;
        }
    }
    if (g.graph.outputs.len > 0) ctx.allocator.free(g.graph.outputs);
    g.graph.outputs = new_outs[0..ow];

    // Remove position
    _ = node_positions.remove(posKey(g.eid, node_id));

    ctx.layer.world.markDirty(g.eid);
    try ctx.reply(.{});
}

/// material.updateGraphNode(entityId, nodeId, channel?, outputType?, valueKind?, scalar?, vec2?, vec3?, vec4?, textureHandle?)
pub fn updateGraphNode(ctx: *Ctx) !void {
    const g = try getGraphFromEntity(ctx);
    const node_id: u32 = @intCast(try ctx.param(u64, "nodeId"));

    var found = false;
    for (g.graph.nodes) |*node| {
        if (node.id != node_id) continue;
        found = true;

        if (try ctx.paramOpt([]const u8, "channel")) |ch_str| {
            node.channel = parseChannel(ch_str);
        }
        if (try ctx.paramOpt([]const u8, "outputType")) |ot_str| {
            if (parseSocketType(ot_str)) |st| node.output_type = st;
        }
        if (try ctx.paramOpt([]const u8, "valueKind")) |vk_str| {
            if (parseValueKind(vk_str)) |vk| node.value.kind = vk;
        }
        if (try ctx.paramOpt(f64, "scalar")) |s| {
            node.value.scalar = @floatCast(s);
        }
        if (ctx.paramArray("vec2")) |arr| {
            if (arr.items.len >= 2) {
                node.value.vec2 = .{
                    floatFromJson(arr.items[0]),
                    floatFromJson(arr.items[1]),
                };
            }
        } else |_| {}
        if (ctx.paramArray("vec3")) |arr| {
            if (arr.items.len >= 3) {
                node.value.vec3 = .{
                    floatFromJson(arr.items[0]),
                    floatFromJson(arr.items[1]),
                    floatFromJson(arr.items[2]),
                };
            }
        } else |_| {}
        if (ctx.paramArray("vec4")) |arr| {
            if (arr.items.len >= 4) {
                node.value.vec4 = .{
                    floatFromJson(arr.items[0]),
                    floatFromJson(arr.items[1]),
                    floatFromJson(arr.items[2]),
                    floatFromJson(arr.items[3]),
                };
            }
        } else |_| {}
        if (try ctx.paramOpt(u64, "textureHandle")) |th| {
            node.value.texture = u32ToHandle(handles.TextureHandle, @intCast(th));
        }
        break;
    }

    if (!found) return error.InvalidArguments;
    ctx.layer.world.markDirty(g.eid);
    try ctx.reply(.{});
}

/// material.addGraphConnection(entityId, fromNodeId, fromSlot, toNodeId, toSlot)
pub fn addGraphConnection(ctx: *Ctx) !void {
    const g = try getGraphFromEntity(ctx);
    const from_id: u32 = @intCast(try ctx.param(u64, "fromNodeId"));
    const from_slot: u8 = @intCast(try ctx.paramOpt(u64, "fromSlot") orelse 0);
    const to_id: u32 = @intCast(try ctx.param(u64, "toNodeId"));
    const to_slot: u8 = @intCast(try ctx.paramOpt(u64, "toSlot") orelse 0);

    // Prevent duplicate
    for (g.graph.connections) |c| {
        if (c.from_node_id == from_id and c.from_slot == from_slot and
            c.to_node_id == to_id and c.to_slot == to_slot)
        {
            try ctx.reply(.{});
            return;
        }
    }

    const new_conn = material_model.MaterialGraphConnection{
        .from_node_id = from_id,
        .from_slot = from_slot,
        .to_node_id = to_id,
        .to_slot = to_slot,
    };

    const old = g.graph.connections;
    const new_conns = try ctx.allocator.alloc(material_model.MaterialGraphConnection, old.len + 1);
    @memcpy(new_conns[0..old.len], old);
    new_conns[old.len] = new_conn;
    if (old.len > 0) ctx.allocator.free(old);
    g.graph.connections = new_conns;

    ctx.layer.world.markDirty(g.eid);
    try ctx.reply(.{});
}

/// material.removeGraphConnection(entityId, fromNodeId, fromSlot, toNodeId, toSlot)
pub fn removeGraphConnection(ctx: *Ctx) !void {
    const g = try getGraphFromEntity(ctx);
    const from_id: u32 = @intCast(try ctx.param(u64, "fromNodeId"));
    const from_slot: u8 = @intCast(try ctx.paramOpt(u64, "fromSlot") orelse 0);
    const to_id: u32 = @intCast(try ctx.param(u64, "toNodeId"));
    const to_slot: u8 = @intCast(try ctx.paramOpt(u64, "toSlot") orelse 0);

    var new_conns = try ctx.allocator.alloc(material_model.MaterialGraphConnection, g.graph.connections.len);
    var w: usize = 0;
    for (g.graph.connections) |c| {
        if (c.from_node_id == from_id and c.from_slot == from_slot and
            c.to_node_id == to_id and c.to_slot == to_slot)
            continue;
        new_conns[w] = c;
        w += 1;
    }
    if (g.graph.connections.len > 0) ctx.allocator.free(g.graph.connections);
    g.graph.connections = new_conns[0..w];

    ctx.layer.world.markDirty(g.eid);
    try ctx.reply(.{});
}

/// material.setGraphOutput(entityId, channel, sourceNodeId, sourceSlot)
pub fn setGraphOutput(ctx: *Ctx) !void {
    const g = try getGraphFromEntity(ctx);
    const ch_str = try ctx.param([]const u8, "channel");
    const channel = parseChannel(ch_str) orelse return error.InvalidArguments;
    const src_id: u32 = @intCast(try ctx.param(u64, "sourceNodeId"));
    const src_slot: u8 = @intCast(try ctx.paramOpt(u64, "sourceSlot") orelse 0);

    // Update existing or append
    for (g.graph.outputs) |*o| {
        if (o.channel == channel) {
            o.source_node_id = src_id;
            o.source_slot = src_slot;
            ctx.layer.world.markDirty(g.eid);
            try ctx.reply(.{});
            return;
        }
    }

    // Append new output
    const old = g.graph.outputs;
    const new_outs = try ctx.allocator.alloc(material_model.MaterialGraphOutput, old.len + 1);
    @memcpy(new_outs[0..old.len], old);
    new_outs[old.len] = .{ .channel = channel, .source_node_id = src_id, .source_slot = src_slot };
    if (old.len > 0) ctx.allocator.free(old);
    g.graph.outputs = new_outs;

    ctx.layer.world.markDirty(g.eid);
    try ctx.reply(.{});
}

/// material.removeGraphOutput(entityId, channel)
pub fn removeGraphOutput(ctx: *Ctx) !void {
    const g = try getGraphFromEntity(ctx);
    const ch_str = try ctx.param([]const u8, "channel");
    const channel = parseChannel(ch_str) orelse return error.InvalidArguments;

    var new_outs = try ctx.allocator.alloc(material_model.MaterialGraphOutput, g.graph.outputs.len);
    var w: usize = 0;
    for (g.graph.outputs) |o| {
        if (o.channel != channel) {
            new_outs[w] = o;
            w += 1;
        }
    }
    if (g.graph.outputs.len > 0) ctx.allocator.free(g.graph.outputs);
    g.graph.outputs = new_outs[0..w];

    ctx.layer.world.markDirty(g.eid);
    try ctx.reply(.{});
}

/// material.setNodePosition(entityId, nodeId, posX, posY)
pub fn setNodePosition(ctx: *Ctx) !void {
    const eid = try ctx.param(u64, "entityId");
    const node_id: u32 = @intCast(try ctx.param(u64, "nodeId"));
    const px: f32 = @floatCast(try ctx.param(f64, "posX"));
    const py: f32 = @floatCast(try ctx.param(f64, "posY"));
    try node_positions.put(posKey(eid, node_id), .{ px, py });
    try ctx.reply(.{});
}

// ── Utility ─────────────────────────────────────────────────────

fn floatFromJson(val: std.json.Value) f32 {
    return switch (val) {
        .float => |f| @floatCast(f),
        .integer => |i| @floatFromInt(i),
        else => 0.0,
    };
}

fn appendSlice(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, data: []const u8) !void {
    try buf.appendSlice(allocator, data);
}

fn appendNum(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, val: i64) !void {
    var num_buf: [24]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch "0";
    try buf.appendSlice(allocator, num_str);
}

fn appendFloat(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, val: f32) !void {
    var num_buf: [32]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{val}) catch "0";
    try buf.appendSlice(allocator, num_str);
}
