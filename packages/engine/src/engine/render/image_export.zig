const std = @import("std");
const vec3 = @import("../math/vec3.zig");
const render_types = @import("types.zig");

pub fn sanitizeHdrValue(value: f32) f32 {
    if (!std.math.isFinite(value)) return 0.0;
    return value;
}

fn luminance(rgb: [3]f32) f32 {
    return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722;
}

fn writeF16Le(out: []u8, offset: usize, value: f32) void {
    const clamped = std.math.clamp(value, -65504.0, 65504.0);
    const bits: u16 = @bitCast(@as(f16, @floatCast(clamped)));
    out[offset + 0] = @as(u8, @truncate(bits));
    out[offset + 1] = @as(u8, @truncate(bits >> 8));
}

pub fn readF16Le(bytes: []const u8, offset: usize) f32 {
    const bits: u16 = @as(u16, bytes[offset + 0]) | (@as(u16, bytes[offset + 1]) << 8);
    return @as(f32, @floatCast(@as(f16, @bitCast(bits))));
}

fn writeU32Le(out: []u8, offset: usize, value: u32) void {
    out[offset + 0] = @as(u8, @truncate(value));
    out[offset + 1] = @as(u8, @truncate(value >> 8));
    out[offset + 2] = @as(u8, @truncate(value >> 16));
    out[offset + 3] = @as(u8, @truncate(value >> 24));
}

fn writeI32Le(out: []u8, offset: usize, value: i32) void {
    writeU32Le(out, offset, @bitCast(value));
}

fn writeU64Le(out: []u8, offset: usize, value: u64) void {
    out[offset + 0] = @as(u8, @truncate(value));
    out[offset + 1] = @as(u8, @truncate(value >> 8));
    out[offset + 2] = @as(u8, @truncate(value >> 16));
    out[offset + 3] = @as(u8, @truncate(value >> 24));
    out[offset + 4] = @as(u8, @truncate(value >> 32));
    out[offset + 5] = @as(u8, @truncate(value >> 40));
    out[offset + 6] = @as(u8, @truncate(value >> 48));
    out[offset + 7] = @as(u8, @truncate(value >> 56));
}

fn writeF32Le(out: []u8, offset: usize, value: f32) void {
    writeU32Le(out, offset, @bitCast(value));
}

fn appendU32Le(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var buf: [4]u8 = undefined;
    writeU32Le(&buf, 0, value);
    try list.appendSlice(allocator, &buf);
}

fn appendI32Le(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: i32) !void {
    var buf: [4]u8 = undefined;
    writeI32Le(&buf, 0, value);
    try list.appendSlice(allocator, &buf);
}

fn appendU64Le(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var buf: [8]u8 = undefined;
    writeU64Le(&buf, 0, value);
    try list.appendSlice(allocator, &buf);
}

fn appendF32Le(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f32) !void {
    var buf: [4]u8 = undefined;
    writeF32Le(&buf, 0, value);
    try list.appendSlice(allocator, &buf);
}

fn appendCString(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try list.appendSlice(allocator, value);
    try list.append(allocator, 0);
}

fn appendExrAttribute(
    list: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    name: []const u8,
    attr_type: []const u8,
    value: []const u8,
) !void {
    try appendCString(list, allocator, name);
    try appendCString(list, allocator, attr_type);
    try appendU32Le(list, allocator, @intCast(value.len));
    try list.appendSlice(allocator, value);
}

pub fn encodeExrRgb32fAlloc(
    allocator: std.mem.Allocator,
    rgba: []const f32,
    width: u32,
    height: u32,
) ![]u8 {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const pixel_count = @as(usize, width) * @as(usize, height);
    if (rgba.len < pixel_count * 4) return error.InvalidHdrData;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    try appendU32Le(&output, allocator, 20000630);
    try appendU32Le(&output, allocator, 2);

    var channel_list = std.ArrayList(u8).empty;
    defer channel_list.deinit(allocator);
    for ([_][]const u8{ "B", "G", "R" }) |channel_name| {
        try appendCString(&channel_list, allocator, channel_name);
        try appendI32Le(&channel_list, allocator, 2);
        try channel_list.append(allocator, 0);
        try channel_list.appendNTimes(allocator, 0, 3);
        try appendI32Le(&channel_list, allocator, 1);
        try appendI32Le(&channel_list, allocator, 1);
    }
    try channel_list.append(allocator, 0);
    try appendExrAttribute(&output, allocator, "channels", "chlist", channel_list.items);
    try appendExrAttribute(&output, allocator, "compression", "compression", &[_]u8{0});

    var box2i: [16]u8 = undefined;
    writeI32Le(&box2i, 0, 0);
    writeI32Le(&box2i, 4, 0);
    writeI32Le(&box2i, 8, @intCast(width - 1));
    writeI32Le(&box2i, 12, @intCast(height - 1));
    try appendExrAttribute(&output, allocator, "dataWindow", "box2i", &box2i);
    try appendExrAttribute(&output, allocator, "displayWindow", "box2i", &box2i);
    try appendExrAttribute(&output, allocator, "lineOrder", "lineOrder", &[_]u8{0});

    var pixel_aspect_ratio: [4]u8 = undefined;
    writeF32Le(&pixel_aspect_ratio, 0, 1.0);
    try appendExrAttribute(&output, allocator, "pixelAspectRatio", "float", &pixel_aspect_ratio);

    var screen_window_center: [8]u8 = undefined;
    writeF32Le(&screen_window_center, 0, 0.0);
    writeF32Le(&screen_window_center, 4, 0.0);
    try appendExrAttribute(&output, allocator, "screenWindowCenter", "v2f", &screen_window_center);

    var screen_window_width: [4]u8 = undefined;
    writeF32Le(&screen_window_width, 0, 1.0);
    try appendExrAttribute(&output, allocator, "screenWindowWidth", "float", &screen_window_width);
    try output.append(allocator, 0);

    const header_size = output.items.len;
    const scanline_data_size: u32 = width * 3 * @sizeOf(f32);
    const offset_table_size = @as(usize, height) * @sizeOf(u64);
    var next_chunk_offset: u64 = @intCast(header_size + offset_table_size);
    for (0..height) |_| {
        try appendU64Le(&output, allocator, next_chunk_offset);
        next_chunk_offset += 8 + scanline_data_size;
    }

    for (0..height) |row| {
        try appendI32Le(&output, allocator, @intCast(row));
        try appendU32Le(&output, allocator, scanline_data_size);
        for ([_]usize{ 2, 1, 0 }) |channel_index| {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const pixel_index = (@as(usize, @intCast(row)) * @as(usize, width) + @as(usize, x)) * 4;
                try appendF32Le(&output, allocator, sanitizeHdrValue(rgba[pixel_index + channel_index]));
            }
        }
    }

    return output.toOwnedSlice(allocator);
}

pub fn writeHdrPixelRgba16f(out: []u8, pixel_index: usize, rgb: [3]f32) void {
    const dst = pixel_index * 8;
    writeF16Le(out, dst + 0, rgb[0]);
    writeF16Le(out, dst + 2, rgb[1]);
    writeF16Le(out, dst + 4, rgb[2]);
    writeF16Le(out, dst + 6, 1.0);
}

pub fn copyHdrRgbaToRgbAlloc(
    allocator: std.mem.Allocator,
    hdr_rgba: []const f32,
    width: u32,
    height: u32,
) ![]f32 {
    const pixel_count = @as(usize, width) * @as(usize, height);
    if (hdr_rgba.len < pixel_count * 4) return error.InvalidHdrData;

    const rgb = try allocator.alloc(f32, pixel_count * 3);
    var pixel_index: usize = 0;
    while (pixel_index < pixel_count) : (pixel_index += 1) {
        const src = pixel_index * 4;
        const dst = pixel_index * 3;
        rgb[dst + 0] = sanitizeHdrValue(hdr_rgba[src + 0]);
        rgb[dst + 1] = sanitizeHdrValue(hdr_rgba[src + 1]);
        rgb[dst + 2] = sanitizeHdrValue(hdr_rgba[src + 2]);
    }
    return rgb;
}

pub fn copyHdrRgbToRgbaAlloc(
    allocator: std.mem.Allocator,
    hdr_rgb: []const f32,
    width: u32,
    height: u32,
) ![]f32 {
    const pixel_count = @as(usize, width) * @as(usize, height);
    if (hdr_rgb.len < pixel_count * 3) return error.InvalidHdrData;

    const rgba = try allocator.alloc(f32, pixel_count * 4);
    var pixel_index: usize = 0;
    while (pixel_index < pixel_count) : (pixel_index += 1) {
        const src = pixel_index * 3;
        const dst = pixel_index * 4;
        rgba[dst + 0] = sanitizeHdrValue(hdr_rgb[src + 0]);
        rgba[dst + 1] = sanitizeHdrValue(hdr_rgb[src + 1]);
        rgba[dst + 2] = sanitizeHdrValue(hdr_rgb[src + 2]);
        rgba[dst + 3] = 1.0;
    }
    return rgba;
}

fn acesFilmScalar(x: f32) f32 {
    const clamped = @max(x, 0.0);
    return std.math.clamp((clamped * (2.51 * clamped + 0.03)) / (clamped * (2.43 * clamped + 0.59) + 0.14), 0.0, 1.0);
}

fn linearToSrgbScalar(linear: f32) f32 {
    if (linear <= 0.0031308) return linear * 12.92;
    return 1.055 * std.math.pow(f32, @max(linear, 0.0), 1.0 / 2.4) - 0.055;
}

fn applyCpuColorGrading(color: [3]f32, viewport_state: render_types.EditorViewportState) [3]f32 {
    if (!viewport_state.color_grading_enabled) return color;

    const saturation = @max(viewport_state.color_grading_saturation, 0.0);
    const contrast = @max(viewport_state.color_grading_contrast, 0.0);
    const gamma = @max(viewport_state.color_grading_gamma, 0.001);
    const luma = luminance(color);
    var graded = .{
        luma + (color[0] - luma) * saturation,
        luma + (color[1] - luma) * saturation,
        luma + (color[2] - luma) * saturation,
    };
    graded = .{
        (graded[0] - 0.5) * contrast + 0.5,
        (graded[1] - 0.5) * contrast + 0.5,
        (graded[2] - 0.5) * contrast + 0.5,
    };
    graded = .{
        std.math.pow(f32, @max(graded[0], 0.0), 1.0 / gamma),
        std.math.pow(f32, @max(graded[1], 0.0), 1.0 / gamma),
        std.math.pow(f32, @max(graded[2], 0.0), 1.0 / gamma),
    };
    return .{
        std.math.clamp(graded[0], 0.0, 1.0),
        std.math.clamp(graded[1], 0.0, 1.0),
        std.math.clamp(graded[2], 0.0, 1.0),
    };
}

pub fn tonemapHdrToRgba8Alloc(
    allocator: std.mem.Allocator,
    hdr_rgb: []const f32,
    width: u32,
    height: u32,
    viewport_state: render_types.EditorViewportState,
) ![]u8 {
    const pixel_count = @as(usize, width) * @as(usize, height);
    if (hdr_rgb.len < pixel_count * 3) return error.InvalidHdrData;

    const rgba = try allocator.alloc(u8, pixel_count * 4);
    const exposure = if (viewport_state.exposure_enabled) @max(viewport_state.exposure, 0.0) else 1.0;

    var pixel_index: usize = 0;
    while (pixel_index < pixel_count) : (pixel_index += 1) {
        const src = pixel_index * 3;
        const dst = pixel_index * 4;
        var ldr = [3]f32{
            acesFilmScalar(sanitizeHdrValue(hdr_rgb[src + 0]) * exposure),
            acesFilmScalar(sanitizeHdrValue(hdr_rgb[src + 1]) * exposure),
            acesFilmScalar(sanitizeHdrValue(hdr_rgb[src + 2]) * exposure),
        };
        ldr = applyCpuColorGrading(ldr, viewport_state);
        rgba[dst + 0] = @intFromFloat(std.math.clamp(linearToSrgbScalar(ldr[0]) * 255.0, 0.0, 255.0));
        rgba[dst + 1] = @intFromFloat(std.math.clamp(linearToSrgbScalar(ldr[1]) * 255.0, 0.0, 255.0));
        rgba[dst + 2] = @intFromFloat(std.math.clamp(linearToSrgbScalar(ldr[2]) * 255.0, 0.0, 255.0));
        rgba[dst + 3] = 255;
    }

    return rgba;
}

pub fn encodeGuideToRgba8Alloc(
    allocator: std.mem.Allocator,
    guide_rgb: []const f32,
    width: u32,
    height: u32,
    encode_normal: bool,
) ![]u8 {
    const pixel_count = @as(usize, width) * @as(usize, height);
    if (guide_rgb.len < pixel_count * 3) return error.InvalidHdrData;

    const rgba = try allocator.alloc(u8, pixel_count * 4);
    var pixel_index: usize = 0;
    while (pixel_index < pixel_count) : (pixel_index += 1) {
        const src = pixel_index * 3;
        const dst = pixel_index * 4;
        var out_rgb = [3]f32{
            guide_rgb[src + 0],
            guide_rgb[src + 1],
            guide_rgb[src + 2],
        };
        if (encode_normal) {
            const normal_len_sq = vec3.dot(out_rgb, out_rgb);
            if (normal_len_sq <= 0.0001) {
                out_rgb = .{ 0.0, 0.0, 0.0 };
            } else {
                out_rgb = .{
                    out_rgb[0] * 0.5 + 0.5,
                    out_rgb[1] * 0.5 + 0.5,
                    out_rgb[2] * 0.5 + 0.5,
                };
            }
        } else {
            out_rgb = .{
                linearToSrgbScalar(std.math.clamp(out_rgb[0], 0.0, 1.0)),
                linearToSrgbScalar(std.math.clamp(out_rgb[1], 0.0, 1.0)),
                linearToSrgbScalar(std.math.clamp(out_rgb[2], 0.0, 1.0)),
            };
        }

        rgba[dst + 0] = @intFromFloat(std.math.clamp(out_rgb[0] * 255.0, 0.0, 255.0));
        rgba[dst + 1] = @intFromFloat(std.math.clamp(out_rgb[1] * 255.0, 0.0, 255.0));
        rgba[dst + 2] = @intFromFloat(std.math.clamp(out_rgb[2] * 255.0, 0.0, 255.0));
        rgba[dst + 3] = 255;
    }

    return rgba;
}

pub fn encodePngAlloc(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    width: u32,
    height: u32,
) ![]u8 {
    if (rgba.len < @as(usize, width) * @as(usize, height) * 4) return error.InvalidPngData;

    const c = @cImport({
        @cDefine("STBI_WRITE_NO_STDIO", "1");
        @cDefine("STB_IMAGE_WRITE_IMPLEMENTATION", "1");
        @cInclude("stb_image_write.h");
    });

    var out_len: c_int = 0;
    const png_data = c.stbi_write_png_to_mem(
        @constCast(rgba.ptr),
        @intCast(width * 4),
        @intCast(width),
        @intCast(height),
        4,
        &out_len,
    ) orelse return error.PngEncodingFailed;
    defer c.free(png_data);

    const png_slice: []const u8 = @ptrCast(png_data[0..@intCast(out_len)]);
    return allocator.dupe(u8, png_slice);
}

pub fn writeFileEnsuringParent(out_path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(out_path)) |directory| {
        try std.fs.cwd().makePath(directory);
    }
    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(bytes);
}

pub fn allocSidecarPath(allocator: std.mem.Allocator, out_path: []const u8, suffix: []const u8) ![]u8 {
    const extension = std.fs.path.extension(out_path);
    const stem = if (extension.len > 0) out_path[0 .. out_path.len - extension.len] else out_path;
    const resolved_extension = if (extension.len > 0) extension else ".png";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ stem, suffix, resolved_extension });
}

// ---------------------------------------------------------------------------
// Multi-layer EXR encoding (beauty + optional AOV layers)
// ---------------------------------------------------------------------------

/// Optional AOV layers to embed alongside the beauty pass.
pub const ExrAovLayers = struct {
    /// RGB3 float albedo buffer (pixel_count * 3 floats).
    albedo: ?[]const f32 = null,
    /// RGB3 float normal buffer (pixel_count * 3 floats).
    normal: ?[]const f32 = null,
};

/// Encode a multi-layer OpenEXR file with beauty RGB + optional AOV layers.
/// `beauty_rgba` is RGBA32f (pixel_count * 4), same as `encodeExrRgb32fAlloc`.
pub fn encodeExrMultiLayerAlloc(
    allocator: std.mem.Allocator,
    beauty_rgba: []const f32,
    width: u32,
    height: u32,
    aov: ExrAovLayers,
) ![]u8 {
    if (width == 0 or height == 0) return error.InvalidDimensions;
    const pixel_count = @as(usize, width) * @as(usize, height);
    if (beauty_rgba.len < pixel_count * 4) return error.InvalidHdrData;

    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);

    // Magic + version
    try appendU32Le(&output, allocator, 20000630);
    try appendU32Le(&output, allocator, 2);

    // --- Build channel list ---
    // OpenEXR requires channels sorted alphabetically.
    // Our channels (sorted): B, G, R, albedo.B, albedo.G, albedo.R, normal.B, normal.G, normal.R
    // Note: EXR convention uses layer.channel naming for sub-layers.
    const ChannelEntry = struct {
        name: []const u8,
        source: enum { beauty, albedo, normal },
        component: usize, // 0=R, 1=G, 2=B
    };

    var channel_entries = std.ArrayList(ChannelEntry).empty;
    defer channel_entries.deinit(allocator);

    // Beauty channels (B, G, R)
    try channel_entries.append(allocator, .{ .name = "B", .source = .beauty, .component = 2 });
    try channel_entries.append(allocator, .{ .name = "G", .source = .beauty, .component = 1 });
    try channel_entries.append(allocator, .{ .name = "R", .source = .beauty, .component = 0 });

    if (aov.albedo != null) {
        try channel_entries.append(allocator, .{ .name = "albedo.B", .source = .albedo, .component = 2 });
        try channel_entries.append(allocator, .{ .name = "albedo.G", .source = .albedo, .component = 1 });
        try channel_entries.append(allocator, .{ .name = "albedo.R", .source = .albedo, .component = 0 });
    }
    if (aov.normal != null) {
        try channel_entries.append(allocator, .{ .name = "normal.B", .source = .normal, .component = 2 });
        try channel_entries.append(allocator, .{ .name = "normal.G", .source = .normal, .component = 1 });
        try channel_entries.append(allocator, .{ .name = "normal.R", .source = .normal, .component = 0 });
    }

    // Build channel list attribute
    var channel_list = std.ArrayList(u8).empty;
    defer channel_list.deinit(allocator);
    for (channel_entries.items) |entry| {
        try appendCString(&channel_list, allocator, entry.name);
        try appendI32Le(&channel_list, allocator, 2); // PixelType::FLOAT
        try channel_list.append(allocator, 0); // pLinear
        try channel_list.appendNTimes(allocator, 0, 3); // reserved
        try appendI32Le(&channel_list, allocator, 1); // xSampling
        try appendI32Le(&channel_list, allocator, 1); // ySampling
    }
    try channel_list.append(allocator, 0); // null terminator

    try appendExrAttribute(&output, allocator, "channels", "chlist", channel_list.items);
    try appendExrAttribute(&output, allocator, "compression", "compression", &[_]u8{0});

    var box2i: [16]u8 = undefined;
    writeI32Le(&box2i, 0, 0);
    writeI32Le(&box2i, 4, 0);
    writeI32Le(&box2i, 8, @intCast(width - 1));
    writeI32Le(&box2i, 12, @intCast(height - 1));
    try appendExrAttribute(&output, allocator, "dataWindow", "box2i", &box2i);
    try appendExrAttribute(&output, allocator, "displayWindow", "box2i", &box2i);
    try appendExrAttribute(&output, allocator, "lineOrder", "lineOrder", &[_]u8{0});

    var pixel_aspect_ratio: [4]u8 = undefined;
    writeF32Le(&pixel_aspect_ratio, 0, 1.0);
    try appendExrAttribute(&output, allocator, "pixelAspectRatio", "float", &pixel_aspect_ratio);

    var screen_window_center: [8]u8 = undefined;
    writeF32Le(&screen_window_center, 0, 0.0);
    writeF32Le(&screen_window_center, 4, 0.0);
    try appendExrAttribute(&output, allocator, "screenWindowCenter", "v2f", &screen_window_center);

    var screen_window_width: [4]u8 = undefined;
    writeF32Le(&screen_window_width, 0, 1.0);
    try appendExrAttribute(&output, allocator, "screenWindowWidth", "float", &screen_window_width);

    // End of header
    try output.append(allocator, 0);

    // --- Offset table + scanline data ---
    const num_channels = channel_entries.items.len;
    const scanline_data_size: u32 = @intCast(width * num_channels * @sizeOf(f32));
    const header_size = output.items.len;
    const offset_table_size = @as(usize, height) * @sizeOf(u64);
    var next_chunk_offset: u64 = @intCast(header_size + offset_table_size);
    for (0..height) |_| {
        try appendU64Le(&output, allocator, next_chunk_offset);
        next_chunk_offset += 8 + scanline_data_size; // 4 (row) + 4 (size) + data
    }

    // --- Pixel data (scanlines) ---
    for (0..height) |row| {
        try appendI32Le(&output, allocator, @intCast(row));
        try appendU32Le(&output, allocator, scanline_data_size);

        // Write channels in the order they appear in channel_entries
        for (channel_entries.items) |entry| {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const value = switch (entry.source) {
                    .beauty => blk: {
                        const pixel_index = (row * @as(usize, width) + @as(usize, x)) * 4;
                        break :blk sanitizeHdrValue(beauty_rgba[pixel_index + entry.component]);
                    },
                    .albedo => blk: {
                        const buf = aov.albedo.?;
                        const pixel_index = (row * @as(usize, width) + @as(usize, x)) * 3;
                        break :blk sanitizeHdrValue(buf[pixel_index + entry.component]);
                    },
                    .normal => blk: {
                        const buf = aov.normal.?;
                        const pixel_index = (row * @as(usize, width) + @as(usize, x)) * 3;
                        break :blk sanitizeHdrValue(buf[pixel_index + entry.component]);
                    },
                };
                try appendF32Le(&output, allocator, value);
            }
        }
    }

    return output.toOwnedSlice(allocator);
}
