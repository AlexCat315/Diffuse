const std = @import("std");
const rhi_mod = @import("engine/rhi_legacy/mod.zig");
const image_export = @import("image_export.zig");
const renderer_path_trace = @import("path_trace/renderer_path_trace.zig");
const types = @import("types.zig");

const path_trace_denoise = @import("path_trace/path_trace_denoise.zig");
const samplePathTraceGuidePixel = renderer_path_trace.samplePathTraceGuidePixel;

pub const FramePixels = struct {
    data: []u8,
    width: u32,
    height: u32,
};

pub const HdrFramePixels = struct {
    data: []f32,
    width: u32,
    height: u32,
};

pub const PathTracePngExportOptions = struct {
    denoise: bool = true,
    write_aov_sidecars: bool = true,
};

pub const PathTraceExrExportOptions = struct {
    denoise: bool = true,
    write_aov_layers: bool = true,
};

pub fn downloadFramePixelsAlloc(rhi: *rhi_mod.RhiDevice, color_texture: ?rhi_mod.Texture, allocator: std.mem.Allocator) !FramePixels {
    const texture = color_texture orelse return error.TextureNotFound;
    const width = texture.desc.width;
    const height = texture.desc.height;
    const row_bytes = width * 4;
    const byte_count = row_bytes * height;

    const data = try allocator.alloc(u8, byte_count);
    errdefer allocator.free(data);

    try rhi.readTextureData(&texture, row_bytes, data);

    return .{ .data = data, .width = width, .height = height };
}

pub fn downloadFinalFrameAlloc(rhi: *rhi_mod.RhiDevice, color_texture: ?rhi_mod.Texture, allocator: std.mem.Allocator) ![]u8 {
    const pixels = try downloadFramePixelsAlloc(rhi, color_texture, allocator);
    defer allocator.free(pixels.data);

    const rgb_size = @as(usize, pixels.width) * @as(usize, pixels.height) * 3;
    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ pixels.width, pixels.height }) catch return error.HeaderOverflow;

    const ppm = try allocator.alloc(u8, header.len + rgb_size);
    @memcpy(ppm[0..header.len], header);

    var src: usize = 0;
    var dst: usize = header.len;
    while (src + 3 < pixels.data.len) : (src += 4) {
        ppm[dst + 0] = pixels.data[src + 2];
        ppm[dst + 1] = pixels.data[src + 1];
        ppm[dst + 2] = pixels.data[src + 0];
        dst += 3;
    }
    return ppm;
}

pub fn downloadHdrFramePixelsAlloc(rhi: *rhi_mod.RhiDevice, hdr_color_texture: ?rhi_mod.Texture, allocator: std.mem.Allocator) !HdrFramePixels {
    const texture = hdr_color_texture orelse return error.TextureNotFound;
    const width = texture.desc.width;
    const height = texture.desc.height;
    const row_bytes = width * texture.desc.format.bytesPerPixel();
    const byte_count = row_bytes * height;

    const raw = try allocator.alloc(u8, byte_count);
    defer allocator.free(raw);
    try rhi.readTextureData(&texture, row_bytes, raw);

    const pixel_count = @as(usize, width) * @as(usize, height);
    const hdr = try allocator.alloc(f32, pixel_count * 4);
    errdefer allocator.free(hdr);

    switch (texture.desc.format) {
        .rgba16_float => {
            var pixel_index: usize = 0;
            while (pixel_index < pixel_count) : (pixel_index += 1) {
                const src = pixel_index * 8;
                const dst = pixel_index * 4;
                hdr[dst + 0] = image_export.readF16Le(raw, src + 0);
                hdr[dst + 1] = image_export.readF16Le(raw, src + 2);
                hdr[dst + 2] = image_export.readF16Le(raw, src + 4);
                hdr[dst + 3] = image_export.readF16Le(raw, src + 6);
            }
        },
        .rgba32_float => {
            var pixel_index: usize = 0;
            while (pixel_index < pixel_count) : (pixel_index += 1) {
                const src = pixel_index * 16;
                const dst = pixel_index * 4;
                const r_bits: u32 = @as(u32, raw[src + 0]) |
                    (@as(u32, raw[src + 1]) << 8) |
                    (@as(u32, raw[src + 2]) << 16) |
                    (@as(u32, raw[src + 3]) << 24);
                const g_bits: u32 = @as(u32, raw[src + 4]) |
                    (@as(u32, raw[src + 5]) << 8) |
                    (@as(u32, raw[src + 6]) << 16) |
                    (@as(u32, raw[src + 7]) << 24);
                const b_bits: u32 = @as(u32, raw[src + 8]) |
                    (@as(u32, raw[src + 9]) << 8) |
                    (@as(u32, raw[src + 10]) << 16) |
                    (@as(u32, raw[src + 11]) << 24);
                const a_bits: u32 = @as(u32, raw[src + 12]) |
                    (@as(u32, raw[src + 13]) << 8) |
                    (@as(u32, raw[src + 14]) << 16) |
                    (@as(u32, raw[src + 15]) << 24);
                hdr[dst + 0] = @bitCast(r_bits);
                hdr[dst + 1] = @bitCast(g_bits);
                hdr[dst + 2] = @bitCast(b_bits);
                hdr[dst + 3] = @bitCast(a_bits);
            }
        },
        else => return error.UnsupportedTextureFormat,
    }

    return .{ .data = hdr, .width = width, .height = height };
}

pub fn downloadHdrFrameExrAlloc(rhi: *rhi_mod.RhiDevice, hdr_color_texture: ?rhi_mod.Texture, allocator: std.mem.Allocator) ![]u8 {
    const pixels = try downloadHdrFramePixelsAlloc(rhi, hdr_color_texture, allocator);
    defer allocator.free(pixels.data);
    return image_export.encodeExrRgb32fAlloc(allocator, pixels.data, pixels.width, pixels.height);
}

pub fn exportFramePng(rhi: *rhi_mod.RhiDevice, color_texture: ?rhi_mod.Texture, allocator: std.mem.Allocator, out_path: []const u8) !void {
    const pixels = try downloadFramePixelsAlloc(rhi, color_texture, allocator);
    defer allocator.free(pixels.data);

    var i: usize = 0;
    while (i < pixels.data.len) : (i += 4) {
        const b = pixels.data[i];
        pixels.data[i] = pixels.data[i + 2];
        pixels.data[i + 2] = b;
    }

    const png = try image_export.encodePngAlloc(allocator, pixels.data, pixels.width, pixels.height);
    defer allocator.free(png);
    try image_export.writeFileEnsuringParent(out_path, png);
}

pub fn exportFrameExr(rhi: *rhi_mod.RhiDevice, hdr_color_texture: ?rhi_mod.Texture, allocator: std.mem.Allocator, out_path: []const u8) !void {
    const exr = try downloadHdrFrameExrAlloc(rhi, hdr_color_texture, allocator);
    defer allocator.free(exr);
    try image_export.writeFileEnsuringParent(out_path, exr);
}

pub fn copyHalfTracePixelsToRgbAlloc(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    width: u32,
    height: u32,
) ![]f32 {
    const pixel_count = @as(usize, width) * @as(usize, height);
    if (pixels.len < pixel_count * 8) return error.InvalidPixelBuffer;
    const rgb = try allocator.alloc(f32, pixel_count * 3);
    errdefer allocator.free(rgb);

    var pixel_index: usize = 0;
    while (pixel_index < pixel_count) : (pixel_index += 1) {
        const src = pixel_index * 8;
        const dst = pixel_index * 3;
        rgb[dst + 0] = image_export.readF16Le(pixels, src + 0);
        rgb[dst + 1] = image_export.readF16Le(pixels, src + 2);
        rgb[dst + 2] = image_export.readF16Le(pixels, src + 4);
    }
    return rgb;
}
