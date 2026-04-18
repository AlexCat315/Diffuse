const std = @import("std");
const io_globals = @import("io_globals");
const environment_map_import = @import("environment_map_import.zig");
const image_decoder = @import("image_decoder.zig");
const registry_mod = @import("registry.zig");
const svg_decoder = @import("svg_decoder.zig");
const rhi_types = @import("guava_rhi").types;
const library_mod = @import("library.zig");

pub const current_texture_cache_version: u32 = registry_mod.AssetType.texture.importVersion();

const CookedTexture = struct {
    version: u32 = current_texture_cache_version,
    asset_id: []const u8,
    source_path: []const u8,
    source_hash: []const u8,
    import_settings_hash: []const u8,
    import_version: u32 = current_texture_cache_version,
    width: u32,
    height: u32,
    format: rhi_types.TextureFormat = .rgba8_unorm,
    pixels_hex: []const u8 = "",
    pixels_bin_path: []const u8 = "",
};

pub fn ensureCookedTexture(allocator: std.mem.Allocator, registry: *const registry_mod.AssetRegistry, asset_id: []const u8) ![]u8 {
    const record = registry.recordById(asset_id) orelse return error.AssetNotFound;
    if (record.type != .texture) {
        return error.AssetTypeMismatch;
    }
    if (record.outputs.len == 0) {
        return error.MissingCookedOutput;
    }

    const cooked_path = record.outputs[0].path;
    const should_recook = recook: {
        std.Io.Dir.cwd().access(io_globals.global_io, cooked_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :recook true,
            else => return err,
        };
        break :recook !(try cookedTextureIsCurrent(allocator, record, cooked_path));
    };
    if (should_recook) {
        try cookTextureRecord(allocator, record, cooked_path);
    }
    return cooked_path;
}

pub fn validateCookedTextureAsset(
    allocator: std.mem.Allocator,
    registry: *const registry_mod.AssetRegistry,
    asset_id: []const u8,
) !void {
    const record = registry.recordById(asset_id) orelse return error.AssetNotFound;
    if (record.type != .texture) {
        return error.AssetTypeMismatch;
    }

    const cooked_path = try ensureCookedTexture(allocator, registry, asset_id);
    if (!(try cookedTextureIsCurrent(allocator, record, cooked_path))) {
        return error.TextureCacheOutOfDate;
    }

    const cooked = try readCookedTextureAlloc(allocator, cooked_path);
    defer freeCookedTexture(allocator, &cooked);

    const pixels = try loadCookedPixelsAlloc(allocator, cooked);
    defer allocator.free(pixels);

    if (pixels.len == 0 or cooked.width == 0 or cooked.height == 0) {
        return error.InvalidCookedTexturePayload;
    }
}

pub fn loadTextureAsset(
    allocator: std.mem.Allocator,
    library: *library_mod.ResourceLibrary,
    registry: *const registry_mod.AssetRegistry,
    asset_id: []const u8,
) !@import("handles.zig").TextureHandle {
    if (library.textureHandleByAssetId(asset_id)) |handle| {
        return handle;
    }

    const cooked_path = try ensureCookedTexture(allocator, registry, asset_id);
    const encoded = try std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, cooked_path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(CookedTexture, allocator, encoded, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const cooked = parsed.value;
    if (cooked.version != current_texture_cache_version) {
        return error.UnsupportedTextureCacheVersion;
    }
    if (!std.mem.eql(u8, cooked.asset_id, asset_id)) {
        return error.AssetIdMismatch;
    }

    const pixels = try loadCookedPixelsAlloc(allocator, cooked);
    defer allocator.free(pixels);

    const handle = try library.createTexture(.{
        .name = cooked.source_path,
        .width = cooked.width,
        .height = cooked.height,
        .format = cooked.format,
        .pixels = pixels,
    });
    const bound_record = if (try registry.cloneRecordById(asset_id, allocator)) |record|
        record
    else
        return error.AssetNotFound;
    _ = try library.bindTextureAssetRecord(handle, bound_record);
    return handle;
}

fn cookTextureRecord(allocator: std.mem.Allocator, record: *const registry_mod.AssetRecord, cooked_path: []const u8) !void {
    var width: u32 = 0;
    var height: u32 = 0;
    var raw_pixels: []u8 = undefined;
    var format: rhi_types.TextureFormat = .rgba8_unorm;
    defer allocator.free(raw_pixels);

    if (std.mem.endsWith(u8, record.source_path, ".svg")) {
        var rasterized = try svg_decoder.rasterizeBgra8(allocator, record.source_path, .{});
        defer rasterized.deinit();
        swizzleBgraToRgba(rasterized.pixels);
        width = rasterized.width;
        height = rasterized.height;
        raw_pixels = try allocator.dupe(u8, rasterized.pixels);
    } else if (std.mem.endsWith(u8, record.source_path, ".hdr")) {
        const encoded = try std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, record.source_path, allocator, .limited(128 * 1024 * 1024));
        defer allocator.free(encoded);

        var decoded = try image_decoder.decodeRgba32f(allocator, encoded);
        defer decoded.deinit();
        width = decoded.width;
        height = decoded.height;
        format = .rgba32_float;
        raw_pixels = try allocator.dupe(u8, std.mem.sliceAsBytes(decoded.pixels));

        const cooked_ibl_path = try environment_map_import.cookedIBLPathAlloc(allocator, cooked_path);
        defer allocator.free(cooked_ibl_path);

        const cooked_ibl = try environment_map_import.generateIBLDataForHDR(
            allocator,
            record.id,
            record.source_path,
            record.source_hash,
            record.import_settings_hash,
            record.resolvedImportVersion(),
            decoded.width,
            decoded.height,
            decoded.pixels,
        );
        defer allocator.free(cooked_ibl);

        if (std.fs.path.dirname(cooked_ibl_path)) |directory| {
            try std.Io.Dir.cwd().createDirPath(io_globals.global_io, directory);
        }
        try std.Io.Dir.cwd().writeFile(io_globals.global_io, .{
            .sub_path = cooked_ibl_path,
            .data = cooked_ibl,
        });
    } else {
        const encoded = try std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, record.source_path, allocator, .limited(128 * 1024 * 1024));
        defer allocator.free(encoded);

        var decoded = try image_decoder.decodeRgba8(allocator, encoded);
        defer decoded.deinit();
        width = decoded.width;
        height = decoded.height;
        raw_pixels = try allocator.dupe(u8, decoded.pixels);
    }

    // Write raw pixel data to .bin sidecar file
    const bin_path = try std.fmt.allocPrint(allocator, "{s}.bin", .{cooked_path});
    defer allocator.free(bin_path);

    if (std.fs.path.dirname(cooked_path)) |directory| {
        try std.Io.Dir.cwd().createDirPath(io_globals.global_io, directory);
    }
    try std.Io.Dir.cwd().writeFile(io_globals.global_io, .{
        .sub_path = bin_path,
        .data = raw_pixels,
    });

    const cooked = CookedTexture{
        .asset_id = record.id,
        .source_path = record.source_path,
        .source_hash = record.source_hash,
        .import_settings_hash = record.import_settings_hash,
        .import_version = record.resolvedImportVersion(),
        .width = width,
        .height = height,
        .format = format,
        .pixels_bin_path = bin_path,
    };

    const output = try stringifyAlloc(allocator, cooked);
    defer allocator.free(output);

    try std.Io.Dir.cwd().writeFile(io_globals.global_io, .{
        .sub_path = cooked_path,
        .data = output,
    });
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
}

fn readCookedTextureAlloc(allocator: std.mem.Allocator, cooked_path: []const u8) !CookedTexture {
    const encoded = try std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, cooked_path, allocator, .limited(512 * 1024 * 1024));
    defer allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(CookedTexture, allocator, encoded, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .version = parsed.value.version,
        .asset_id = try allocator.dupe(u8, parsed.value.asset_id),
        .source_path = try allocator.dupe(u8, parsed.value.source_path),
        .source_hash = try allocator.dupe(u8, parsed.value.source_hash),
        .import_settings_hash = try allocator.dupe(u8, parsed.value.import_settings_hash),
        .import_version = parsed.value.import_version,
        .width = parsed.value.width,
        .height = parsed.value.height,
        .format = parsed.value.format,
        .pixels_hex = try allocator.dupe(u8, parsed.value.pixels_hex),
        .pixels_bin_path = try allocator.dupe(u8, parsed.value.pixels_bin_path),
    };
}

fn freeCookedTexture(allocator: std.mem.Allocator, cooked: *const CookedTexture) void {
    allocator.free(cooked.asset_id);
    allocator.free(cooked.source_path);
    allocator.free(cooked.source_hash);
    allocator.free(cooked.import_settings_hash);
    if (cooked.pixels_hex.len > 0) allocator.free(cooked.pixels_hex);
    if (cooked.pixels_bin_path.len > 0) allocator.free(cooked.pixels_bin_path);
}

fn cookedTextureIsCurrent(
    allocator: std.mem.Allocator,
    record: *const registry_mod.AssetRecord,
    cooked_path: []const u8,
) !bool {
    const cooked = readCookedTextureAlloc(allocator, cooked_path) catch return false;
    defer freeCookedTexture(allocator, &cooked);

    return cooked.version == current_texture_cache_version and
        std.mem.eql(u8, cooked.asset_id, record.id) and
        std.mem.eql(u8, cooked.source_path, record.source_path) and
        std.mem.eql(u8, cooked.source_hash, record.source_hash) and
        std.mem.eql(u8, cooked.import_settings_hash, record.import_settings_hash) and
        cooked.import_version == record.resolvedImportVersion();
}

fn encodeHexAlloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        const high = byte >> 4;
        const low = byte & 0x0F;
        encoded[index * 2] = nibbleToHex(high);
        encoded[index * 2 + 1] = nibbleToHex(low);
    }
    return encoded;
}

fn decodeHexAlloc(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len % 2 != 0) {
        return error.InvalidHexEncoding;
    }

    const decoded = try allocator.alloc(u8, encoded.len / 2);
    errdefer allocator.free(decoded);
    _ = try std.fmt.hexToBytes(decoded, encoded);
    return decoded;
}

/// Load pixel data from either a binary sidecar file or hex-encoded JSON field.
fn loadCookedPixelsAlloc(allocator: std.mem.Allocator, cooked: CookedTexture) ![]u8 {
    if (cooked.pixels_bin_path.len > 0) {
        return std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, cooked.pixels_bin_path, allocator, .limited(512 * 1024 * 1024));
    }
    if (cooked.pixels_hex.len > 0) {
        return decodeHexAlloc(allocator, cooked.pixels_hex);
    }
    return error.MissingPixelData;
}

fn nibbleToHex(value: u8) u8 {
    return if (value < 10) '0' + value else 'a' + (value - 10);
}

fn swizzleRgbaToBgra(bytes: []u8) void {
    var index: usize = 0;
    while (index + 3 < bytes.len) : (index += 4) {
        const r = bytes[index];
        bytes[index] = bytes[index + 2];
        bytes[index + 2] = r;
    }
}

// BGRA→RGBA is the same byte swap (R↔B), re-use the above implementation.
const swizzleBgraToRgba = swizzleRgbaToBgra;

test "texture cache is created deterministically" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.makePath("assets/textures");

    const cwd = std.Io.Dir.cwd();
    const source_png = try cwd.readFileAlloc(std.testing.allocator, "assets/models/guava_showcase/checker.png", 128 * 1024);
    defer std.testing.allocator.free(source_png);

    try temp_dir.dir.writeFile(.{
        .sub_path = "assets/textures/example.png",
        .data = source_png,
    });

    var original = try cwd.openDir(io_globals.global_io, ".", .{});
    defer original.close(io_globals.global_io);
    try temp_dir.dir.setAsCwd();
    defer original.setAsCwd() catch {};

    var registry = registry_mod.AssetRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.refreshProject("assets");

    const record = registry.recordByPath("assets/textures/example.png") orelse return error.AssetNotFound;
    const first_path = try ensureCookedTexture(std.testing.allocator, &registry, record.id);
    const first_bytes = try std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, first_path, std.testing.allocator, .limited(512 * 1024));
    defer std.testing.allocator.free(first_bytes);

    try std.Io.Dir.cwd().deleteFile(io_globals.global_io, first_path);
    const second_path = try ensureCookedTexture(std.testing.allocator, &registry, record.id);
    const second_bytes = try std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, second_path, std.testing.allocator, .limited(512 * 1024));
    defer std.testing.allocator.free(second_bytes);

    try std.testing.expectEqualStrings(first_path, second_path);
    try std.testing.expectEqualStrings(first_bytes, second_bytes);
    try validateCookedTextureAsset(std.testing.allocator, &registry, record.id);
}
