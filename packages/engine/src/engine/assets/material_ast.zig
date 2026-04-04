const std = @import("std");
const components = @import("../scene/components.zig");
const handles = @import("handles.zig");
const material_model_mod = @import("material_model.zig");
const material_resource_mod = @import("material_resource.zig");

pub const TextureSlots = struct {
    base_color: ?handles.TextureHandle = null,
    metallic_roughness: ?handles.TextureHandle = null,
    normal: ?handles.TextureHandle = null,
    occlusion: ?handles.TextureHandle = null,
    emissive: ?handles.TextureHandle = null,
};

// MaterialAst is a small renderer-agnostic intermediate representation.
// Phase 1 keeps this flat and close to MaterialResource for safe adoption.
pub const MaterialAst = struct {
    name: []const u8,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
    use_ibl: bool = true,
    ibl_intensity: f32 = 1.0,
    textures: TextureSlots = .{},
    inheritance: material_model_mod.MaterialInheritanceInfo = .{},
    graph: ?material_model_mod.MaterialGraph = null,

    pub fn fromResource(resource: *const material_resource_mod.MaterialResource) MaterialAst {
        return .{
            .name = resource.name,
            .shading = resource.shading,
            .base_color_factor = resource.base_color_factor,
            .emissive_factor = resource.emissive_factor,
            .metallic_factor = resource.metallic_factor,
            .roughness_factor = resource.roughness_factor,
            .alpha_cutoff = resource.alpha_cutoff,
            .double_sided = resource.double_sided,
            .use_ibl = resource.use_ibl,
            .ibl_intensity = resource.ibl_intensity,
            .textures = .{
                .base_color = resource.base_color_texture,
                .metallic_roughness = resource.metallic_roughness_texture,
                .normal = resource.normal_texture,
                .occlusion = resource.occlusion_texture,
                .emissive = resource.emissive_texture,
            },
            .inheritance = resource.inheritance,
            .graph = resource.graph,
        };
    }

    pub fn toResourceDesc(self: *const MaterialAst) material_resource_mod.MaterialResourceDesc {
        return .{
            .name = self.name,
            .shading = self.shading,
            .base_color_factor = self.base_color_factor,
            .base_color_texture = self.textures.base_color,
            .metallic_roughness_texture = self.textures.metallic_roughness,
            .normal_texture = self.textures.normal,
            .occlusion_texture = self.textures.occlusion,
            .emissive_texture = self.textures.emissive,
            .emissive_factor = self.emissive_factor,
            .metallic_factor = self.metallic_factor,
            .roughness_factor = self.roughness_factor,
            .alpha_cutoff = self.alpha_cutoff,
            .double_sided = self.double_sided,
            .use_ibl = self.use_ibl,
            .ibl_intensity = self.ibl_intensity,
            .inheritance = self.inheritance,
            .graph = self.graph,
        };
    }

    pub fn canonicalGraphAlloc(self: *const MaterialAst, allocator: std.mem.Allocator) !material_model_mod.MaterialGraph {
        var nodes = std.ArrayList(material_model_mod.MaterialGraphNode).empty;
        defer nodes.deinit(allocator);
        var outputs = std.ArrayList(material_model_mod.MaterialGraphOutput).empty;
        defer outputs.deinit(allocator);

        var next_id: u32 = 1;

        const base_color_node = next_id;
        next_id += 1;
        try nodes.append(allocator, .{
            .id = base_color_node,
            .kind = .input_parameter,
            .output_type = .vec4,
            .channel = .base_color,
            .value = .{ .kind = .vec4, .vec4 = self.base_color_factor },
        });
        try outputs.append(allocator, .{ .channel = .base_color, .source_node_id = try nodeForTextureOrFallback(self.textures.base_color, .base_color, .vec4, base_color_node, &nodes, allocator, &next_id) });

        const metallic_node = next_id;
        next_id += 1;
        try nodes.append(allocator, .{
            .id = metallic_node,
            .kind = .input_parameter,
            .output_type = .scalar,
            .channel = .metallic,
            .value = .{ .kind = .scalar, .scalar = self.metallic_factor },
        });

        const roughness_node = next_id;
        next_id += 1;
        try nodes.append(allocator, .{
            .id = roughness_node,
            .kind = .input_parameter,
            .output_type = .scalar,
            .channel = .roughness,
            .value = .{ .kind = .scalar, .scalar = self.roughness_factor },
        });

        if (self.textures.metallic_roughness) |texture| {
            const metallic_texture_node = next_id;
            next_id += 1;
            try nodes.append(allocator, .{
                .id = metallic_texture_node,
                .kind = .texture_sample,
                .output_type = .vec4,
                .channel = .metallic,
                .value = .{ .kind = .texture, .texture = texture },
            });
            try outputs.append(allocator, .{ .channel = .metallic, .source_node_id = metallic_texture_node });

            const roughness_texture_node = next_id;
            next_id += 1;
            try nodes.append(allocator, .{
                .id = roughness_texture_node,
                .kind = .split_channels,
                .output_type = .scalar,
                .channel = .roughness,
                .value = .{ .kind = .texture, .texture = texture },
            });
            try outputs.append(allocator, .{ .channel = .roughness, .source_node_id = roughness_texture_node });
        } else {
            try outputs.append(allocator, .{ .channel = .metallic, .source_node_id = metallic_node });
            try outputs.append(allocator, .{ .channel = .roughness, .source_node_id = roughness_node });
        }

        const emissive_node = next_id;
        next_id += 1;
        try nodes.append(allocator, .{
            .id = emissive_node,
            .kind = .input_parameter,
            .output_type = .vec3,
            .channel = .emissive,
            .value = .{ .kind = .vec3, .vec3 = self.emissive_factor },
        });
        try outputs.append(allocator, .{ .channel = .emissive, .source_node_id = try nodeForTextureOrFallback(self.textures.emissive, .emissive, .vec3, emissive_node, &nodes, allocator, &next_id) });

        const alpha_node = next_id;
        next_id += 1;
        try nodes.append(allocator, .{
            .id = alpha_node,
            .kind = .constant,
            .output_type = .scalar,
            .channel = .alpha_cutoff,
            .value = .{ .kind = .scalar, .scalar = self.alpha_cutoff },
        });
        try outputs.append(allocator, .{ .channel = .alpha_cutoff, .source_node_id = alpha_node });

        if (self.textures.normal) |texture| {
            const normal_node = next_id;
            next_id += 1;
            try nodes.append(allocator, .{
                .id = normal_node,
                .kind = .normal_map,
                .output_type = .vec3,
                .channel = .normal,
                .value = .{ .kind = .texture, .texture = texture },
            });
            try outputs.append(allocator, .{ .channel = .normal, .source_node_id = normal_node });
        }

        if (self.textures.occlusion) |texture| {
            const occlusion_node = next_id;
            next_id += 1;
            try nodes.append(allocator, .{
                .id = occlusion_node,
                .kind = .texture_sample,
                .output_type = .scalar,
                .channel = .occlusion,
                .value = .{ .kind = .texture, .texture = texture },
            });
            try outputs.append(allocator, .{ .channel = .occlusion, .source_node_id = occlusion_node });
        }

        return .{
            .nodes = try nodes.toOwnedSlice(allocator),
            .connections = &.{},
            .outputs = try outputs.toOwnedSlice(allocator),
        };
    }
};

fn nodeForTextureOrFallback(
    texture: ?handles.TextureHandle,
    channel: material_model_mod.MaterialChannel,
    output_type: material_model_mod.MaterialGraphSocketType,
    fallback_node_id: u32,
    nodes: *std.ArrayList(material_model_mod.MaterialGraphNode),
    allocator: std.mem.Allocator,
    next_id: *u32,
) !u32 {
    if (texture) |resolved| {
        const node_id = next_id.*;
        next_id.* += 1;
        try nodes.append(allocator, .{
            .id = node_id,
            .kind = .texture_sample,
            .output_type = output_type,
            .channel = channel,
            .value = .{ .kind = .texture, .texture = resolved },
        });
        return node_id;
    }
    return fallback_node_id;
}

test "MaterialAst.fromResource maps all phase-1 fields" {
    const resource: material_resource_mod.MaterialResource = .{
        .name = @constCast("MatA"),
        .shading = .lambert,
        .base_color_factor = .{ 0.1, 0.2, 0.3, 0.4 },
        .base_color_texture = @enumFromInt(2),
        .metallic_roughness_texture = @enumFromInt(3),
        .normal_texture = @enumFromInt(4),
        .occlusion_texture = @enumFromInt(5),
        .emissive_texture = @enumFromInt(6),
        .emissive_factor = .{ 0.7, 0.8, 0.9 },
        .metallic_factor = 0.25,
        .roughness_factor = 0.75,
        .alpha_cutoff = 0.42,
        .double_sided = true,
        .use_ibl = false,
        .ibl_intensity = 1.6,
        .inheritance = .{
            .parent_material_handle = @enumFromInt(7),
            .parent_material_name_hint = "Root",
            .generation = 1,
        },
    };

    const ast = MaterialAst.fromResource(&resource);
    try std.testing.expectEqual(components.ShadingModel.lambert, ast.shading);
    try std.testing.expectEqual(resource.base_color_factor, ast.base_color_factor);
    try std.testing.expectEqual(resource.emissive_factor, ast.emissive_factor);
    try std.testing.expectEqual(resource.metallic_factor, ast.metallic_factor);
    try std.testing.expectEqual(resource.roughness_factor, ast.roughness_factor);
    try std.testing.expectEqual(resource.alpha_cutoff, ast.alpha_cutoff);
    try std.testing.expectEqual(resource.double_sided, ast.double_sided);
    try std.testing.expectEqual(resource.use_ibl, ast.use_ibl);
    try std.testing.expectEqual(resource.ibl_intensity, ast.ibl_intensity);
    try std.testing.expectEqual(resource.inheritance.parent_material_handle, ast.inheritance.parent_material_handle);
    try std.testing.expectEqualStrings(resource.inheritance.parent_material_name_hint.?, ast.inheritance.parent_material_name_hint.?);
    try std.testing.expectEqual(resource.base_color_texture, ast.textures.base_color);
    try std.testing.expectEqual(resource.metallic_roughness_texture, ast.textures.metallic_roughness);
    try std.testing.expectEqual(resource.normal_texture, ast.textures.normal);
    try std.testing.expectEqual(resource.occlusion_texture, ast.textures.occlusion);
    try std.testing.expectEqual(resource.emissive_texture, ast.textures.emissive);
}

test "MaterialAst.toResourceDesc maps all phase-1 fields" {
    const ast: MaterialAst = .{
        .name = "AstMat",
        .shading = .pbr_metallic_roughness,
        .base_color_factor = .{ 0.9, 0.6, 0.4, 1.0 },
        .emissive_factor = .{ 0.05, 0.1, 0.2 },
        .metallic_factor = 0.33,
        .roughness_factor = 0.66,
        .alpha_cutoff = 0.12,
        .double_sided = true,
        .use_ibl = true,
        .ibl_intensity = 0.8,
        .inheritance = .{
            .parent_material_handle = @enumFromInt(21),
            .parent_material_name_hint = "Parent",
            .generation = 2,
        },
        .textures = .{
            .base_color = @enumFromInt(11),
            .metallic_roughness = @enumFromInt(12),
            .normal = @enumFromInt(13),
            .occlusion = @enumFromInt(14),
            .emissive = @enumFromInt(15),
        },
    };

    const desc = ast.toResourceDesc();
    try std.testing.expectEqualStrings(ast.name, desc.name);
    try std.testing.expectEqual(ast.shading, desc.shading);
    try std.testing.expectEqual(ast.base_color_factor, desc.base_color_factor);
    try std.testing.expectEqual(ast.emissive_factor, desc.emissive_factor);
    try std.testing.expectEqual(ast.metallic_factor, desc.metallic_factor);
    try std.testing.expectEqual(ast.roughness_factor, desc.roughness_factor);
    try std.testing.expectEqual(ast.alpha_cutoff, desc.alpha_cutoff);
    try std.testing.expectEqual(ast.double_sided, desc.double_sided);
    try std.testing.expectEqual(ast.use_ibl, desc.use_ibl);
    try std.testing.expectEqual(ast.ibl_intensity, desc.ibl_intensity);
    try std.testing.expectEqual(ast.inheritance.parent_material_handle, desc.inheritance.parent_material_handle);
    try std.testing.expectEqualStrings(ast.inheritance.parent_material_name_hint.?, desc.inheritance.parent_material_name_hint.?);
    try std.testing.expectEqual(ast.textures.base_color, desc.base_color_texture);
    try std.testing.expectEqual(ast.textures.metallic_roughness, desc.metallic_roughness_texture);
    try std.testing.expectEqual(ast.textures.normal, desc.normal_texture);
    try std.testing.expectEqual(ast.textures.occlusion, desc.occlusion_texture);
    try std.testing.expectEqual(ast.textures.emissive, desc.emissive_texture);
}

test "MaterialAst.canonicalGraphAlloc seeds phase-2 graph outputs" {
    const ast: MaterialAst = .{
        .name = "GraphSeed",
        .base_color_factor = .{ 0.8, 0.7, 0.6, 1.0 },
        .emissive_factor = .{ 0.1, 0.2, 0.3 },
        .metallic_factor = 0.4,
        .roughness_factor = 0.5,
        .alpha_cutoff = 0.25,
        .textures = .{
            .base_color = @enumFromInt(5),
            .normal = @enumFromInt(6),
        },
    };

    var graph = try ast.canonicalGraphAlloc(std.testing.allocator);
    defer material_model_mod.deinitGraph(std.testing.allocator, &graph);

    try std.testing.expect(graph.nodes.len >= 5);
    try std.testing.expect(graph.outputs.len >= 5);
}
