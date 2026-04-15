const std = @import("std");

const c = @import("c_svg_bridge");

pub const RasterizedSvg = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: *RasterizedSvg) void {
        self.allocator.free(self.pixels);
        self.* = undefined;
    }
};

pub const RasterizeOptions = struct {
    width: u32 = 0,
    height: u32 = 0,
    tint: ?[4]u8 = null,
};

pub fn rasterizeBgra8(allocator: std.mem.Allocator, path: []const u8, options: RasterizeOptions) !RasterizedSvg {
    var output: c.GuavaSvgRasterImage = std.mem.zeroes(c.GuavaSvgRasterImage);
    defer c.guava_svg_free_image(&output);

    const tint_rgba = options.tint orelse [4]u8{ 0, 0, 0, 0 };
    const raster_options = c.GuavaSvgRasterOptions{
        .width = options.width,
        .height = options.height,
        .apply_tint = options.tint != null,
        .tint_rgba = tint_rgba,
    };

    if (!c.guava_svg_rasterize_file(path.ptr, path.len, raster_options, &output)) {
        return error.SvgRasterizeFailed;
    }
    if (output.width == 0 or output.height == 0 or output.pixels == null or output.length == 0) {
        return error.InvalidSvgDimensions;
    }

    const pixel_count: usize = @intCast(output.length);
    const pixels = try allocator.alloc(u8, pixel_count);
    const source: [*]u8 = @ptrCast(output.pixels);
    @memcpy(pixels, source[0..pixel_count]);

    return .{
        .allocator = allocator,
        .width = output.width,
        .height = output.height,
        .pixels = pixels,
    };
}
