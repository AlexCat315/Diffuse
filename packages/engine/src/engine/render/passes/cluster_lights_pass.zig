const std = @import("std");
const rhi_mod = @import("../../rhi/device.zig");
const rhi_types = @import("guava_rhi").types;
const shader_support = @import("../shader_support.zig");

// ── Constants (must match cluster_lights.comp.glsl) ─────────────────────────
pub const cluster_x = 16;
pub const cluster_y = 9;
pub const cluster_z = 24;
pub const total_clusters = cluster_x * cluster_y * cluster_z; // 3456
pub const max_point_lights = 256;
pub const max_lights_per_cluster = 64;
/// Number of compute groups dispatched (ceil(total_clusters / local_size_x=64))
pub const dispatch_groups = (total_clusters + 63) / 64; // 54

// ── GPU data types (std140 layout, must match cluster_lights.comp.glsl) ──────

/// Point light as uploaded to the cluster_lights UBO.
pub const GpuPointLight = extern struct {
    position_range: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 }, // xyz=worldpos, w=range
    color_intensity: [4]f32 = .{ 0.0, 0.0, 0.0, 0.0 }, // rgb=color, w=intensity
};

/// Full UBO uploaded to the cluster_lights compute shader every frame.
/// std140 layout — kept in sync with the GLSL definition.
pub const ClusterLightsUniforms = extern struct {
    inv_projection: [16]f32 = std.mem.zeroes([16]f32), // clip → view
    view: [16]f32 = std.mem.zeroes([16]f32), // world → view
    near: f32 = 0.1,
    far: f32 = 1000.0,
    viewport_w: f32 = 1.0,
    viewport_h: f32 = 1.0,
    point_count: u32 = 0,
    _pad: [3]u32 = .{ 0, 0, 0 },
    lights: [max_point_lights]GpuPointLight = std.mem.zeroes([max_point_lights]GpuPointLight),
};

comptime {
    // UBO size check (std140):
    //   inv_projection: 64B  view: 64B  near..viewport_h: 16B  count+pad: 16B  lights: 8192B
    std.debug.assert(@sizeOf(ClusterLightsUniforms) == 64 + 64 + 16 + 16 + max_point_lights * 32);
}

// ── Pass struct ───────────────────────────────────────────────────────────────

pub const ClusterLightsPass = struct {
    pipeline: ?rhi_mod.ComputePipeline = null,
    /// R32UI  width=3456  height=1   — per-cluster light count
    cluster_count_texture: ?rhi_mod.Texture = null,
    /// R32UI  width=64  height=3456  — per-cluster light indices
    cluster_indices_texture: ?rhi_mod.Texture = null,
    /// Nearest sampler used when these textures are bound in the fragment pass.
    nearest_sampler: ?rhi_mod.Sampler = null,

    pub fn init(device: *rhi_mod.RhiDevice) !ClusterLightsPass {
        var pass = ClusterLightsPass{};
        try pass.createResources(device);
        return pass;
    }

    pub fn deinit(self: *ClusterLightsPass, device: *rhi_mod.RhiDevice) void {
        if (self.pipeline) |*p| device.releaseComputePipeline(p);
        if (self.cluster_count_texture) |*t| device.releaseTexture(t);
        if (self.cluster_indices_texture) |*t| device.releaseTexture(t);
        if (self.nearest_sampler) |*s| device.releaseSampler(s);
        self.* = undefined;
    }

    pub fn isReady(self: *const ClusterLightsPass) bool {
        return self.pipeline != null and
            self.cluster_count_texture != null and
            self.cluster_indices_texture != null and
            self.nearest_sampler != null;
    }

    /// Execute the cluster light culling pass.
    /// Call this every frame before the base (mesh) pass.
    pub fn dispatch(
        self: *ClusterLightsPass,
        device: *rhi_mod.RhiDevice,
        frame: rhi_mod.Frame,
        uniforms: ClusterLightsUniforms,
    ) void {
        if (!self.isReady()) return;

        const count_tex = &self.cluster_count_texture.?;
        const idx_tex = &self.cluster_indices_texture.?;

        // Declare the two writeonly storage images as outputs in the pass.
        const compute_pass = device.beginComputePass(frame, &.{ count_tex, idx_tex }, &.{}) catch return;
        device.bindComputePipeline(compute_pass, &self.pipeline.?);

        // Bind storage images at set=0 bindings 0 and 1.
        // bindComputeStorageTextureBinding(binding) → first_slot = binding × 2
        // applyBindingSetCompute: mtl_index = slot / 2 → binding number. Correct.
        device.bindComputeStorageTextureBinding(compute_pass, 0, count_tex);
        device.bindComputeStorageTextureBinding(compute_pass, 1, idx_tex);

        // Upload UBO at set=1, buffer slot 0.
        // No SSBOs in set=0, so MSL buffer(0) = this UBO.
        device.pushComputeUniformData(frame, 0, std.mem.asBytes(&uniforms));

        device.dispatchCompute(compute_pass, dispatch_groups, 1, 1);
        device.endComputePass(compute_pass);
    }

    fn createResources(self: *ClusterLightsPass, device: *rhi_mod.RhiDevice) !void {
        // 2 writeonly storage images (r32ui), 0 readonly, 0 storage buffers.
        self.pipeline = try shader_support.loadComputePipelineRW(device, "cluster_lights", 2, 0);
        errdefer {
            if (self.pipeline) |*p| device.releaseComputePipeline(p);
            self.pipeline = null;
        }

        // cluster_count_texture: one uint per cluster, laid out in a 1-D strip.
        self.cluster_count_texture = try device.createTexture(.{
            .width = total_clusters,
            .height = 1,
            .format = .r32_uint,
            .usage = rhi_types.TextureUsage.sampler |
                rhi_types.TextureUsage.compute_storage_write,
            .label = "cluster_counts",
        });
        errdefer {
            if (self.cluster_count_texture) |*t| device.releaseTexture(t);
            self.cluster_count_texture = null;
        }

        // cluster_indices_texture: up to max_lights_per_cluster indices per cluster.
        //   width  = max_lights_per_cluster (64) — index slot within cluster
        //   height = total_clusters (3456)        — cluster row
        self.cluster_indices_texture = try device.createTexture(.{
            .width = max_lights_per_cluster,
            .height = total_clusters,
            .format = .r32_uint,
            .usage = rhi_types.TextureUsage.sampler |
                rhi_types.TextureUsage.compute_storage_write,
            .label = "cluster_light_indices",
        });
        errdefer {
            if (self.cluster_indices_texture) |*t| device.releaseTexture(t);
            self.cluster_indices_texture = null;
        }

        // Nearest sampler — integer textures must not use linear filtering.
        self.nearest_sampler = try device.createSampler(.{
            .min_filter = .nearest,
            .mag_filter = .nearest,
            .mipmap_mode = .nearest,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
        });
    }
};
