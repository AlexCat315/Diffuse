///! handlers/material.zig — material editing via RPC.
///!
///! Reads/writes Material component + MaterialResource for the selected entity.
///! Follows the same ensureEditable pattern as the ImGui material editor.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

const handles = @import("../../assets/handles.zig");
const material_resource_mod = @import("../../assets/material_resource.zig");
const material_ast_mod = @import("../../assets/material_ast.zig");
const components = @import("../../scene/components.zig");

// ── Preview state (static — no EditorState in RPC ctx) ─────────
const PreviewPrimitive = enum { sphere, plane };
var preview_primitive: PreviewPrimitive = .sphere;

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
        .previewPrimitive = @tagName(preview_primitive),
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
        preview_primitive = .sphere;
    } else if (strEql(prim_str, "plane")) {
        preview_primitive = .plane;
    } else return error.InvalidArguments;
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
