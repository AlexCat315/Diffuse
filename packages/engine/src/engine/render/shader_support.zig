const generated_shaders = @import("../generated/shaders.zig");
const rhi_mod = @import("../rhi/device.zig");
const rhi_types = @import("../rhi/types.zig");

pub const ProgramStages = struct {
    vertex: rhi_mod.ShaderModule,
    fragment: rhi_mod.ShaderModule,

    pub fn deinit(self: *ProgramStages, device: *rhi_mod.RhiDevice) void {
        device.releaseShaderModule(&self.fragment);
        device.releaseShaderModule(&self.vertex);
        self.* = undefined;
    }
};

pub fn loadProgramStages(device: *rhi_mod.RhiDevice, name: []const u8) !ProgramStages {
    const program = generated_shaders.findProgram(name) orelse return error.MissingShaderProgram;
    const vertex_variant = program.stageForBackend(device.api, .vertex) orelse return error.UnsupportedShaderBackend;
    const fragment_variant = program.stageForBackend(device.api, .fragment) orelse return error.UnsupportedShaderBackend;

    const vertex = try device.createShaderModule(.{
        .code = vertex_variant.code,
        .stage = .vertex,
        .format = vertex_variant.format,
        .entry_point = vertex_variant.entry_point,
        .num_samplers = vertex_variant.reflection.num_samplers,
        .num_storage_textures = vertex_variant.reflection.num_storage_textures,
        .num_storage_buffers = vertex_variant.reflection.num_storage_buffers,
        .num_uniform_buffers = vertex_variant.reflection.num_uniform_buffers,
    });
    errdefer {
        var shader = vertex;
        device.releaseShaderModule(&shader);
    }

    const fragment = try device.createShaderModule(.{
        .code = fragment_variant.code,
        .stage = .fragment,
        .format = fragment_variant.format,
        .entry_point = fragment_variant.entry_point,
        .num_samplers = fragment_variant.reflection.num_samplers,
        .num_storage_textures = fragment_variant.reflection.num_storage_textures,
        .num_storage_buffers = fragment_variant.reflection.num_storage_buffers,
        .num_uniform_buffers = fragment_variant.reflection.num_uniform_buffers,
    });
    errdefer {
        var shader = fragment;
        device.releaseShaderModule(&shader);
    }

    return .{
        .vertex = vertex,
        .fragment = fragment,
    };
}

pub fn loadVertexStage(device: *rhi_mod.RhiDevice, name: []const u8) !rhi_mod.ShaderModule {
    const program = generated_shaders.findProgram(name) orelse return error.MissingShaderProgram;
    const vertex_variant = program.stageForBackend(device.api, .vertex) orelse return error.UnsupportedShaderBackend;

    return device.createShaderModule(.{
        .code = vertex_variant.code,
        .stage = .vertex,
        .format = vertex_variant.format,
        .entry_point = vertex_variant.entry_point,
        .num_samplers = vertex_variant.reflection.num_samplers,
        .num_storage_textures = vertex_variant.reflection.num_storage_textures,
        .num_storage_buffers = vertex_variant.reflection.num_storage_buffers,
        .num_uniform_buffers = vertex_variant.reflection.num_uniform_buffers,
    });
}

/// Load a compute shader program by name and create the compute pipeline.
pub fn loadComputePipeline(device: *rhi_mod.RhiDevice, name: []const u8) !rhi_mod.ComputePipeline {
    const program = generated_shaders.findComputeProgram(name) orelse return error.MissingShaderProgram;
    const variant = program.variantForBackend(device.api) orelse return error.UnsupportedShaderBackend;

    return device.createComputePipeline(.{
        .code = variant.code,
        .entry_point = variant.entry_point,
        .format = variant.format,
        .num_samplers = variant.reflection.num_samplers,
        .num_readonly_storage_textures = variant.reflection.num_storage_textures,
        .num_readonly_storage_buffers = variant.reflection.num_storage_buffers,
        .num_readwrite_storage_textures = 0,
        .num_readwrite_storage_buffers = 0,
        .num_uniform_buffers = variant.reflection.num_uniform_buffers,
        .threadcount_x = program.threadcount_x,
        .threadcount_y = program.threadcount_y,
        .threadcount_z = program.threadcount_z,
    });
}

/// Load a compute shader program with explicit readwrite storage counts.
pub fn loadComputePipelineRW(
    device: *rhi_mod.RhiDevice,
    name: []const u8,
    num_rw_storage_textures: u32,
    num_rw_storage_buffers: u32,
) !rhi_mod.ComputePipeline {
    const program = generated_shaders.findComputeProgram(name) orelse return error.MissingShaderProgram;
    const variant = program.variantForBackend(device.api) orelse return error.UnsupportedShaderBackend;

    // The reflection "images" count covers both readonly and readwrite storage textures.
    // Caller specifies how many are readwrite; the rest are readonly.
    const total_storage_tex = variant.reflection.num_storage_textures;
    const readonly_tex = if (total_storage_tex >= num_rw_storage_textures) total_storage_tex - num_rw_storage_textures else 0;
    const total_storage_buf = variant.reflection.num_storage_buffers;
    const readonly_buf = if (total_storage_buf >= num_rw_storage_buffers) total_storage_buf - num_rw_storage_buffers else 0;

    return device.createComputePipeline(.{
        .code = variant.code,
        .entry_point = variant.entry_point,
        .format = variant.format,
        .num_samplers = variant.reflection.num_samplers,
        .num_readonly_storage_textures = readonly_tex,
        .num_readonly_storage_buffers = readonly_buf,
        .num_readwrite_storage_textures = num_rw_storage_textures,
        .num_readwrite_storage_buffers = num_rw_storage_buffers,
        .num_uniform_buffers = variant.reflection.num_uniform_buffers,
        .threadcount_x = program.threadcount_x,
        .threadcount_y = program.threadcount_y,
        .threadcount_z = program.threadcount_z,
    });
}
