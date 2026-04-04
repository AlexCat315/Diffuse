/// MCP Screenshot Tool - Convert viewport rendering to PNG and return as base64.
const std = @import("std");
const core = @import("../core/layer.zig");
const image_export = @import("../render/image_export.zig");

/// Encode binary PNG data as base64 string
fn encodeBase64Alloc(allocator: std.mem.Allocator, png_data: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    const encoded_len = encoder.calcSize(png_data.len);
    const encoded = try allocator.alloc(u8, encoded_len);
    _ = encoder.encode(encoded, png_data);
    return encoded;
}

/// Capture viewport frame, encode as PNG, return as base64 data URI
/// Returns allocated string "data:image/png;base64,{base64_data}"
pub fn screenshotAsDataUriAlloc(
    allocator: std.mem.Allocator,
    layer_context: *core.LayerContext,
) ![]u8 {
    const pixels = try layer_context.renderer.downloadFramePixelsAlloc(allocator);
    defer allocator.free(pixels.data);

    // Renderer readback is BGRA; swap into RGBA before PNG encoding.
    var i: usize = 0;
    while (i < pixels.data.len) : (i += 4) {
        const b = pixels.data[i];
        pixels.data[i] = pixels.data[i + 2];
        pixels.data[i + 2] = b;
    }

    const png_data = try image_export.encodePngAlloc(allocator, pixels.data, pixels.width, pixels.height);
    defer allocator.free(png_data);

    const base64_data = try encodeBase64Alloc(allocator, png_data);
    defer allocator.free(base64_data);

    const data_uri = try std.fmt.allocPrint(
        allocator,
        "data:image/png;base64,{s}",
        .{base64_data},
    );

    return data_uri;
}

/// Capture screenshot and return PNG as base64 (without data URI wrapper)
pub fn screenshotAsPngBase64Alloc(
    allocator: std.mem.Allocator,
    layer_context: *core.LayerContext,
) ![]u8 {
    const pixels = try layer_context.renderer.downloadFramePixelsAlloc(allocator);
    defer allocator.free(pixels.data);

    var i: usize = 0;
    while (i < pixels.data.len) : (i += 4) {
        const b = pixels.data[i];
        pixels.data[i] = pixels.data[i + 2];
        pixels.data[i + 2] = b;
    }

    const png_data = try image_export.encodePngAlloc(allocator, pixels.data, pixels.width, pixels.height);
    defer allocator.free(png_data);

    const base64_data = try encodeBase64Alloc(allocator, png_data);
    return base64_data;
}
