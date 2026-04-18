///! Font loading and SDF atlas generation using stb_truetype.
///!
///! Generates a single-channel Signed Distance Field (SDF) atlas texture
///! for GPU-accelerated text rendering. Glyph metrics are stored for
///! text layout (advance, bearing, bounds).
const std = @import("std");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("guava_rhi").types;

const c = @import("c_stb_truetype");

/// Metrics for a single glyph.
pub const GlyphMetrics = struct {
    /// Codepoint this glyph represents.
    codepoint: u32 = 0,
    /// UV coordinates in the atlas (normalized 0..1).
    uv_x0: f32 = 0,
    uv_y0: f32 = 0,
    uv_x1: f32 = 0,
    uv_y1: f32 = 0,
    /// Glyph size in pixels at the font's rasterized size.
    width: f32 = 0,
    height: f32 = 0,
    /// Offset from the pen position to the glyph's top-left corner.
    bearing_x: f32 = 0,
    bearing_y: f32 = 0,
    /// Horizontal advance to the next glyph.
    advance: f32 = 0,
};

/// A loaded font with an SDF atlas ready for GPU rendering.
pub const Font = struct {
    allocator: std.mem.Allocator,
    /// Glyph lookup: codepoint → index in `glyphs`.
    glyph_map: std.AutoHashMapUnmanaged(u32, u16) = .empty,
    /// All rasterized glyphs.
    glyphs: std.ArrayListUnmanaged(GlyphMetrics) = .empty,
    /// Atlas dimensions.
    atlas_width: u32 = 0,
    atlas_height: u32 = 0,
    /// Atlas pixel data (R8, owned).
    atlas_pixels: ?[]u8 = null,
    /// GPU texture handle (created after upload).
    atlas_texture: ?rhi_mod.Texture = null,
    /// GPU sampler.
    atlas_sampler: ?rhi_mod.Sampler = null,
    /// GPU bind group for the atlas (fragment stage set=2).
    atlas_bind_group: ?rhi_mod.BindGroup = null,
    /// Font pixel size used during rasterization.
    font_size: f32 = 32,
    /// Line height (ascent - descent + lineGap) scaled to font_size.
    line_height: f32 = 0,
    /// Ascent above baseline scaled to font_size.
    ascent: f32 = 0,

    const sdf_padding: u32 = 6;
    const sdf_on_edge_value: u8 = 128;
    const sdf_pixel_dist_scale: f32 = 128.0 / @as(f32, @floatFromInt(sdf_padding));
    const atlas_max_dim: u32 = 2048;

    pub fn init(allocator: std.mem.Allocator) Font {
        return .{ .allocator = allocator };
    }

    /// Load a TTF font from raw bytes and generate the SDF atlas.
    /// `font_data` must remain valid until `deinit` is called.
    pub fn load(
        self: *Font,
        font_data: []const u8,
        font_size_px: f32,
        codepoint_ranges: []const [2]u32,
    ) !void {
        self.font_size = font_size_px;

        var info: c.stbtt_fontinfo = undefined;
        if (c.stbtt_InitFont(&info, font_data.ptr, 0) == 0) {
            return error.FontInitFailed;
        }

        const scale = c.stbtt_ScaleForPixelHeight(&info, font_size_px);

        // Read font metrics
        var asc: c_int = 0;
        var desc: c_int = 0;
        var lg: c_int = 0;
        c.stbtt_GetFontVMetrics(&info, &asc, &desc, &lg);
        self.ascent = @as(f32, @floatFromInt(asc)) * scale;
        self.line_height = @as(f32, @floatFromInt(asc - desc + lg)) * scale;

        // Count total glyphs
        var total_glyphs: usize = 0;
        for (codepoint_ranges) |range| {
            total_glyphs += range[1] - range[0] + 1;
        }

        try self.glyphs.ensureTotalCapacity(self.allocator, total_glyphs);
        try self.glyph_map.ensureTotalCapacity(self.allocator, @intCast(total_glyphs));

        // First pass: rasterize glyphs to determine atlas packing
        const glyph_size = @as(u32, @intFromFloat(font_size_px)) + sdf_padding * 2;
        const cols = atlas_max_dim / glyph_size;
        const rows = @as(u32, @intCast((total_glyphs + cols - 1) / cols));
        self.atlas_width = cols * glyph_size;
        self.atlas_height = @min(rows * glyph_size, atlas_max_dim);

        const pixel_count = @as(usize, self.atlas_width) * @as(usize, self.atlas_height);
        self.atlas_pixels = try self.allocator.alloc(u8, pixel_count);
        @memset(self.atlas_pixels.?, 0);

        var pack_x: u32 = 0;
        var pack_y: u32 = 0;

        for (codepoint_ranges) |range| {
            var cp: u32 = range[0];
            while (cp <= range[1]) : (cp += 1) {
                const glyph_index: u32 = @intCast(c.stbtt_FindGlyphIndex(&info, @intCast(cp)));
                if (glyph_index == 0 and cp != ' ') continue;

                // Get advance and bearing
                var adv: c_int = 0;
                var lsb: c_int = 0;
                c.stbtt_GetGlyphHMetrics(&info, @intCast(glyph_index), &adv, &lsb);

                // Generate SDF for this glyph
                var gw: c_int = 0;
                var gh: c_int = 0;
                var xoff: c_int = 0;
                var yoff: c_int = 0;
                const sdf_bitmap = c.stbtt_GetGlyphSDF(
                    &info,
                    scale,
                    @intCast(glyph_index),
                    @intCast(sdf_padding),
                    sdf_on_edge_value,
                    sdf_pixel_dist_scale,
                    &gw,
                    &gh,
                    &xoff,
                    &yoff,
                );

                const glyph_w: u32 = @intCast(@max(gw, 0));
                const glyph_h: u32 = @intCast(@max(gh, 0));

                // Advance to next row if needed
                if (pack_x + glyph_w > self.atlas_width) {
                    pack_x = 0;
                    pack_y += glyph_size;
                }

                if (pack_y + glyph_h > self.atlas_height) {
                    if (sdf_bitmap != null) c.stbtt_FreeSDF(sdf_bitmap, null);
                    continue; // Atlas full, skip glyph
                }

                // Copy SDF pixels into atlas
                if (sdf_bitmap != null and glyph_w > 0 and glyph_h > 0) {
                    const src: [*]const u8 = @ptrCast(sdf_bitmap);
                    var row: u32 = 0;
                    while (row < glyph_h) : (row += 1) {
                        const dst_start = @as(usize, pack_y + row) * @as(usize, self.atlas_width) + @as(usize, pack_x);
                        const src_start = @as(usize, row) * @as(usize, glyph_w);
                        @memcpy(
                            self.atlas_pixels.?[dst_start .. dst_start + glyph_w],
                            src[src_start .. src_start + glyph_w],
                        );
                    }
                    c.stbtt_FreeSDF(sdf_bitmap, null);
                }

                // Store metrics
                const aw: f32 = @floatFromInt(self.atlas_width);
                const ah: f32 = @floatFromInt(self.atlas_height);
                const glyph_idx: u16 = @intCast(self.glyphs.items.len);
                self.glyphs.appendAssumeCapacity(.{
                    .codepoint = cp,
                    .uv_x0 = @as(f32, @floatFromInt(pack_x)) / aw,
                    .uv_y0 = @as(f32, @floatFromInt(pack_y)) / ah,
                    .uv_x1 = @as(f32, @floatFromInt(pack_x + glyph_w)) / aw,
                    .uv_y1 = @as(f32, @floatFromInt(pack_y + glyph_h)) / ah,
                    .width = @floatFromInt(glyph_w),
                    .height = @floatFromInt(glyph_h),
                    .bearing_x = @floatFromInt(xoff),
                    .bearing_y = @floatFromInt(yoff),
                    .advance = @as(f32, @floatFromInt(adv)) * scale,
                });
                self.glyph_map.putAssumeCapacity(cp, glyph_idx);

                pack_x += glyph_w + 1; // 1px padding between glyphs
            }
        }
    }

    /// Upload the atlas to the GPU and create the bind group.
    pub fn createGpuResources(self: *Font, device: *rhi_mod.RhiDevice) !void {
        const pixels = self.atlas_pixels orelse return error.NoAtlasData;

        self.atlas_texture = try device.createTexture(.{
            .width = self.atlas_width,
            .height = self.atlas_height,
            .format = .r8_unorm,
            .usage = rhi_types.TextureUsage.sampler,
            .label = "ui_font_atlas",
        });
        try device.uploadTextureData(
            &self.atlas_texture.?,
            pixels,
            self.atlas_width, // pixels_per_row
            self.atlas_height, // rows_per_layer
        );

        self.atlas_sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
        });

        const bindings = [_]rhi_mod.TextureSamplerBinding{
            .{
                .texture = &self.atlas_texture.?,
                .sampler = &self.atlas_sampler.?,
            },
        };
        self.atlas_bind_group = try device.createBindGroup(.{
            .stage = .fragment,
            .texture_sampler_bindings = &bindings,
            .slot_offset = 0,
        });
    }

    /// Look up glyph metrics for a codepoint.
    pub fn getGlyph(self: *const Font, codepoint: u32) ?GlyphMetrics {
        const idx = self.glyph_map.get(codepoint) orelse return null;
        return self.glyphs.items[idx];
    }

    pub fn deinit(self: *Font, device: *rhi_mod.RhiDevice) void {
        if (self.atlas_bind_group) |*bg| device.releaseBindGroup(bg);
        if (self.atlas_sampler) |*s| device.releaseSampler(s);
        if (self.atlas_texture) |*t| device.releaseTexture(t);
        if (self.atlas_pixels) |p| self.allocator.free(p);
        self.glyphs.deinit(self.allocator);
        self.glyph_map.deinit(self.allocator);
    }

    /// Measure the width of a text string at the given font size.
    pub fn measureText(self: *const Font, text: []const u8, size: f32) f32 {
        const scale_factor = size / self.font_size;
        var width: f32 = 0;
        for (text) |byte| {
            if (self.getGlyph(byte)) |g| {
                width += g.advance * scale_factor;
            }
        }
        return width;
    }

    /// Get the scaled line height for a given font size.
    pub fn scaledLineHeight(self: *const Font, size: f32) f32 {
        return self.line_height * (size / self.font_size);
    }

    /// Get the scaled ascent for a given font size.
    pub fn scaledAscent(self: *const Font, size: f32) f32 {
        return self.ascent * (size / self.font_size);
    }
};
