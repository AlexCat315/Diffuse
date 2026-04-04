const std = @import("std");
const engine = @import("guava");
const EditorState = @import("../core/state.zig").EditorState;
const utils = @import("../common/utils.zig");
const history = @import("history.zig");

pub fn addMaterialComponent(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
) !void {
    if (entity.material != null) {
        return;
    }
    const material_handle = try layer_context.world.assets().ensureDefaultMaterial();
    entity.material = .{
        .handle = material_handle,
    };
    try history.captureSnapshot(state, layer_context);
}

pub fn ensureEditableMaterialResource(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    entity: *engine.scene.Entity,
) !?*engine.assets.MaterialResource {
    const allocator = state.allocator orelse layer_context.world.allocator;
    const material_component = if (entity.material) |*value| value else return null;

    if (material_component.handle) |material_handle| {
        if (materialUsageCount(state, layer_context.world, material_handle) <= 1) {
            const material_resource = layer_context.world.assets().material(material_handle) orelse return null;
            return @constCast(material_resource);
        }

        const source = layer_context.world.assets().material(material_handle) orelse return null;
        const instance_name = try std.fmt.allocPrint(allocator, "{s} Material", .{entity.name});
        defer allocator.free(instance_name);

        const new_handle = try layer_context.world.assets().createMaterial(.{
            .name = instance_name,
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
                .parent_material_handle = material_handle,
                .parent_material_name_hint = source.name,
                .generation = source.inheritance.generation + 1,
            },
            .graph = source.graph,
        });
        material_component.handle = new_handle;
        material_component.shading = source.shading;
        material_component.base_color_factor = source.base_color_factor;
        material_component.emissive_factor = source.emissive_factor;
        material_component.metallic_factor = source.metallic_factor;
        material_component.roughness_factor = source.roughness_factor;
        material_component.alpha_cutoff = source.alpha_cutoff;
        material_component.double_sided = source.double_sided;
        return @constCast(layer_context.world.assets().material(new_handle).?);
    }

    const instance_name = try std.fmt.allocPrint(allocator, "{s} Material", .{entity.name});
    defer allocator.free(instance_name);

    const new_handle = try layer_context.world.assets().createMaterial(.{
        .name = instance_name,
        .shading = material_component.shading,
        .base_color_factor = material_component.base_color_factor,
        .emissive_factor = material_component.emissive_factor,
        .metallic_factor = material_component.metallic_factor,
        .roughness_factor = material_component.roughness_factor,
        .alpha_cutoff = material_component.alpha_cutoff,
        .double_sided = material_component.double_sided,
        .inheritance = .{},
    });
    material_component.handle = new_handle;
    return @constCast(layer_context.world.assets().material(new_handle).?);
}

pub fn materialHandleForEntity(_: *const EditorState, entity: *const engine.scene.Entity) ?engine.assets.MaterialHandle {
    if (entity.material) |material_component| {
        return material_component.handle;
    }
    return null;
}

pub fn materialUsageCount(_: *const EditorState, world: *const engine.scene.World, handle: engine.assets.MaterialHandle) usize {
    var count: usize = 0;
    for (world.entities.items) |entity| {
        if (entity.material) |material| {
            if (material.handle) |candidate| {
                if (candidate == handle) {
                    count += 1;
                }
            }
        }
    }
    return count;
}

pub fn importTextureAsset(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    asset_id: []const u8,
    path: []const u8,
) !engine.assets.TextureHandle {
    if (state.asset_registry) |*registry| {
        if (registry.recordById(asset_id) != null) {
            return engine.assets.loadTextureAsset(
                state.allocator orelse layer_context.world.allocator,
                layer_context.world.assets(),
                registry,
                asset_id,
            );
        }
    }

    for (layer_context.world.assets().textures.items, 0..) |texture, index| {
        if (std.mem.eql(u8, texture.name, path)) {
            return @enumFromInt(index + 1);
        }
    }

    const allocator = state.allocator orelse layer_context.world.allocator;
    const encoded = try std.fs.cwd().readFileAlloc(allocator, path, 128 * 1024 * 1024);
    defer allocator.free(encoded);

    var decoded = try engine.assets.decodeImageRgba8(allocator, encoded);
    defer decoded.deinit();
    utils.swizzleRgbaToBgra(decoded.pixels);

    return layer_context.world.assets().createTexture(.{
        .name = path,
        .width = decoded.width,
        .height = decoded.height,
        .pixels = decoded.pixels,
    });
}
