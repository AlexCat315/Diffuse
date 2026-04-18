const std = @import("std");
const gfx_types = @import("guava_gfx").types;

pub const TextureResource = struct {
    name: []u8,
    width: u32,
    height: u32,
    format: gfx_types.TextureFormat = .bgra8_unorm,
    pixels: []u8,

    pub fn deinit(self: *TextureResource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const TextureResourceDesc = struct {
    name: []const u8,
    width: u32,
    height: u32,
    format: gfx_types.TextureFormat = .bgra8_unorm,
    pixels: []const u8,
};

pub fn clone(allocator: std.mem.Allocator, desc: TextureResourceDesc) !TextureResource {
    return .{
        .name = try allocator.dupe(u8, desc.name),
        .width = desc.width,
        .height = desc.height,
        .format = desc.format,
        .pixels = try allocator.dupe(u8, desc.pixels),
    };
}
