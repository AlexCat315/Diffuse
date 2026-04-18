const std = @import("std");
const gfx_mod = @import("engine/render/render_context.zig");
const gfx_types = @import("guava_gfx").types;
const mat4_mod = @import("../math/mat4.zig");
const render_log = std.log.scoped(.viewport_render);

pub const SceneViewportState = struct {
    width: u32 = 0,
    height: u32 = 0,
    hdr_color_texture: ?gfx_mod.Texture = null,
    taa_texture: ?gfx_mod.Texture = null,
    velocity_texture: ?gfx_mod.Texture = null,
    ssao_texture: ?gfx_mod.Texture = null,
    ssr_texture: ?gfx_mod.Texture = null,
    ssr_blur_texture: ?gfx_mod.Texture = null,
    ssgi_texture: ?gfx_mod.Texture = null,
    contact_shadow_texture: ?gfx_mod.Texture = null,
    rt_shadow_denoised_texture: ?gfx_mod.Texture = null,
    bloom_texture: ?gfx_mod.Texture = null,
    fxaa_texture: ?gfx_mod.Texture = null,
    color_texture: ?gfx_mod.Texture = null,
    depth_texture: ?gfx_mod.Texture = null,

    /// IOSurface id for cross-process sharing (0 = not using IOSurface).
    iosurface_id: u32 = 0,
    /// Staging IOSurface id — safe to read at any time (never written by GPU).
    staging_iosurface_id: u32 = 0,
    /// POSIX shared memory name for cross-process sharing (Linux Vulkan path).
    shm_name: [64]u8 = [_]u8{0} ** 64,
    /// When true, color_texture is backed by a cross-process shared resource.
    use_iosurface: bool = false,

    pub fn deinit(self: *SceneViewportState, device: *gfx_mod.RenderContext) void {
        if (self.hdr_color_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.taa_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.velocity_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.ssao_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.ssr_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.ssr_blur_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.ssgi_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.contact_shadow_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.rt_shadow_denoised_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.bloom_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.fxaa_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.color_texture) |*texture| {
            device.releaseTexture(texture);
        }
        if (self.depth_texture) |*texture| {
            device.releaseTexture(texture);
        }
        const preserve_iosurface = self.use_iosurface;
        self.* = .{};
        self.use_iosurface = preserve_iosurface;
    }

    pub fn ensure(self: *SceneViewportState, device: *gfx_mod.RenderContext, width: u32, height: u32) !void {
        if (width == 0 or height == 0) {
            self.deinit(device);
            return;
        }

        if (self.color_texture) |color_texture| {
            if (self.depth_texture != null and self.hdr_color_texture != null and self.taa_texture != null and self.velocity_texture != null and self.ssao_texture != null and self.ssr_texture != null and self.ssr_blur_texture != null and self.ssgi_texture != null and self.contact_shadow_texture != null and self.rt_shadow_denoised_texture != null and self.bloom_texture != null and self.fxaa_texture != null and color_texture.desc.width == width and color_texture.desc.height == height) {
                self.width = width;
                self.height = height;
                return;
            }
        }

        self.deinit(device);

        self.hdr_color_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
        });
        errdefer if (self.hdr_color_texture) |*texture| {
            device.releaseTexture(texture);
            self.hdr_color_texture = null;
        };

        self.taa_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
        });
        errdefer if (self.taa_texture) |*texture| {
            device.releaseTexture(texture);
            self.taa_texture = null;
        };

        self.velocity_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
        });
        errdefer if (self.velocity_texture) |*texture| {
            device.releaseTexture(texture);
            self.velocity_texture = null;
        };

        self.ssao_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .r8_unorm,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler | gfx_types.TextureUsage.compute_storage_write,
        });
        errdefer if (self.ssao_texture) |*texture| {
            device.releaseTexture(texture);
            self.ssao_texture = null;
        };

        self.ssr_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
        });
        errdefer if (self.ssr_texture) |*texture| {
            device.releaseTexture(texture);
            self.ssr_texture = null;
        };

        self.ssr_blur_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
        });
        errdefer if (self.ssr_blur_texture) |*texture| {
            device.releaseTexture(texture);
            self.ssr_blur_texture = null;
        };

        self.ssgi_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler | gfx_types.TextureUsage.compute_storage_write,
        });
        errdefer if (self.ssgi_texture) |*texture| {
            device.releaseTexture(texture);
            self.ssgi_texture = null;
        };

        self.contact_shadow_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .r8_unorm,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
        });
        errdefer if (self.contact_shadow_texture) |*texture| {
            device.releaseTexture(texture);
            self.contact_shadow_texture = null;
        };

        self.rt_shadow_denoised_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .r8_unorm,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
        });
        errdefer if (self.rt_shadow_denoised_texture) |*texture| {
            device.releaseTexture(texture);
            self.rt_shadow_denoised_texture = null;
        };

        self.bloom_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .rgba16_float,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
        });
        errdefer if (self.bloom_texture) |*texture| {
            device.releaseTexture(texture);
            self.bloom_texture = null;
        };

        self.fxaa_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .bgra8_unorm_srgb,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
        });
        errdefer if (self.fxaa_texture) |*texture| {
            device.releaseTexture(texture);
            self.fxaa_texture = null;
        };

        self.color_texture = if (self.use_iosurface) blk: {
            const result = device.createSharedTexture(.{
                .width = width,
                .height = height,
                .format = .bgra8_unorm_srgb,
                .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
            }) catch |err| {
                render_log.err("Shared texture creation failed: {s}, falling back to private texture", .{@errorName(err)});
                self.iosurface_id = 0;
                self.shm_name = [_]u8{0} ** 64;
                break :blk try device.createTexture(.{
                    .width = width,
                    .height = height,
                    .format = .bgra8_unorm_srgb,
                    .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
                });
            };
            self.iosurface_id = result.iosurface_id;
            self.shm_name = result.shm_name;
            break :blk result.texture;
        } else try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .bgra8_unorm_srgb,
            .usage = gfx_types.TextureUsage.color_target | gfx_types.TextureUsage.sampler,
        });
        errdefer if (self.color_texture) |*texture| {
            device.releaseTexture(texture);
            self.color_texture = null;
        };

        self.depth_texture = try device.createTexture(.{
            .width = width,
            .height = height,
            .format = .d32_float,
            .usage = gfx_types.TextureUsage.depth_stencil_target | gfx_types.TextureUsage.sampler,
        });
        errdefer if (self.depth_texture) |*texture| {
            device.releaseTexture(texture);
            self.depth_texture = null;
        };

        self.width = width;
        self.height = height;
        render_log.info(
            "viewport textures ready size={d}x{d} hdr_format={s} color_format={s} depth_format={s}",
            .{
                width,
                height,
                @tagName(self.hdr_color_texture.?.desc.format),
                @tagName(self.color_texture.?.desc.format),
                @tagName(self.depth_texture.?.desc.format),
            },
        );
    }

    pub fn active(self: *const SceneViewportState) bool {
        return self.width > 0 and self.height > 0 and self.hdr_color_texture != null and self.color_texture != null and self.depth_texture != null;
    }

    pub fn hdrColor(self: *SceneViewportState) ?*const gfx_mod.Texture {
        if (self.hdr_color_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn taa(self: *SceneViewportState) ?*const gfx_mod.Texture {
        if (self.taa_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn color(self: *SceneViewportState) ?*const gfx_mod.Texture {
        if (self.color_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn bloom(self: *SceneViewportState) ?*const gfx_mod.Texture {
        if (self.bloom_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn velocity(self: *SceneViewportState) ?*const gfx_mod.Texture {
        if (self.velocity_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn ssao(self: *SceneViewportState) ?*const gfx_mod.Texture {
        if (self.ssao_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn ssr(self: *SceneViewportState) ?*const gfx_mod.Texture {
        if (self.ssr_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn ssrBlur(self: *SceneViewportState) ?*const gfx_mod.Texture {
        if (self.ssr_blur_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn ssgi(self: *SceneViewportState) ?*const gfx_mod.Texture {
        if (self.ssgi_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn contactShadow(self: *SceneViewportState) ?*const gfx_mod.Texture {
        if (self.contact_shadow_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn rtShadowDenoised(self: *SceneViewportState) ?*const gfx_mod.Texture {
        if (self.rt_shadow_denoised_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn fxaa(self: *SceneViewportState) ?*const gfx_mod.Texture {
        if (self.fxaa_texture) |*texture| {
            return texture;
        }
        return null;
    }

    pub fn depth(self: *SceneViewportState) ?*const gfx_mod.Texture {
        if (self.depth_texture) |*texture| {
            return texture;
        }
        return null;
    }
};

pub const csm_cascade_count = 4;

pub const ShadowMapState = struct {
    /// Per-cascade shadow map resolution. 2048×2048 per cascade = ~64 MB total VRAM for d32_float.
    size: u32 = 2048,
    depth_textures: [csm_cascade_count]?gfx_mod.Texture = .{ null, null, null, null },
    sampler: ?gfx_mod.Sampler = null,
    /// true = shadow map depth already cleared to 1.0 for RT shadow bypass
    cleared_for_rt: bool = false,

    /// View-space far-plane distance per cascade (computed each frame).
    cascade_splits: [csm_cascade_count]f32 = .{ 0.0, 0.0, 0.0, 0.0 },
    /// Light-space view-projection per cascade (computed each frame).
    cascade_matrices: [csm_cascade_count][16]f32 = .{ mat4_mod.identity(), mat4_mod.identity(), mat4_mod.identity(), mat4_mod.identity() },

    pub fn init(device: *gfx_mod.RenderContext) !ShadowMapState {
        const size: u32 = 2048;
        var textures: [csm_cascade_count]?gfx_mod.Texture = .{ null, null, null, null };
        errdefer for (&textures) |*t| {
            if (t.*) |*tex| device.releaseTexture(tex);
        };
        for (0..csm_cascade_count) |i| {
            const label: []const u8 = switch (i) {
                0 => "CSM_Cascade0",
                1 => "CSM_Cascade1",
                2 => "CSM_Cascade2",
                3 => "CSM_Cascade3",
                else => unreachable,
            };
            textures[i] = try device.createTexture(.{
                .width = size,
                .height = size,
                .format = .d32_float,
                .usage = gfx_types.TextureUsage.depth_stencil_target | gfx_types.TextureUsage.sampler,
                .label = label,
            });
        }

        const sampler = try device.createSampler(.{
            .min_filter = .linear,
            .mag_filter = .linear,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .enable_compare = true,
            .compare_op = .less_or_equal,
        });

        return .{
            .size = size,
            .depth_textures = textures,
            .sampler = sampler,
        };
    }

    pub fn deinit(self: *ShadowMapState, device: *gfx_mod.RenderContext) void {
        for (&self.depth_textures) |*texture| {
            if (texture.*) |*tex| {
                device.releaseTexture(tex);
            }
        }
        if (self.sampler) |*sampler| {
            device.releaseSampler(sampler);
        }
        self.* = .{};
    }
};
