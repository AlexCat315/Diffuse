const std = @import("std");
const handles = @import("handles.zig");
const ibl_precompute = @import("../render/ibl_precompute.zig");
const library_mod = @import("library.zig");
const registry_mod = @import("registry.zig");
const rhi_types = @import("../rhi/types.zig");

const synthetic_importer_name = "ibl-derived-v1";
const runtime_source_hash = "ibl-runtime-source-v1";
const runtime_import_settings_hash = "ibl-runtime-settings-v1";
const default_brdf_lut_size: u32 = 256;

pub const EnvironmentMapResource = struct {
    name: []u8,

    // Original HDR cubemap/equirectangular map
    source_width: u32,
    source_height: u32,
    source_pixels: []f32,

    // Runtime texture handles for the source environment and its derived IBL maps.
    environment_map_handle: ?handles.TextureHandle = null,
    irradiance_map_handle: ?handles.TextureHandle = null,
    prefiltered_map_handle: ?handles.TextureHandle = null,
    brdf_lut_handle: ?handles.TextureHandle = null,

    // Generation parameters
    irradiance_size: u32 = 64,
    prefiltered_size: u32 = 256,
    prefiltered_mip_levels: u32 = 5,
    brdf_lut_size: u32 = default_brdf_lut_size,

    pub fn deinit(self: *EnvironmentMapResource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.source_pixels);
        self.* = undefined;
    }

    pub fn generateIBLData(
        self: *EnvironmentMapResource,
        allocator: std.mem.Allocator,
        library: *library_mod.ResourceLibrary,
    ) !void {
        const base_asset_id = try runtimeAssetIdAlloc(allocator, self.name);
        defer allocator.free(base_asset_id);

        const source_path = try std.fmt.allocPrint(allocator, "memory://{s}", .{base_asset_id});
        defer allocator.free(source_path);

        self.environment_map_handle = try ensureSyntheticTexture(
            allocator,
            library,
            base_asset_id,
            source_path,
            self.name,
            runtime_source_hash,
            runtime_import_settings_hash,
            &.{},
            self.source_width,
            self.source_height,
            .rgba32_float,
            std.mem.sliceAsBytes(self.source_pixels),
        );

        const irradiance_pixels = try ibl_precompute.generateIrradianceMap(
            allocator,
            self.source_width,
            self.source_height,
            self.source_pixels,
            self.irradiance_size,
        );
        defer allocator.free(irradiance_pixels);

        const irradiance_bytes = try expandRgb32fToRgbaBytes(allocator, irradiance_pixels);
        defer allocator.free(irradiance_bytes);

        const dependencies = [_][]const u8{base_asset_id};

        self.irradiance_map_handle = try ensureDerivedTexture(
            allocator,
            library,
            base_asset_id,
            source_path,
            "ibl/irradiance",
            "IBL Irradiance",
            runtime_source_hash,
            runtime_import_settings_hash,
            dependencies[0..],
            self.irradiance_size,
            self.irradiance_size,
            .rgba32_float,
            irradiance_bytes,
        );

        const prefiltered_pixels = try ibl_precompute.generatePrefilteredMap(
            allocator,
            self.source_width,
            self.source_height,
            self.source_pixels,
            self.prefiltered_mip_levels,
        );
        defer allocator.free(prefiltered_pixels);

        const prefiltered_bytes = try expandRgb32fToRgbaBytes(allocator, prefiltered_pixels);
        defer allocator.free(prefiltered_bytes);

        self.prefiltered_map_handle = try ensureDerivedTexture(
            allocator,
            library,
            base_asset_id,
            source_path,
            "ibl/prefiltered",
            "IBL Prefiltered",
            runtime_source_hash,
            runtime_import_settings_hash,
            dependencies[0..],
            self.prefiltered_size,
            self.prefiltered_size,
            .rgba32_float,
            prefiltered_bytes,
        );

        self.brdf_lut_handle = try ensureBRDFLUTTexture(allocator, library, self.brdf_lut_size);
    }
};

pub const EnvironmentMapResourceDesc = struct {
    name: []const u8,
    source_width: u32,
    source_height: u32,
    source_pixels: []const f32,
    irradiance_size: u32 = 64,
    prefiltered_size: u32 = 256,
    prefiltered_mip_levels: u32 = 5,
    brdf_lut_size: u32 = default_brdf_lut_size,
};

pub fn clone(allocator: std.mem.Allocator, desc: EnvironmentMapResourceDesc) !EnvironmentMapResource {
    return .{
        .name = try allocator.dupe(u8, desc.name),
        .source_width = desc.source_width,
        .source_height = desc.source_height,
        .source_pixels = try allocator.dupe(f32, desc.source_pixels),
        .irradiance_size = desc.irradiance_size,
        .prefiltered_size = desc.prefiltered_size,
        .prefiltered_mip_levels = desc.prefiltered_mip_levels,
        .brdf_lut_size = desc.brdf_lut_size,
    };
}

pub fn createFromHDR(
    allocator: std.mem.Allocator,
    name: []const u8,
    width: u32,
    height: u32,
    hdr_pixels: []const f32,
) !EnvironmentMapResource {
    return .{
        .name = try allocator.dupe(u8, name),
        .source_width = width,
        .source_height = height,
        .source_pixels = try allocator.dupe(f32, hdr_pixels),
        .irradiance_size = 64,
        .prefiltered_size = @min(width, height),
        .prefiltered_mip_levels = 5,
        .brdf_lut_size = default_brdf_lut_size,
    };
}

pub const IBLCache = struct {
    allocator: std.mem.Allocator,
    brdf_lut_handle: ?handles.TextureHandle = null,
    brdf_lut_size: u32 = 512,

    pub fn init(allocator: std.mem.Allocator) IBLCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *IBLCache) void {
        // ResourceLibrary owns the actual texture storage; the cache only tracks the handle.
        self.brdf_lut_handle = null;
    }

    pub fn ensureBRDFLUT(self: *IBLCache, library: *library_mod.ResourceLibrary) !handles.TextureHandle {
        if (self.brdf_lut_handle) |handle| {
            return handle;
        }

        self.brdf_lut_handle = try ensureBRDFLUTTexture(self.allocator, library, self.brdf_lut_size);
        return self.brdf_lut_handle.?;
    }
};

pub fn ensureBRDFLUTTexture(
    allocator: std.mem.Allocator,
    library: *library_mod.ResourceLibrary,
    size: u32,
) !handles.TextureHandle {
    const asset_id = try std.fmt.allocPrint(allocator, "builtin://ibl/brdf_lut/{d}", .{size});
    defer allocator.free(asset_id);

    if (library.textureHandleByAssetId(asset_id)) |handle| {
        return handle;
    }

    const lut = try ibl_precompute.generateBRDFLUT(allocator, size);
    defer allocator.free(lut);

    const lut_bytes = try expandRg32fToRgbaBytes(allocator, lut);
    defer allocator.free(lut_bytes);

    return ensureSyntheticTexture(
        allocator,
        library,
        asset_id,
        "internal://ibl/brdf_lut",
        "IBL BRDF LUT",
        "ibl-brdf-lut",
        synthetic_importer_name,
        &.{},
        size,
        size,
        .rgba32_float,
        lut_bytes,
    );
}

pub fn ensureDerivedTexture(
    allocator: std.mem.Allocator,
    library: *library_mod.ResourceLibrary,
    base_asset_id: []const u8,
    base_source_path: []const u8,
    suffix: []const u8,
    display_name: []const u8,
    source_hash: []const u8,
    import_settings_hash: []const u8,
    dependencies: []const []const u8,
    width: u32,
    height: u32,
    format: rhi_types.TextureFormat,
    pixels: []const u8,
) !handles.TextureHandle {
    const derived_asset_id = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ base_asset_id, suffix });
    defer allocator.free(derived_asset_id);

    const source_path = try std.fmt.allocPrint(allocator, "{s}#{s}", .{ base_source_path, suffix });
    defer allocator.free(source_path);

    return ensureSyntheticTexture(
        allocator,
        library,
        derived_asset_id,
        source_path,
        display_name,
        source_hash,
        import_settings_hash,
        dependencies,
        width,
        height,
        format,
        pixels,
    );
}

pub fn ensureSyntheticTexture(
    allocator: std.mem.Allocator,
    library: *library_mod.ResourceLibrary,
    asset_id: []const u8,
    source_path: []const u8,
    display_name: []const u8,
    source_hash: []const u8,
    import_settings_hash: []const u8,
    dependencies: []const []const u8,
    width: u32,
    height: u32,
    format: rhi_types.TextureFormat,
    pixels: []const u8,
) !handles.TextureHandle {
    if (library.textureHandleByAssetId(asset_id)) |handle| {
        return handle;
    }

    const handle = try library.createTexture(.{
        .name = display_name,
        .width = width,
        .height = height,
        .format = format,
        .pixels = pixels,
    });
    _ = try library.bindTextureAssetRecord(
        handle,
        try makeSyntheticTextureRecord(
            allocator,
            asset_id,
            source_path,
            display_name,
            source_hash,
            import_settings_hash,
            dependencies,
        ),
    );
    return handle;
}

pub fn makeSyntheticTextureRecord(
    allocator: std.mem.Allocator,
    id: []const u8,
    source_path: []const u8,
    display_name: []const u8,
    source_hash: []const u8,
    import_settings_hash: []const u8,
    dependencies: []const []const u8,
) !registry_mod.AssetRecord {
    const dependency_ids = try allocator.alloc([]u8, dependencies.len);
    var dependency_count: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < dependency_count) : (index += 1) {
            allocator.free(dependency_ids[index]);
        }
        allocator.free(dependency_ids);
    }

    for (dependencies, 0..) |dependency, index| {
        dependency_ids[index] = try allocator.dupe(u8, dependency);
        dependency_count = index + 1;
    }

    return .{
        .id = try allocator.dupe(u8, id),
        .type = .texture,
        .source_path = try allocator.dupe(u8, source_path),
        .source_hash = try allocator.dupe(u8, source_hash),
        .import_settings_hash = try allocator.dupe(u8, import_settings_hash),
        .import_version = registry_mod.AssetType.texture.importVersion() + 2,
        .dependency_ids = dependency_ids,
        .outputs = try allocator.alloc(registry_mod.AssetOutput, 0),
        .metadata = .{
            .display_name = try allocator.dupe(u8, display_name),
            .importer = try allocator.dupe(u8, synthetic_importer_name),
            .source_extension = try allocator.dupe(u8, ".hdr"),
        },
    };
}

pub fn expandRgb32fToRgbaBytes(allocator: std.mem.Allocator, rgb: []const f32) ![]u8 {
    if (rgb.len % 3 != 0) {
        return error.InvalidIBLPixelPayload;
    }

    const pixel_count = rgb.len / 3;
    var rgba = try allocator.alloc(f32, pixel_count * 4);
    errdefer allocator.free(rgba);

    var index: usize = 0;
    while (index < pixel_count) : (index += 1) {
        const src = index * 3;
        const dst = index * 4;
        rgba[dst] = rgb[src];
        rgba[dst + 1] = rgb[src + 1];
        rgba[dst + 2] = rgb[src + 2];
        rgba[dst + 3] = 1.0;
    }

    const bytes = try allocator.alloc(u8, rgba.len * @sizeOf(f32));
    @memcpy(bytes, std.mem.sliceAsBytes(rgba));
    allocator.free(rgba);
    return bytes;
}

pub fn expandRg32fToRgbaBytes(allocator: std.mem.Allocator, rg: []const f32) ![]u8 {
    if (rg.len % 2 != 0) {
        return error.InvalidBRDFPayload;
    }

    const pixel_count = rg.len / 2;
    var rgba = try allocator.alloc(f32, pixel_count * 4);
    errdefer allocator.free(rgba);

    var index: usize = 0;
    while (index < pixel_count) : (index += 1) {
        const src = index * 2;
        const dst = index * 4;
        rgba[dst] = rg[src];
        rgba[dst + 1] = rg[src + 1];
        rgba[dst + 2] = 0.0;
        rgba[dst + 3] = 1.0;
    }

    const bytes = try allocator.alloc(u8, rgba.len * @sizeOf(f32));
    @memcpy(bytes, std.mem.sliceAsBytes(rgba));
    allocator.free(rgba);
    return bytes;
}

fn runtimeAssetIdAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, name, "://") != null) {
        return try allocator.dupe(u8, name);
    }

    var sanitized = std.ArrayList(u8).empty;
    defer sanitized.deinit(allocator);

    for (name) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try sanitized.append(allocator, std.ascii.toLower(char));
        } else if (char == ' ' or char == '-' or char == '_') {
            if (sanitized.items.len == 0 or sanitized.items[sanitized.items.len - 1] == '-') {
                continue;
            }
            try sanitized.append(allocator, '-');
        }
    }

    if (sanitized.items.len == 0) {
        try sanitized.appendSlice(allocator, "environment");
    }

    return std.fmt.allocPrint(allocator, "runtime://environment/{s}", .{sanitized.items});
}

test "ensureBRDFLUTTexture reuses a stable asset handle" {
    var library = library_mod.ResourceLibrary.init(std.testing.allocator, null);
    defer library.deinit();

    const first = try ensureBRDFLUTTexture(std.testing.allocator, &library, 64);
    const second = try ensureBRDFLUTTexture(std.testing.allocator, &library, 64);

    try std.testing.expectEqual(first, second);
    try std.testing.expect(library.textureAssetId(first) != null);
}

test "generateIBLData creates source and derived texture handles" {
    var library = library_mod.ResourceLibrary.init(std.testing.allocator, null);
    defer library.deinit();

    const pixels = [_]f32{
        1.0, 0.5, 0.25, 1.0,
        0.2, 0.3, 0.4,  1.0,
        0.8, 0.7, 0.6,  1.0,
        0.1, 0.2, 0.9,  1.0,
    };

    var resource = try createFromHDR(std.testing.allocator, "Test Sky", 2, 2, pixels[0..]);
    defer resource.deinit(std.testing.allocator);

    try resource.generateIBLData(std.testing.allocator, &library);

    try std.testing.expect(resource.environment_map_handle != null);
    try std.testing.expect(resource.irradiance_map_handle != null);
    try std.testing.expect(resource.prefiltered_map_handle != null);
    try std.testing.expect(resource.brdf_lut_handle != null);
}
