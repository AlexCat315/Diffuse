const std = @import("std");

const c = @import("c_stb_image");

pub const DecodedImage = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *DecodedImage) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const DecodedImageFloat = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []f32,

    pub fn deinit(self: *DecodedImageFloat) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub fn decodeRgba8(allocator: std.mem.Allocator, encoded: []const u8) !DecodedImage {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels_in_file: c_int = 0;

    const decoded = c.stbi_load_from_memory(
        encoded.ptr,
        @intCast(encoded.len),
        &width,
        &height,
        &channels_in_file,
        4,
    ) orelse return error.ImageDecodeFailed;
    defer c.stbi_image_free(decoded);

    if (width <= 0 or height <= 0) {
        return error.InvalidImageDimensions;
    }

    const pixel_count: usize = @intCast(width * height * 4);
    const pixels = try allocator.alloc(u8, pixel_count);
    @memcpy(pixels, @as([*]u8, @ptrCast(decoded))[0..pixel_count]);

    return .{
        .allocator = allocator,
        .width = @intCast(width),
        .height = @intCast(height),
        .pixels = pixels,
    };
}

pub fn decodeRgba32f(allocator: std.mem.Allocator, encoded: []const u8) !DecodedImageFloat {
    var width: c_int = 0;
    var height: c_int = 0;
    var channels_in_file: c_int = 0;

    const decoded = c.stbi_loadf_from_memory(
        encoded.ptr,
        @intCast(encoded.len),
        &width,
        &height,
        &channels_in_file,
        4,
    ) orelse return error.ImageDecodeFailed;
    defer c.stbi_image_free(decoded);

    if (width <= 0 or height <= 0) {
        return error.InvalidImageDimensions;
    }

    const pixel_count: usize = @intCast(width * height * 4);
    const pixels = try allocator.alloc(f32, pixel_count);
    @memcpy(pixels, @as([*]f32, @ptrCast(decoded))[0..pixel_count]);

    return .{
        .allocator = allocator,
        .width = @intCast(width),
        .height = @intCast(height),
        .pixels = pixels,
    };
}
