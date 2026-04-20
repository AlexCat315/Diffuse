const std = @import("std");
const handles = @import("handles.zig");
const material_model_mod = @import("material_model.zig");
const components = @import("../scene/components.zig");

const current_material_version: u32 = 1;

const MaterialFile = struct {
    version: u32 = current_material_version,
    name: []const u8,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    base_color_texture_handle: ?u32 = null,
    metallic_roughness_texture_handle: ?u32 = null,
    normal_texture_handle: ?u32 = null,
    occlusion_texture_handle: ?u32 = null,
    emissive_texture_handle: ?u32 = null,
    emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
    use_ibl: bool = true,
    ibl_intensity: f32 = 1.0,
    inheritance: ?material_model_mod.MaterialInheritanceInfo = null,
    graph: ?material_model_mod.MaterialGraph = null,
};

pub const MaterialResource = struct {
    name: []u8,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    base_color_texture: ?handles.TextureHandle = null,
    metallic_roughness_texture: ?handles.TextureHandle = null,
    normal_texture: ?handles.TextureHandle = null,
    occlusion_texture: ?handles.TextureHandle = null,
    emissive_texture: ?handles.TextureHandle = null,
    emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
    metallic_factor: f32 = 1.0,
    roughness_factor: f32 = 1.0,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
    use_ibl: bool = true, // Enable IBL by default
    ibl_intensity: f32 = 1.0, // IBL intensity multiplier
    inheritance: material_model_mod.MaterialInheritanceInfo = .{},
    graph: ?material_model_mod.MaterialGraph = null,

    pub fn deinit(self: *MaterialResource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.inheritance.parent_material_name_hint) |name| {
            allocator.free(@constCast(name));
        }
        if (self.graph) |*graph| {
            material_model_mod.deinitGraph(allocator, graph);
        }
        self.* = undefined;
    }
};

pub const MaterialResourceDesc = struct {
    name: []const u8,
    shading: components.ShadingModel = .pbr_metallic_roughness,
    base_color_factor: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
    base_color_texture: ?handles.TextureHandle = null,
    metallic_roughness_texture: ?handles.TextureHandle = null,
    normal_texture: ?handles.TextureHandle = null,
    occlusion_texture: ?handles.TextureHandle = null,
    emissive_texture: ?handles.TextureHandle = null,
    emissive_factor: [3]f32 = .{ 0.0, 0.0, 0.0 },
    metallic_factor: f32 = 0.0,
    roughness_factor: f32 = 0.5,
    alpha_cutoff: f32 = 0.5,
    double_sided: bool = false,
    use_ibl: bool = true,
    ibl_intensity: f32 = 1.0,
    inheritance: material_model_mod.MaterialInheritanceInfo = .{},
    graph: ?material_model_mod.MaterialGraph = null,
};

pub fn clone(allocator: std.mem.Allocator, desc: MaterialResourceDesc) !MaterialResource {
    const inherited_name = try cloneOptionalString(allocator, desc.inheritance.parent_material_name_hint);
    errdefer if (inherited_name) |name| allocator.free(@constCast(name));

    var cloned_graph = if (desc.graph) |graph| try material_model_mod.cloneGraphAlloc(allocator, graph) else null;
    errdefer if (cloned_graph) |*graph| material_model_mod.deinitGraph(allocator, graph);

    return .{
        .name = try allocator.dupe(u8, desc.name),
        .shading = desc.shading,
        .base_color_factor = desc.base_color_factor,
        .base_color_texture = desc.base_color_texture,
        .metallic_roughness_texture = desc.metallic_roughness_texture,
        .normal_texture = desc.normal_texture,
        .occlusion_texture = desc.occlusion_texture,
        .emissive_texture = desc.emissive_texture,
        .emissive_factor = desc.emissive_factor,
        .metallic_factor = desc.metallic_factor,
        .roughness_factor = desc.roughness_factor,
        .alpha_cutoff = desc.alpha_cutoff,
        .double_sided = desc.double_sided,
        .use_ibl = desc.use_ibl,
        .ibl_intensity = desc.ibl_intensity,
        .inheritance = .{
            .parent_material_handle = desc.inheritance.parent_material_handle,
            .parent_material_name_hint = inherited_name,
            .generation = desc.inheritance.generation,
        },
        .graph = cloned_graph,
    };
}

pub fn serializeAlloc(allocator: std.mem.Allocator, material: *const MaterialResource) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var writer = out.writer(allocator);
    var adapter_buffer: [4096]u8 = undefined;
    var adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(MaterialFile{
        .name = material.name,
        .shading = material.shading,
        .base_color_factor = material.base_color_factor,
        .base_color_texture_handle = optionalHandleToRaw(material.base_color_texture),
        .metallic_roughness_texture_handle = optionalHandleToRaw(material.metallic_roughness_texture),
        .normal_texture_handle = optionalHandleToRaw(material.normal_texture),
        .occlusion_texture_handle = optionalHandleToRaw(material.occlusion_texture),
        .emissive_texture_handle = optionalHandleToRaw(material.emissive_texture),
        .emissive_factor = material.emissive_factor,
        .metallic_factor = material.metallic_factor,
        .roughness_factor = material.roughness_factor,
        .alpha_cutoff = material.alpha_cutoff,
        .double_sided = material.double_sided,
        .use_ibl = material.use_ibl,
        .ibl_intensity = material.ibl_intensity,
        .inheritance = if (material_model_mod.hasUsefulInheritance(material.inheritance)) material.inheritance else null,
        .graph = if (material.graph) |graph| if (!graph.isEmpty()) graph else null else null,
    }, .{ .whitespace = .indent_2 }, &adapter.new_interface);
    try adapter.new_interface.flush();
    try writer.writeByte('\n');
    return try out.toOwnedSlice(allocator);
}

pub fn deserializeFromSlice(allocator: std.mem.Allocator, source: []const u8) !MaterialResource {
    var parsed = try std.json.parseFromSlice(MaterialFile, allocator, source, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (parsed.value.version != current_material_version) {
        return error.UnsupportedMaterialVersion;
    }

    return .{
        .name = try allocator.dupe(u8, parsed.value.name),
        .shading = parsed.value.shading,
        .base_color_factor = parsed.value.base_color_factor,
        .base_color_texture = rawToHandle(parsed.value.base_color_texture_handle),
        .metallic_roughness_texture = rawToHandle(parsed.value.metallic_roughness_texture_handle),
        .normal_texture = rawToHandle(parsed.value.normal_texture_handle),
        .occlusion_texture = rawToHandle(parsed.value.occlusion_texture_handle),
        .emissive_texture = rawToHandle(parsed.value.emissive_texture_handle),
        .emissive_factor = parsed.value.emissive_factor,
        .metallic_factor = parsed.value.metallic_factor,
        .roughness_factor = parsed.value.roughness_factor,
        .alpha_cutoff = parsed.value.alpha_cutoff,
        .double_sided = parsed.value.double_sided,
        .use_ibl = parsed.value.use_ibl,
        .ibl_intensity = parsed.value.ibl_intensity,
        .inheritance = .{
            .parent_material_handle = if (parsed.value.inheritance) |inheritance| inheritance.parent_material_handle else null,
            .parent_material_name_hint = if (parsed.value.inheritance) |inheritance| try cloneOptionalString(allocator, inheritance.parent_material_name_hint) else null,
            .generation = if (parsed.value.inheritance) |inheritance| inheritance.generation else 0,
        },
        .graph = if (parsed.value.graph) |graph| try material_model_mod.cloneGraphAlloc(allocator, graph) else null,
    };
}

pub fn saveToPath(allocator: std.mem.Allocator, material: *const MaterialResource, path: []const u8) !void {
    const encoded = try serializeAlloc(allocator, material);
    defer allocator.free(encoded);

    if (std.fs.path.dirname(path)) |directory| {
        try std.fs.cwd().makePath(directory);
    }
    try std.fs.cwd().writeFile(.{
        .sub_path = path,
        .data = encoded,
    });
}

pub fn loadFromPath(allocator: std.mem.Allocator, path: []const u8) !MaterialResource {
    const source = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
    defer allocator.free(source);
    return try deserializeFromSlice(allocator, source);
}

fn optionalHandleToRaw(handle: ?handles.TextureHandle) ?u32 {
    return if (handle) |resolved| @intFromEnum(resolved) else null;
}

fn rawToHandle(raw: ?u32) ?handles.TextureHandle {
    return if (raw) |value|
        if (value == 0) null else @enumFromInt(value)
    else
        null;
}

fn cloneOptionalString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    return if (value) |resolved| try allocator.dupe(u8, resolved) else null;
}

test "material resource save-load-resave is byte stable" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const cwd = std.fs.cwd();
    var original = try cwd.openDir(".", .{});
    defer original.close();
    try temp_dir.dir.setAsCwd();
    defer original.setAsCwd() catch {};

    var material = try clone(std.testing.allocator, .{
        .name = "Test Material",
        .shading = .lambert,
        .base_color_factor = .{ 0.18, 0.34, 0.76, 0.92 },
        .base_color_texture = @enumFromInt(7),
        .metallic_roughness_texture = @enumFromInt(9),
        .normal_texture = @enumFromInt(11),
        .occlusion_texture = @enumFromInt(13),
        .emissive_texture = @enumFromInt(15),
        .emissive_factor = .{ 0.1, 0.2, 0.3 },
        .metallic_factor = 0.25,
        .roughness_factor = 0.7,
        .alpha_cutoff = 0.42,
        .double_sided = true,
        .use_ibl = false,
        .ibl_intensity = 1.75,
        .inheritance = .{
            .parent_material_handle = @enumFromInt(99),
            .parent_material_name_hint = "Master Material",
            .generation = 2,
        },
        .graph = blk: {
            var graph_nodes = [_]material_model_mod.MaterialGraphNode{.{
                .id = 1,
                .kind = .input_parameter,
                .output_type = .vec4,
                .channel = .base_color,
                .value = .{ .kind = .vec4, .vec4 = .{ 0.18, 0.34, 0.76, 0.92 } },
            }};
            var graph_outputs = [_]material_model_mod.MaterialGraphOutput{.{ .channel = .base_color, .source_node_id = 1 }};
            break :blk material_model_mod.MaterialGraph{
                .nodes = graph_nodes[0..],
                .outputs = graph_outputs[0..],
            };
        },
    });
    defer material.deinit(std.testing.allocator);

    try saveToPath(std.testing.allocator, &material, "assets/materials/test.guava_material");
    var loaded = try loadFromPath(std.testing.allocator, "assets/materials/test.guava_material");
    defer loaded.deinit(std.testing.allocator);
    try saveToPath(std.testing.allocator, &loaded, "assets/materials/test_resaved.guava_material");

    const first = try std.fs.cwd().readFileAlloc(std.testing.allocator, "assets/materials/test.guava_material", 1024 * 1024);
    defer std.testing.allocator.free(first);
    const second = try std.fs.cwd().readFileAlloc(std.testing.allocator, "assets/materials/test_resaved.guava_material", 1024 * 1024);
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings(first, second);
}
