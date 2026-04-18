const std = @import("std");
const gfx_types = @import("guava_gfx").types;

// SH coefficients for efficient irradiance calculation
pub const SH9 = struct {
    coefficients: [9][3]f32,

    pub fn init() SH9 {
        return .{ .coefficients = [_][3]f32{[_]f32{0.0} ** 3} ** 9 };
    }

    // Project a cubemap into spherical harmonics
    pub fn projectCubemap(self: *SH9, width: u32, height: u32, pixels: []const f32) void {
        // Simple Monte Carlo integration
        var i: u32 = 0;
        while (i < width * height) : (i += 1) {
            const x = i % width;
            const y = i / width;

            // Generate direction from uv
            const uv = [2]f32{ @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(width)), @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(height)) };
            const dir = uvToDirection(uv);

            // Sample color
            const pixel_idx = i * 4;
            const color = [3]f32{ pixels[pixel_idx], pixels[pixel_idx + 1], pixels[pixel_idx + 2] };

            // Project into SH
            const sh_basis = evalSHBasis(dir);
            for (0..9) |j| {
                self.coefficients[j][0] += color[0] * sh_basis[j];
                self.coefficients[j][1] += color[1] * sh_basis[j];
                self.coefficients[j][2] += color[2] * sh_basis[j];
            }
        }

        // Normalize
        const inv_samples = 1.0 / @as(f32, @floatFromInt(width * height));
        for (0..9) |j| {
            self.coefficients[j][0] *= inv_samples;
            self.coefficients[j][1] *= inv_samples;
            self.coefficients[j][2] *= inv_samples;
        }
    }

    // Evaluate irradiance at a direction using all 9 SH bands
    // Cosine-lobe convolution coefficients: Aₗ = π for L=0, 2π/3 for L=1, π/4 for L=2
    pub fn evalIrradiance(self: *const SH9, direction: [3]f32) [3]f32 {
        const sh_basis = evalSHBasis(direction);
        var result = [3]f32{ 0.0, 0.0, 0.0 };

        const band_scales = [_]f32{
            3.141593, // L=0: π
            2.094395, 2.094395, 2.094395, // L=1: 2π/3
            0.785398, 0.785398, 0.785398, 0.785398, 0.785398, // L=2: π/4
        };

        for (0..9) |j| {
            result[0] += self.coefficients[j][0] * sh_basis[j] * band_scales[j];
            result[1] += self.coefficients[j][1] * sh_basis[j] * band_scales[j];
            result[2] += self.coefficients[j][2] * sh_basis[j] * band_scales[j];
        }

        return .{
            @max(result[0], 0.0),
            @max(result[1], 0.0),
            @max(result[2], 0.0),
        };
    }
};

// Convert UV coordinates to direction vector
fn uvToDirection(uv: [2]f32) [3]f32 {
    // Convert from [0,1] to [-1,1] and generate direction
    const x = uv[0] * 2.0 - 1.0;
    const y = uv[1] * 2.0 - 1.0;

    // Simple equirectangular to direction mapping
    const phi = x * std.math.pi;
    const theta = (1.0 - y) * std.math.pi * 0.5;

    const sin_theta = std.math.sin(theta);
    return .{
        sin_theta * std.math.cos(phi),
        std.math.cos(theta),
        sin_theta * std.math.sin(phi),
    };
}

// Evaluate Spherical Harmonics basis functions (L0 + L1 + L2 = 9 coefficients)
fn evalSHBasis(direction: [3]f32) [9]f32 {
    const x = direction[0];
    const y = direction[1];
    const z = direction[2];

    var basis: [9]f32 = undefined;

    // Band 0 (L=0)
    basis[0] = 0.282095; // 1/2 * sqrt(1/π)

    // Band 1 (L=1)
    basis[1] = -0.488603 * y; // -1/2 * sqrt(3/π) * y
    basis[2] = 0.488603 * z; //  1/2 * sqrt(3/π) * z
    basis[3] = -0.488603 * x; // -1/2 * sqrt(3/π) * x

    // Band 2 (L=2)
    basis[4] = 1.092548 * x * y; //  1/2 * sqrt(15/π) * xy
    basis[5] = -1.092548 * y * z; // -1/2 * sqrt(15/π) * yz
    basis[6] = 0.315392 * (3.0 * z * z - 1.0); // 1/4 * sqrt(5/π) * (3z²-1)
    basis[7] = -1.092548 * x * z; // -1/2 * sqrt(15/π) * xz
    basis[8] = 0.546274 * (x * x - y * y); // 1/4 * sqrt(15/π) * (x²-y²)

    return basis;
}

// Generate irradiance map from HDR environment map
pub fn generateIrradianceMap(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    hdr_pixels: []const f32,
    output_size: u32,
) ![]f32 {
    var sh = SH9.init();
    sh.projectCubemap(width, height, hdr_pixels);

    const output_pixels = output_size * output_size;
    var irradiance = try allocator.alloc(f32, output_pixels * 3);
    errdefer allocator.free(irradiance);

    var i: u32 = 0;
    while (i < output_pixels) : (i += 1) {
        const x = i % output_size;
        const y = i / output_size;

        const uv = [2]f32{ @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(output_size)), @as(f32, @floatFromInt(y)) / @as(f32, @floatFromInt(output_size)) };
        const dir = uvToDirection(uv);

        const color = sh.evalIrradiance(dir);
        irradiance[i * 3] = color[0];
        irradiance[i * 3 + 1] = color[1];
        irradiance[i * 3 + 2] = color[2];
    }

    return irradiance;
}

// Generate prefiltered environment map for different roughness levels
pub fn generatePrefilteredMap(
    allocator: std.mem.Allocator,
    src_width: u32,
    src_height: u32,
    hdr_pixels: []const f32,
    out_width: u32,
    out_height: u32,
    max_mip_level: u32,
) ![]f32 {
    // For simplicity, we use a box filter approximation
    // Real implementation should use importance sampling with GGX distribution

    var result = try allocator.alloc(f32, out_width * out_height * 3);
    errdefer allocator.free(result);

    // For each roughness level (approximated with a simple blur)
    const roughness = if (max_mip_level > 0)
        @min(@as(f32, @floatFromInt(max_mip_level)) / 10.0, 1.0)
    else
        0.5;
    const filter_size = @max(1, @as(u32, @intFromFloat(roughness * 10.0)));

    // Scale factor from output to source coordinates
    const scale_x = @as(f32, @floatFromInt(src_width)) / @as(f32, @floatFromInt(out_width));
    const scale_y = @as(f32, @floatFromInt(src_height)) / @as(f32, @floatFromInt(out_height));

    var i: u32 = 0;
    while (i < out_width * out_height) : (i += 1) {
        const ox = i % out_width;
        const oy = i / out_width;

        // Map output pixel to source coordinates
        const src_x = @as(u32, @intFromFloat(@as(f32, @floatFromInt(ox)) * scale_x));
        const src_y = @as(u32, @intFromFloat(@as(f32, @floatFromInt(oy)) * scale_y));

        // Simple box filter
        var color = [3]f32{ 0.0, 0.0, 0.0 };
        var sample_count: u32 = 0;

        const kernel_size = filter_size;
        var ky: u32 = 0;
        while (ky < kernel_size) : (ky += 1) {
            var kx: u32 = 0;
            while (kx < kernel_size) : (kx += 1) {
                const sx = @min(src_x + kx, src_width - 1);
                const sy = @min(src_y + ky, src_height - 1);
                const sample_idx = (sy * src_width + sx) * 4;

                if (sample_idx + 2 < hdr_pixels.len) {
                    color[0] += hdr_pixels[sample_idx];
                    color[1] += hdr_pixels[sample_idx + 1];
                    color[2] += hdr_pixels[sample_idx + 2];
                    sample_count += 1;
                }
            }
        }

        if (sample_count > 0) {
            const inv_count = 1.0 / @as(f32, @floatFromInt(sample_count));
            result[i * 3] = color[0] * inv_count;
            result[i * 3 + 1] = color[1] * inv_count;
            result[i * 3 + 2] = color[2] * inv_count;
        } else {
            result[i * 3] = 0.0;
            result[i * 3 + 1] = 0.0;
            result[i * 3 + 2] = 0.0;
        }
    }

    return result;
}

// Generate BRDF LUT for split-sum approximation
pub fn generateBRDFLUT(allocator: std.mem.Allocator, size: u32) ![]f32 {
    // BRDF LUT stores (scale, bias) for split-sum approximation
    var lut = try allocator.alloc(f32, size * size * 2);
    errdefer allocator.free(lut);

    const inv_size = 1.0 / @as(f32, @floatFromInt(size));

    var y: u32 = 0;
    while (y < size) : (y += 1) {
        var x: u32 = 0;
        while (x < size) : (x += 1) {
            const roughness = @as(f32, @floatFromInt(x)) * inv_size;
            const n_dot_v = @as(f32, @floatFromInt(y)) * inv_size;

            // Approximate BRDF integration using GGX
            const result = integrateBRDF(roughness, n_dot_v);

            const idx = (y * size + x) * 2;
            lut[idx] = result[0]; // scale
            lut[idx + 1] = result[1]; // bias
        }
    }

    return lut;
}

// Approximate BRDF integration for given roughness and NdotV
fn integrateBRDF(roughness: f32, n_dot_v: f32) [2]f32 {
    // Use GGX distribution
    const alpha = roughness * roughness;

    // Simplified BRDF integration
    // In a real implementation, use importance sampling with many samples
    const view_weight = 0.75 + n_dot_v * 0.25;
    const scale = 1.0 - alpha * 0.5 * view_weight;
    const bias = alpha * 0.5 * (1.0 - n_dot_v * 0.5);

    return .{ scale, bias };
}
