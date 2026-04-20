const generated_shaders = @import("../generated/shaders.zig");
const gfx_mod = @import("render_context.zig");
const gfx_types = @import("guava_rhi").types;

pub const ProgramStages = struct {
    vertex: gfx_mod.ShaderModule,
    fragment: gfx_mod.ShaderModule,

    pub fn deinit(self: *ProgramStages, device: *gfx_mod.RenderContext) void {
        device.releaseShaderModule(&self.fragment);
        device.releaseShaderModule(&self.vertex);
        self.* = undefined;
    }
};

pub fn loadProgramStages(device: *gfx_mod.RenderContext, name: []const u8) !ProgramStages {
    const program = generated_shaders.findProgram(name) orelse return error.MissingShaderProgram;
    const vertex_variant = program.stageForBackend(device.api, .vertex) orelse return error.UnsupportedShaderBackend;
    const fragment_variant = program.stageForBackend(device.api, .fragment) orelse return error.UnsupportedShaderBackend;

    const vertex = try device.createShaderModule(.{
        .code = vertex_variant.code,
        .stage = .vertex,
        .format = vertex_variant.format,
        .entry_point = vertex_variant.entry_point,
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

pub fn loadVertexStage(device: *gfx_mod.RenderContext, name: []const u8) !gfx_mod.ShaderModule {
    const program = generated_shaders.findProgram(name) orelse return error.MissingShaderProgram;
    const vertex_variant = program.stageForBackend(device.api, .vertex) orelse return error.UnsupportedShaderBackend;

    return device.createShaderModule(.{
        .code = vertex_variant.code,
        .stage = .vertex,
        .format = vertex_variant.format,
        .entry_point = vertex_variant.entry_point,
    });
}

/// Load a compute shader program by name and create the compute pipeline.
pub fn loadComputePipeline(device: *gfx_mod.RenderContext, name: []const u8) !gfx_mod.ComputePipeline {
    const program = generated_shaders.findComputeProgram(name) orelse return error.MissingShaderProgram;
    const variant = program.variantForBackend(device.api) orelse return error.UnsupportedShaderBackend;

    return device.createComputePipeline(.{
        .code = variant.code,
        .entry_point = variant.entry_point,
        .format = variant.format,
    });
}

/// Load a compute shader program with explicit readwrite storage counts.
pub fn loadComputePipelineRW(
    device: *gfx_mod.RenderContext,
    name: []const u8,
    num_rw_storage_textures: u32,
    num_rw_storage_buffers: u32,
) !gfx_mod.ComputePipeline {
    const program = generated_shaders.findComputeProgram(name) orelse return error.MissingShaderProgram;
    const variant = program.variantForBackend(device.api) orelse return error.UnsupportedShaderBackend;

    _ = num_rw_storage_textures;
    _ = num_rw_storage_buffers;

    return device.createComputePipeline(.{
        .code = variant.code,
        .entry_point = variant.entry_point,
        .format = variant.format,
    });
}
