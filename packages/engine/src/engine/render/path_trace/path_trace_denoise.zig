const std = @import("std");
const builtin = @import("builtin");
const vec3 = @import("../../math/vec3.zig");
const common = @import("path_trace_common.zig");

pub const BackendPreference = enum {
    auto,
    oidn,
    mps,
    cpu_guided,
};

pub const BackendKind = enum {
    oidn,
    mps_guided,
    cpu_guided,
};

pub const DenoiseResult = struct {
    rgb: []f32,
    backend: BackendKind,
    fallback_used: bool = false,
};

pub fn backendLabel(backend: BackendKind) []const u8 {
    return switch (backend) {
        .oidn => "OIDN",
        .mps_guided => "MPS Guided Filter",
        .cpu_guided => "CPU Guided Filter",
    };
}

pub fn preferenceLabel(preference: BackendPreference) []const u8 {
    return switch (preference) {
        .auto => "Auto",
        .oidn => "OIDN",
        .mps => "MPS",
        .cpu_guided => "CPU Guided",
    };
}

pub fn parseBackendPreference(value: []const u8) ?BackendPreference {
    if (std.ascii.eqlIgnoreCase(value, "auto")) return .auto;
    if (std.ascii.eqlIgnoreCase(value, "oidn")) return .oidn;
    if (std.ascii.eqlIgnoreCase(value, "mps")) return .mps;
    if (std.ascii.eqlIgnoreCase(value, "cpu")) return .cpu_guided;
    if (std.ascii.eqlIgnoreCase(value, "cpu_guided")) return .cpu_guided;
    return null;
}

fn backendPreferenceFromEnv() BackendPreference {
    const allocator = std.heap.page_allocator;
    const value = std.process.getEnvVarOwned(allocator, "GUAVA_PT_DENOISER") catch return .auto;
    defer allocator.free(value);
    return parseBackendPreference(value) orelse .auto;
}

fn backendMatchesPreference(preference: BackendPreference, backend: BackendKind) bool {
    return switch (preference) {
        .auto => true,
        .oidn => backend == .oidn,
        .mps => backend == .mps_guided,
        .cpu_guided => backend == .cpu_guided,
    };
}

pub fn captureGuideBuffersAlloc(
    allocator: std.mem.Allocator,
    pt: *const common.PathTraceProgressiveState,
    comptime sample_guide_fn: fn (*const common.PathTraceProgressiveState, u32, u32) common.PathTraceGuidePixel,
) !common.PathTraceGuideBuffers {
    const pixel_count = @as(usize, pt.trace_width) * @as(usize, pt.trace_height);
    var guides = common.PathTraceGuideBuffers{
        .albedo = try allocator.alloc(f32, pixel_count * 3),
        .normal = try allocator.alloc(f32, pixel_count * 3),
        .width = pt.trace_width,
        .height = pt.trace_height,
    };
    errdefer guides.deinit(allocator);

    var y: u32 = 0;
    while (y < pt.trace_height) : (y += 1) {
        var x: u32 = 0;
        while (x < pt.trace_width) : (x += 1) {
            const guide = sample_guide_fn(pt, x, y);
            const pixel_index = (@as(usize, y) * @as(usize, pt.trace_width) + @as(usize, x)) * 3;
            guides.albedo[pixel_index + 0] = guide.albedo[0];
            guides.albedo[pixel_index + 1] = guide.albedo[1];
            guides.albedo[pixel_index + 2] = guide.albedo[2];
            guides.normal[pixel_index + 0] = guide.normal[0];
            guides.normal[pixel_index + 1] = guide.normal[1];
            guides.normal[pixel_index + 2] = guide.normal[2];
        }
    }

    return guides;
}

fn gaussianWeight(distance_sq: f32, sigma: f32) f32 {
    const sigma_sq = sigma * sigma;
    if (sigma_sq <= 0.0) return 0.0;
    return std.math.exp(-distance_sq / (2.0 * sigma_sq));
}

pub fn cpuGuidedDenoiseAlloc(
    allocator: std.mem.Allocator,
    beauty_rgb: []const f32,
    width: u32,
    height: u32,
    guides: common.PathTraceGuideBuffers,
) ![]f32 {
    const pixel_count = @as(usize, width) * @as(usize, height);
    if (beauty_rgb.len < pixel_count * 3) return error.InvalidHdrData;
    if (guides.width != width or guides.height != height) return error.InvalidDimensions;

    const pass_count: u32 = 2;
    const radius: i32 = 2;
    const spatial_sigma: f32 = 1.15;
    const albedo_sigma: f32 = 0.18;
    const normal_sigma: f32 = 0.14;

    var ping = try allocator.dupe(f32, beauty_rgb);
    errdefer allocator.free(ping);
    var pong = try allocator.alloc(f32, pixel_count * 3);
    errdefer allocator.free(pong);

    var pass_index: u32 = 0;
    while (pass_index < pass_count) : (pass_index += 1) {
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const center_pixel = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 3;
                const center_albedo = [3]f32{
                    guides.albedo[center_pixel + 0],
                    guides.albedo[center_pixel + 1],
                    guides.albedo[center_pixel + 2],
                };
                const center_normal = [3]f32{
                    guides.normal[center_pixel + 0],
                    guides.normal[center_pixel + 1],
                    guides.normal[center_pixel + 2],
                };
                const center_has_normal = vec3.dot(center_normal, center_normal) > 0.0001;

                var color_sum = [3]f32{ 0.0, 0.0, 0.0 };
                var weight_sum: f32 = 0.0;

                var offset_y: i32 = -radius;
                while (offset_y <= radius) : (offset_y += 1) {
                    const sample_y_i32 = @as(i32, @intCast(y)) + offset_y;
                    if (sample_y_i32 < 0 or sample_y_i32 >= @as(i32, @intCast(height))) continue;
                    const sample_y: u32 = @intCast(sample_y_i32);

                    var offset_x: i32 = -radius;
                    while (offset_x <= radius) : (offset_x += 1) {
                        const sample_x_i32 = @as(i32, @intCast(x)) + offset_x;
                        if (sample_x_i32 < 0 or sample_x_i32 >= @as(i32, @intCast(width))) continue;
                        const sample_x: u32 = @intCast(sample_x_i32);
                        const sample_pixel = (@as(usize, sample_y) * @as(usize, width) + @as(usize, sample_x)) * 3;

                        const sample_albedo = [3]f32{
                            guides.albedo[sample_pixel + 0],
                            guides.albedo[sample_pixel + 1],
                            guides.albedo[sample_pixel + 2],
                        };
                        const sample_normal = [3]f32{
                            guides.normal[sample_pixel + 0],
                            guides.normal[sample_pixel + 1],
                            guides.normal[sample_pixel + 2],
                        };
                        const sample_has_normal = vec3.dot(sample_normal, sample_normal) > 0.0001;

                        const spatial_distance_sq = @as(f32, @floatFromInt(offset_x * offset_x + offset_y * offset_y));
                        const albedo_delta = vec3.sub(center_albedo, sample_albedo);
                        const albedo_distance_sq = vec3.dot(albedo_delta, albedo_delta);

                        var weight = gaussianWeight(spatial_distance_sq, spatial_sigma) *
                            gaussianWeight(albedo_distance_sq, albedo_sigma);

                        if (center_has_normal != sample_has_normal) {
                            weight *= 0.02;
                        } else if (center_has_normal and sample_has_normal) {
                            const alignment = std.math.clamp(vec3.dot(center_normal, sample_normal), 0.0, 1.0);
                            const normal_delta = 1.0 - alignment;
                            weight *= gaussianWeight(normal_delta * normal_delta, normal_sigma);
                        }

                        color_sum[0] += ping[sample_pixel + 0] * weight;
                        color_sum[1] += ping[sample_pixel + 1] * weight;
                        color_sum[2] += ping[sample_pixel + 2] * weight;
                        weight_sum += weight;
                    }
                }

                if (weight_sum <= 0.0) {
                    pong[center_pixel + 0] = ping[center_pixel + 0];
                    pong[center_pixel + 1] = ping[center_pixel + 1];
                    pong[center_pixel + 2] = ping[center_pixel + 2];
                } else {
                    pong[center_pixel + 0] = color_sum[0] / weight_sum;
                    pong[center_pixel + 1] = color_sum[1] / weight_sum;
                    pong[center_pixel + 2] = color_sum[2] / weight_sum;
                }
            }
        }

        std.mem.swap([]f32, &ping, &pong);
    }

    allocator.free(pong);
    return ping;
}

fn fusedGuidanceAlloc(allocator: std.mem.Allocator, guides: common.PathTraceGuideBuffers) ![]f32 {
    const pixel_count = @as(usize, guides.width) * @as(usize, guides.height);
    const fused = try allocator.alloc(f32, pixel_count * 3);

    var pixel_index: usize = 0;
    while (pixel_index < pixel_count) : (pixel_index += 1) {
        const offset = pixel_index * 3;
        const albedo = [3]f32{
            std.math.clamp(guides.albedo[offset + 0], 0.0, 1.0),
            std.math.clamp(guides.albedo[offset + 1], 0.0, 1.0),
            std.math.clamp(guides.albedo[offset + 2], 0.0, 1.0),
        };
        var normal_rgb = [3]f32{ 0.5, 0.5, 0.5 };
        const normal = [3]f32{
            guides.normal[offset + 0],
            guides.normal[offset + 1],
            guides.normal[offset + 2],
        };
        if (vec3.dot(normal, normal) > 0.0001) {
            const normalized = vec3.normalize(normal);
            normal_rgb = .{
                normalized[0] * 0.5 + 0.5,
                normalized[1] * 0.5 + 0.5,
                normalized[2] * 0.5 + 0.5,
            };
        }

        fused[offset + 0] = std.math.clamp(albedo[0] * 0.6 + normal_rgb[0] * 0.4, 0.0, 1.0);
        fused[offset + 1] = std.math.clamp(albedo[1] * 0.6 + normal_rgb[1] * 0.4, 0.0, 1.0);
        fused[offset + 2] = std.math.clamp(albedo[2] * 0.6 + normal_rgb[2] * 0.4, 0.0, 1.0);
    }

    return fused;
}

const OIDN_DEVICE_TYPE_DEFAULT = 0;
const OIDN_FORMAT_FLOAT3 = 3;
const OIDN_QUALITY_HIGH = 6;
const OIDN_ERROR_NONE = 0;

const OidnApi = struct {
    lib: std.DynLib,
    oidnNewDevice: *const fn (i32) callconv(.c) ?*anyopaque,
    oidnCommitDevice: *const fn (?*anyopaque) callconv(.c) void,
    oidnGetDeviceError: *const fn (?*anyopaque, *?[*:0]const u8) callconv(.c) i32,
    oidnNewBuffer: *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque,
    oidnWriteBuffer: *const fn (?*anyopaque, usize, usize, *const anyopaque) callconv(.c) void,
    oidnReadBuffer: *const fn (?*anyopaque, usize, usize, *anyopaque) callconv(.c) void,
    oidnReleaseBuffer: *const fn (?*anyopaque) callconv(.c) void,
    oidnNewFilter: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque,
    oidnSetFilterImage: *const fn (?*anyopaque, [*:0]const u8, ?*anyopaque, i32, usize, usize, usize, usize, usize) callconv(.c) void,
    oidnSetFilterBool: ?*const fn (?*anyopaque, [*:0]const u8, bool) callconv(.c) void,
    oidnSetFilterInt: ?*const fn (?*anyopaque, [*:0]const u8, i32) callconv(.c) void,
    oidnCommitFilter: *const fn (?*anyopaque) callconv(.c) void,
    oidnExecuteFilter: *const fn (?*anyopaque) callconv(.c) void,
    oidnReleaseFilter: *const fn (?*anyopaque) callconv(.c) void,
    oidnReleaseDevice: *const fn (?*anyopaque) callconv(.c) void,

    fn deinit(self: *OidnApi) void {
        self.lib.close();
        self.* = undefined;
    }

    fn load() ?OidnApi {
        var lib = openOidnLibrary() orelse return null;
        errdefer lib.close();

        return .{
            .lib = lib,
            .oidnNewDevice = lookupRequired(&lib, *const fn (i32) callconv(.c) ?*anyopaque, "oidnNewDevice") orelse return null,
            .oidnCommitDevice = lookupRequired(&lib, *const fn (?*anyopaque) callconv(.c) void, "oidnCommitDevice") orelse return null,
            .oidnGetDeviceError = lookupRequired(&lib, *const fn (?*anyopaque, *?[*:0]const u8) callconv(.c) i32, "oidnGetDeviceError") orelse return null,
            .oidnNewBuffer = lookupRequired(&lib, *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque, "oidnNewBuffer") orelse return null,
            .oidnWriteBuffer = lookupRequired(&lib, *const fn (?*anyopaque, usize, usize, *const anyopaque) callconv(.c) void, "oidnWriteBuffer") orelse return null,
            .oidnReadBuffer = lookupRequired(&lib, *const fn (?*anyopaque, usize, usize, *anyopaque) callconv(.c) void, "oidnReadBuffer") orelse return null,
            .oidnReleaseBuffer = lookupRequired(&lib, *const fn (?*anyopaque) callconv(.c) void, "oidnReleaseBuffer") orelse return null,
            .oidnNewFilter = lookupRequired(&lib, *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque, "oidnNewFilter") orelse return null,
            .oidnSetFilterImage = lookupRequired(&lib, *const fn (?*anyopaque, [*:0]const u8, ?*anyopaque, i32, usize, usize, usize, usize, usize) callconv(.c) void, "oidnSetFilterImage") orelse return null,
            .oidnSetFilterBool = lookupOptionalBoolSetter(&lib),
            .oidnSetFilterInt = lookupOptionalIntSetter(&lib),
            .oidnCommitFilter = lookupRequired(&lib, *const fn (?*anyopaque) callconv(.c) void, "oidnCommitFilter") orelse return null,
            .oidnExecuteFilter = lookupRequired(&lib, *const fn (?*anyopaque) callconv(.c) void, "oidnExecuteFilter") orelse return null,
            .oidnReleaseFilter = lookupRequired(&lib, *const fn (?*anyopaque) callconv(.c) void, "oidnReleaseFilter") orelse return null,
            .oidnReleaseDevice = lookupRequired(&lib, *const fn (?*anyopaque) callconv(.c) void, "oidnReleaseDevice") orelse return null,
        };
    }
};

fn lookupRequired(lib: *std.DynLib, comptime T: type, name: [:0]const u8) ?T {
    return lib.lookup(T, name);
}

fn lookupOptionalBoolSetter(lib: *std.DynLib) ?*const fn (?*anyopaque, [*:0]const u8, bool) callconv(.c) void {
    return lib.lookup(*const fn (?*anyopaque, [*:0]const u8, bool) callconv(.c) void, "oidnSetFilterBool") orelse
        lib.lookup(*const fn (?*anyopaque, [*:0]const u8, bool) callconv(.c) void, "oidnSetFilter1b");
}

fn lookupOptionalIntSetter(lib: *std.DynLib) ?*const fn (?*anyopaque, [*:0]const u8, i32) callconv(.c) void {
    return lib.lookup(*const fn (?*anyopaque, [*:0]const u8, i32) callconv(.c) void, "oidnSetFilterInt") orelse
        lib.lookup(*const fn (?*anyopaque, [*:0]const u8, i32) callconv(.c) void, "oidnSetFilter1i");
}

fn openOidnLibrary() ?std.DynLib {
    const allocator = std.heap.page_allocator;
    const env_path = std.process.getEnvVarOwned(allocator, "GUAVA_OIDN_LIBRARY") catch null;
    defer if (env_path) |path| allocator.free(path);
    if (env_path) |path| {
        return std.DynLib.open(path) catch null;
    }

    const candidates = switch (builtin.os.tag) {
        .macos => [_][]const u8{
            "/opt/homebrew/opt/open-image-denoise/lib/libOpenImageDenoise.2.dylib",
            "/opt/homebrew/opt/open-image-denoise/lib/libOpenImageDenoise.dylib",
            "/opt/homebrew/lib/libOpenImageDenoise.2.dylib",
            "/opt/homebrew/lib/libOpenImageDenoise.dylib",
            "/usr/local/lib/libOpenImageDenoise.2.dylib",
            "/usr/local/lib/libOpenImageDenoise.dylib",
            "libOpenImageDenoise.2.dylib",
            "libOpenImageDenoise.dylib",
        },
        .windows => [_][]const u8{
            "OpenImageDenoise.dll",
            "libOpenImageDenoise.dll",
        },
        else => [_][]const u8{
            "/usr/lib/libOpenImageDenoise.so.2",
            "/usr/lib/libOpenImageDenoise.so",
            "/usr/local/lib/libOpenImageDenoise.so.2",
            "/usr/local/lib/libOpenImageDenoise.so",
            "libOpenImageDenoise.so.2",
            "libOpenImageDenoise.so",
        },
    };

    for (candidates) |candidate| {
        if (std.DynLib.open(candidate)) |lib| return lib else |_| {}
    }
    return null;
}

fn oidnSucceeded(api: *const OidnApi, device: ?*anyopaque) bool {
    var message: ?[*:0]const u8 = null;
    return api.oidnGetDeviceError(device, &message) == OIDN_ERROR_NONE;
}

fn tryOidnDenoiseAlloc(
    allocator: std.mem.Allocator,
    beauty_rgb: []const f32,
    width: u32,
    height: u32,
    guides: common.PathTraceGuideBuffers,
) !?[]f32 {
    var api = OidnApi.load() orelse return null;
    defer api.deinit();

    const device = api.oidnNewDevice(OIDN_DEVICE_TYPE_DEFAULT) orelse return null;
    defer api.oidnReleaseDevice(device);
    api.oidnCommitDevice(device);
    if (!oidnSucceeded(&api, device)) return null;

    const byte_size = beauty_rgb.len * @sizeOf(f32);

    const color_buffer = api.oidnNewBuffer(device, byte_size) orelse return null;
    defer api.oidnReleaseBuffer(color_buffer);
    const albedo_buffer = api.oidnNewBuffer(device, guides.albedo.len * @sizeOf(f32)) orelse return null;
    defer api.oidnReleaseBuffer(albedo_buffer);
    const normal_buffer = api.oidnNewBuffer(device, guides.normal.len * @sizeOf(f32)) orelse return null;
    defer api.oidnReleaseBuffer(normal_buffer);
    const output_buffer = api.oidnNewBuffer(device, byte_size) orelse return null;
    defer api.oidnReleaseBuffer(output_buffer);

    api.oidnWriteBuffer(color_buffer, 0, byte_size, @ptrCast(beauty_rgb.ptr));
    api.oidnWriteBuffer(albedo_buffer, 0, guides.albedo.len * @sizeOf(f32), @ptrCast(guides.albedo.ptr));
    api.oidnWriteBuffer(normal_buffer, 0, guides.normal.len * @sizeOf(f32), @ptrCast(guides.normal.ptr));
    if (!oidnSucceeded(&api, device)) return null;

    const filter = api.oidnNewFilter(device, "RT") orelse return null;
    defer api.oidnReleaseFilter(filter);

    api.oidnSetFilterImage(filter, "color", color_buffer, OIDN_FORMAT_FLOAT3, width, height, 0, 0, 0);
    api.oidnSetFilterImage(filter, "albedo", albedo_buffer, OIDN_FORMAT_FLOAT3, width, height, 0, 0, 0);
    api.oidnSetFilterImage(filter, "normal", normal_buffer, OIDN_FORMAT_FLOAT3, width, height, 0, 0, 0);
    api.oidnSetFilterImage(filter, "output", output_buffer, OIDN_FORMAT_FLOAT3, width, height, 0, 0, 0);
    if (api.oidnSetFilterBool) |set_filter_bool| {
        set_filter_bool(filter, "hdr", true);
        set_filter_bool(filter, "cleanAux", true);
    }
    if (api.oidnSetFilterInt) |set_filter_int| {
        set_filter_int(filter, "quality", OIDN_QUALITY_HIGH);
    }
    api.oidnCommitFilter(filter);
    if (!oidnSucceeded(&api, device)) return null;

    api.oidnExecuteFilter(filter);
    if (!oidnSucceeded(&api, device)) return null;

    const output = try allocator.alloc(f32, beauty_rgb.len);
    errdefer allocator.free(output);
    api.oidnReadBuffer(output_buffer, 0, byte_size, @ptrCast(output.ptr));
    if (!oidnSucceeded(&api, device)) return null;

    return output;
}

const mps_bridge = if (builtin.os.tag == .macos) struct {
    extern fn guava_path_trace_mps_guided_denoise(
        beauty_rgb: [*]const f32,
        guidance_rgb: [*]const f32,
        width: u32,
        height: u32,
        out_rgb: [*]f32,
    ) bool;
} else struct {};

fn tryMpsGuidedDenoiseAlloc(
    allocator: std.mem.Allocator,
    beauty_rgb: []const f32,
    width: u32,
    height: u32,
    guides: common.PathTraceGuideBuffers,
) !?[]f32 {
    if (builtin.os.tag != .macos) return null;

    const guidance_rgb = try fusedGuidanceAlloc(allocator, guides);
    defer allocator.free(guidance_rgb);

    const output = try allocator.alloc(f32, beauty_rgb.len);
    errdefer allocator.free(output);

    if (!mps_bridge.guava_path_trace_mps_guided_denoise(
        beauty_rgb.ptr,
        guidance_rgb.ptr,
        width,
        height,
        output.ptr,
    )) {
        allocator.free(output);
        return null;
    }

    return output;
}

pub fn denoiseAlloc(
    allocator: std.mem.Allocator,
    beauty_rgb: []const f32,
    width: u32,
    height: u32,
    guides: common.PathTraceGuideBuffers,
) !DenoiseResult {
    const preference = backendPreferenceFromEnv();

    if (preference == .auto or preference == .oidn) {
        if (try tryOidnDenoiseAlloc(allocator, beauty_rgb, width, height, guides)) |rgb| {
            return .{
                .rgb = rgb,
                .backend = .oidn,
                .fallback_used = !backendMatchesPreference(preference, .oidn),
            };
        }
    }

    if (preference == .auto or preference == .mps) {
        if (try tryMpsGuidedDenoiseAlloc(allocator, beauty_rgb, width, height, guides)) |rgb| {
            return .{
                .rgb = rgb,
                .backend = .mps_guided,
                .fallback_used = !backendMatchesPreference(preference, .mps_guided),
            };
        }
    }

    return .{
        .rgb = try cpuGuidedDenoiseAlloc(allocator, beauty_rgb, width, height, guides),
        .backend = .cpu_guided,
        .fallback_used = !backendMatchesPreference(preference, .cpu_guided),
    };
}

test "parseBackendPreference recognizes supported aliases" {
    try std.testing.expectEqual(BackendPreference.auto, parseBackendPreference("auto").?);
    try std.testing.expectEqual(BackendPreference.oidn, parseBackendPreference("OIDN").?);
    try std.testing.expectEqual(BackendPreference.mps, parseBackendPreference("mps").?);
    try std.testing.expectEqual(BackendPreference.cpu_guided, parseBackendPreference("cpu").?);
    try std.testing.expect(parseBackendPreference("unknown") == null);
}

test "fusedGuidanceAlloc mixes albedo with remapped normals" {
    const guides = common.PathTraceGuideBuffers{
        .albedo = &[_]f32{ 0.2, 0.4, 0.6 },
        .normal = &[_]f32{ 0.0, 0.0, 1.0 },
        .width = 1,
        .height = 1,
    };

    const fused = try fusedGuidanceAlloc(std.testing.allocator, guides);
    defer std.testing.allocator.free(fused);

    try std.testing.expectApproxEqAbs(@as(f32, 0.32), fused[0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.44), fused[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.76), fused[2], 0.0001);
}

test "cpuGuidedDenoiseAlloc smooths within matching guides and preserves albedo edges" {
    const beauty = [_]f32{
        1.0, 0.0, 0.0,
        0.2, 0.0, 0.0,
        0.0, 0.0, 1.0,
    };
    const albedo = [_]f32{
        1.0, 0.0, 0.0,
        1.0, 0.0, 0.0,
        0.0, 0.0, 1.0,
    };
    const normal = [_]f32{
        0.0, 0.0, 1.0,
        0.0, 0.0, 1.0,
        0.0, 0.0, 1.0,
    };

    const guides = common.PathTraceGuideBuffers{
        .albedo = albedo[0..],
        .normal = normal[0..],
        .width = 3,
        .height = 1,
    };

    const denoised = try cpuGuidedDenoiseAlloc(std.testing.allocator, beauty[0..], 3, 1, guides);
    defer std.testing.allocator.free(denoised);

    try std.testing.expect(denoised[3] > beauty[3]);
    try std.testing.expect(denoised[3] > 0.45);
    try std.testing.expect(denoised[5] < 0.12);
}

test "tryMpsGuidedDenoiseAlloc produces output on macOS" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;

    const beauty = [_]f32{
        0.9, 0.1, 0.1,
        0.2, 0.2, 0.8,
    };
    const albedo = [_]f32{
        1.0, 0.0, 0.0,
        0.0, 0.0, 1.0,
    };
    const normal = [_]f32{
        0.0, 0.0, 1.0,
        0.0, 0.0, 1.0,
    };

    const guides = common.PathTraceGuideBuffers{
        .albedo = albedo[0..],
        .normal = normal[0..],
        .width = 2,
        .height = 1,
    };

    const denoised = (try tryMpsGuidedDenoiseAlloc(std.testing.allocator, beauty[0..], 2, 1, guides)) orelse return error.SkipZigTest;
    defer std.testing.allocator.free(denoised);

    try std.testing.expect(std.math.isFinite(denoised[0]));
    try std.testing.expect(std.math.isFinite(denoised[5]));
}
