///! assets/material_editing.zig — shared material editing utilities.
///!
///! Pure engine-level helper functions for material editing workflows.
///! Used by both the RPC handler (editor_rpc/handlers/material.zig) and
///! the editor backend (editor_backend/actions/material_ops.zig).
///!
///! All functions are independent of EditorState — they operate solely
///! on World / ResourceLibrary / Entity data.
const std = @import("std");
const handles = @import("handles.zig");
const material_mod = @import("material_resource.zig");
const library_mod = @import("library.zig");
const world_mod = @import("../scene/world.zig");
const components = @import("../scene/components.zig");

pub const MaterialResource = material_mod.MaterialResource;
pub const MaterialHandle = handles.MaterialHandle;

/// Count how many entities in the world reference the given material handle.
pub fn materialUsageCount(world: *const world_mod.World, handle: MaterialHandle) usize {
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

/// Ensure the entity has an exclusively-owned material resource.
///
/// - If the material has no handle, creates a new resource from component fields.
/// - If the material handle is valid and used by only one entity, returns it directly.
/// - If the material is shared (used by multiple entities), clones it into a
///   new instance with inheritance tracking, and reassigns the component handle.
///
/// Returns `null` if the entity has no material component.
pub fn ensureEditable(
    allocator: std.mem.Allocator,
    world: *world_mod.World,
    entity: *world_mod.Entity,
) !?*MaterialResource {
    const mat = if (entity.material) |*value| value else return null;

    if (mat.handle) |material_handle| {
        // If only one entity uses it, it's already exclusively owned.
        if (materialUsageCount(world, material_handle) <= 1) {
            const res = world.assets().material(material_handle) orelse return null;
            return @constCast(res);
        }

        // Shared material — clone into a new instance.
        const source = world.assets().material(material_handle) orelse return null;
        const instance_name = try std.fmt.allocPrint(allocator, "{s} Material", .{entity.name});
        defer allocator.free(instance_name);

        const new_handle = try world.assets().createMaterial(.{
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
        mat.handle = new_handle;
        syncComponentFromResource(mat, source);
        return @constCast(world.assets().material(new_handle).?);
    }

    // No handle — create a brand-new resource from component fields.
    const instance_name = try std.fmt.allocPrint(allocator, "{s} Material", .{entity.name});
    defer allocator.free(instance_name);

    const new_handle = try world.assets().createMaterial(.{
        .name = instance_name,
        .shading = mat.shading,
        .base_color_factor = mat.base_color_factor,
        .emissive_factor = mat.emissive_factor,
        .metallic_factor = mat.metallic_factor,
        .roughness_factor = mat.roughness_factor,
        .alpha_cutoff = mat.alpha_cutoff,
        .double_sided = mat.double_sided,
        .inheritance = .{},
    });
    mat.handle = new_handle;
    return @constCast(world.assets().material(new_handle).?);
}

/// Sync material component fields from a resource after mutation.
pub fn syncComponentFromResource(mat: *components.Material, res: *const MaterialResource) void {
    mat.shading = res.shading;
    mat.base_color_factor = res.base_color_factor;
    mat.emissive_factor = res.emissive_factor;
    mat.metallic_factor = res.metallic_factor;
    mat.roughness_factor = res.roughness_factor;
    mat.alpha_cutoff = res.alpha_cutoff;
    mat.double_sided = res.double_sided;
}
