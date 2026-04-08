///! Core terrain data — heightmap, CPU mesh generation, LOD chunking.
///!
///! The terrain is a grid of `resolution × resolution` vertices positioned on
///! the X-Z plane with heights from a 2D heightmap.  Mesh data is generated as
///! GpuVertex + u32 index arrays, compatible with the existing mesh pipeline.
const std = @import("std");
const mesh_pass_mod = @import("../render/passes/mesh_pass.zig");
const GpuVertex = mesh_pass_mod.GpuVertex;

// ═══════════════════════════════════════════════════════════════════════════
// Heightmap
// ═══════════════════════════════════════════════════════════════════════════

pub const Heightmap = struct {
    width: u32,
    height: u32,
    data: []f32, // row-major [y * width + x]
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Heightmap {
        const count = @as(usize, width) * @as(usize, height);
        const data = try allocator.alloc(f32, count);
        @memset(data, 0);
        return .{
            .width = width,
            .height = height,
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Heightmap) void {
        self.allocator.free(self.data);
    }

    pub fn get(self: *const Heightmap, x: u32, y: u32) f32 {
        if (x >= self.width or y >= self.height) return 0;
        return self.data[@as(usize, y) * @as(usize, self.width) + @as(usize, x)];
    }

    pub fn set(self: *Heightmap, x: u32, y: u32, value: f32) void {
        if (x >= self.width or y >= self.height) return;
        self.data[@as(usize, y) * @as(usize, self.width) + @as(usize, x)] = value;
    }

    /// Generate a flat terrain at the given height.
    pub fn fill(self: *Heightmap, value: f32) void {
        @memset(self.data, value);
    }

    /// Generate gentle hills using a simple multi-octave sine pattern.
    pub fn generateHills(self: *Heightmap, amplitude: f32, frequency: f32, octaves: u32) void {
        const fw: f32 = @floatFromInt(self.width);
        const fh: f32 = @floatFromInt(self.height);
        for (0..self.height) |yi| {
            const fy: f32 = @floatFromInt(yi);
            for (0..self.width) |xi| {
                const fx: f32 = @floatFromInt(xi);
                var h: f32 = 0;
                var amp = amplitude;
                var freq = frequency;
                for (0..octaves) |_| {
                    h += @sin(fx / fw * freq * std.math.pi * 2.0) *
                        @cos(fy / fh * freq * std.math.pi * 2.0) * amp;
                    amp *= 0.5;
                    freq *= 2.0;
                }
                self.set(@intCast(xi), @intCast(yi), h);
            }
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Mesh generation
// ═══════════════════════════════════════════════════════════════════════════

pub const TerrainMesh = struct {
    vertices: []GpuVertex,
    indices: []u32,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *TerrainMesh) void {
        self.allocator.free(self.vertices);
        self.allocator.free(self.indices);
    }
};

/// Generate terrain mesh from heightmap.
///
/// `world_size` — total terrain extent in world units (X and Z).
/// `step` — vertex sampling stride (1 = full resolution, 2 = half, etc.).
/// Vertices use Y-up convention (height along Y).
pub fn generateMesh(
    allocator: std.mem.Allocator,
    heightmap: *const Heightmap,
    world_size: [2]f32,
    step: u32,
) !TerrainMesh {
    const s = if (step == 0) 1 else step;
    const cols = (heightmap.width - 1) / s + 1;
    const rows = (heightmap.height - 1) / s + 1;
    const vert_count = @as(usize, cols) * @as(usize, rows);
    const quad_count = @as(usize, cols - 1) * @as(usize, rows - 1);
    const idx_count = quad_count * 6;

    var vertices = try allocator.alloc(GpuVertex, vert_count);
    var indices = try allocator.alloc(u32, idx_count);

    const cell_x = world_size[0] / @as(f32, @floatFromInt(cols - 1));
    const cell_z = world_size[1] / @as(f32, @floatFromInt(rows - 1));
    const origin_x = -world_size[0] * 0.5;
    const origin_z = -world_size[1] * 0.5;

    // ── Vertices ──
    var vi: usize = 0;
    for (0..rows) |ri| {
        const hy: u32 = @intCast(@min(ri * s, heightmap.height - 1));
        const fz: f32 = @floatFromInt(ri);
        for (0..cols) |ci| {
            const hx: u32 = @intCast(@min(ci * s, heightmap.width - 1));
            const fx: f32 = @floatFromInt(ci);
            const height = heightmap.get(hx, hy);

            vertices[vi] = .{
                .position = .{
                    origin_x + fx * cell_x,
                    height,
                    origin_z + fz * cell_z,
                },
                .normal = .{ 0, 1, 0 }, // placeholder — computed below
                .color = .{ 1, 1, 1, 1 },
                .uv = .{
                    fx / @as(f32, @floatFromInt(cols - 1)),
                    fz / @as(f32, @floatFromInt(rows - 1)),
                },
                .joints = .{ 0, 0, 0, 0 },
                .weights = .{ 1, 0, 0, 0 },
            };
            vi += 1;
        }
    }

    // ── Normals (central-difference approximation) ──
    for (0..rows) |ri| {
        for (0..cols) |ci| {
            const idx = ri * cols + ci;
            const left = if (ci > 0) vertices[idx - 1].position[1] else vertices[idx].position[1];
            const right = if (ci < cols - 1) vertices[idx + 1].position[1] else vertices[idx].position[1];
            const down = if (ri > 0) vertices[idx - cols].position[1] else vertices[idx].position[1];
            const up = if (ri < rows - 1) vertices[idx + cols].position[1] else vertices[idx].position[1];

            const dx = right - left;
            const dz = up - down;
            // Normal = normalize((-dx, 2*cellSize, -dz))
            const nx = -dx;
            const ny = 2.0 * (cell_x + cell_z) * 0.5;
            const nz = -dz;
            const len = @sqrt(nx * nx + ny * ny + nz * nz);
            if (len > 1e-6) {
                vertices[idx].normal = .{ nx / len, ny / len, nz / len };
            }
        }
    }

    // ── Indices (two triangles per quad, CCW winding) ──
    var ii: usize = 0;
    for (0..rows - 1) |ri| {
        for (0..cols - 1) |ci| {
            const tl: u32 = @intCast(ri * cols + ci);
            const tr: u32 = tl + 1;
            const bl: u32 = @intCast((ri + 1) * cols + ci);
            const br: u32 = bl + 1;
            // Triangle 1
            indices[ii + 0] = tl;
            indices[ii + 1] = bl;
            indices[ii + 2] = tr;
            // Triangle 2
            indices[ii + 3] = tr;
            indices[ii + 4] = bl;
            indices[ii + 5] = br;
            ii += 6;
        }
    }

    return .{
        .vertices = vertices,
        .indices = indices,
        .allocator = allocator,
    };
}

// ═══════════════════════════════════════════════════════════════════════════
// LOD chunk (for distance-based LOD)
// ═══════════════════════════════════════════════════════════════════════════

pub const LodLevel = struct {
    step: u32, // vertex sampling stride
    mesh: ?TerrainMesh = null,
};

/// A terrain chunk at a given grid region [chunk_x, chunk_z] with multiple LOD
/// levels.  Each LOD generates a mesh at a different vertex density.
pub const TerrainChunk = struct {
    chunk_x: u32,
    chunk_z: u32,
    lods: [4]LodLevel = .{
        .{ .step = 1 }, // LOD 0 — full detail
        .{ .step = 2 }, // LOD 1 — half
        .{ .step = 4 }, // LOD 2 — quarter
        .{ .step = 8 }, // LOD 3 — eighth
    },
    active_lod: u8 = 0,

    pub fn activeMesh(self: *const TerrainChunk) ?*const TerrainMesh {
        return if (self.lods[self.active_lod].mesh) |*m| m else null;
    }

    pub fn deinit(self: *TerrainChunk) void {
        for (&self.lods) |*lod| {
            if (lod.mesh) |*m| m.deinit();
            lod.mesh = null;
        }
    }
};

// ═══════════════════════════════════════════════════════════════════════════
// Terrain
// ═══════════════════════════════════════════════════════════════════════════

pub const Terrain = struct {
    heightmap: Heightmap,
    world_size: [2]f32, // X, Z extents
    max_height: f32 = 100.0,

    /// Simple single-chunk terrain (no chunking yet).
    mesh: ?TerrainMesh = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, resolution: u32, world_size: [2]f32) !Terrain {
        return .{
            .heightmap = try Heightmap.init(allocator, resolution, resolution),
            .world_size = world_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Terrain) void {
        if (self.mesh) |*m| m.deinit();
        self.heightmap.deinit();
    }

    /// Rebuild mesh from current heightmap (call after modifying heights).
    pub fn rebuildMesh(self: *Terrain, lod_step: u32) !void {
        if (self.mesh) |*m| m.deinit();
        self.mesh = try generateMesh(
            self.allocator,
            &self.heightmap,
            self.world_size,
            lod_step,
        );
    }

    /// Get height at world position (bilinear interpolation).
    pub fn getHeightAt(self: *const Terrain, world_x: f32, world_z: f32) f32 {
        const hm = &self.heightmap;
        // World → heightmap coords
        const u = (world_x + self.world_size[0] * 0.5) / self.world_size[0];
        const v = (world_z + self.world_size[1] * 0.5) / self.world_size[1];
        if (u < 0 or u > 1 or v < 0 or v > 1) return 0;

        const fx = u * @as(f32, @floatFromInt(hm.width - 1));
        const fz = v * @as(f32, @floatFromInt(hm.height - 1));
        const ix: u32 = @intFromFloat(@floor(fx));
        const iz: u32 = @intFromFloat(@floor(fz));
        const dx = fx - @as(f32, @floatFromInt(ix));
        const dz = fz - @as(f32, @floatFromInt(iz));

        const h00 = hm.get(ix, iz);
        const h10 = hm.get(ix + 1, iz);
        const h01 = hm.get(ix, iz + 1);
        const h11 = hm.get(ix + 1, iz + 1);

        return h00 * (1 - dx) * (1 - dz) +
            h10 * dx * (1 - dz) +
            h01 * (1 - dx) * dz +
            h11 * dx * dz;
    }
};
