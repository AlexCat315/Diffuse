const std = @import("std");

const Manifest = struct {
    programs: []Program,
    compute_programs: []ComputeProgram = &.{},
};

const Program = struct {
    name: []const u8,
    vertex: []const u8,
    fragment: []const u8,
};

const ComputeProgram = struct {
    name: []const u8,
    compute: []const u8,
    threadcount_x: u32 = 8,
    threadcount_y: u32 = 8,
    threadcount_z: u32 = 1,
};

const Reflection = struct {
    num_samplers: u32 = 0,
    num_storage_textures: u32 = 0,
    num_storage_buffers: u32 = 0,
    num_uniform_buffers: u32 = 0,
};

const CompiledStage = struct {
    spirv_bytes: []u8,
    msl_bytes: []u8,
    reflection: Reflection,
};

const Stage = enum {
    vertex,
    fragment,
    compute,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.log.err("usage: shader_codegen <manifest.json> <output.zig>", .{});
        return error.InvalidArguments;
    }

    const manifest_source = try std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024);
    defer allocator.free(manifest_source);

    var manifest_parse = try std.json.parseFromSlice(Manifest, allocator, manifest_source, .{
        .ignore_unknown_fields = true,
    });
    defer manifest_parse.deinit();

    try generateShaderModule(allocator, manifest_parse.value, args[2]);
}

fn generateShaderModule(
    allocator: std.mem.Allocator,
    manifest: Manifest,
    output_path: []const u8,
) !void {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var writer = out.writer(allocator);

    try writer.writeAll(
        \\const std = @import("std");
        \\const rhi_types = @import("../rhi/types.zig");
        \\
        \\pub const ShaderStageReflection = struct {
        \\    num_samplers: u32 = 0,
        \\    num_storage_textures: u32 = 0,
        \\    num_storage_buffers: u32 = 0,
        \\    num_uniform_buffers: u32 = 0,
        \\};
        \\
        \\pub const ShaderVariant = struct {
        \\    format: rhi_types.ShaderFormat,
        \\    entry_point: [:0]const u8,
        \\    code: []const u8,
        \\    reflection: ShaderStageReflection,
        \\};
        \\
        \\pub const ShaderProgram = struct {
        \\    name: []const u8,
        \\    vertex_spirv: ShaderVariant,
        \\    fragment_spirv: ShaderVariant,
        \\    vertex_msl: ShaderVariant,
        \\    fragment_msl: ShaderVariant,
        \\
        \\    pub fn stageForBackend(
        \\        self: *const ShaderProgram,
        \\        backend: rhi_types.GraphicsAPI,
        \\        stage: rhi_types.ShaderStage,
        \\    ) ?ShaderVariant {
        \\        return switch (backend) {
        \\            .vulkan => switch (stage) {
        \\                .vertex => self.vertex_spirv,
        \\                .fragment => self.fragment_spirv,
        \\            },
        \\            .metal => switch (stage) {
        \\                .vertex => self.vertex_msl,
        \\                .fragment => self.fragment_msl,
        \\            },
        \\            .dx12 => null,
        \\        };
        \\    }
        \\};
        \\
        \\pub const ComputeShaderProgram = struct {
        \\    name: []const u8,
        \\    compute_spirv: ShaderVariant,
        \\    compute_msl: ShaderVariant,
        \\    threadcount_x: u32,
        \\    threadcount_y: u32,
        \\    threadcount_z: u32,
        \\
        \\    pub fn variantForBackend(self: *const ComputeShaderProgram, backend: rhi_types.GraphicsAPI) ?ShaderVariant {
        \\        return switch (backend) {
        \\            .vulkan => self.compute_spirv,
        \\            .metal => self.compute_msl,
        \\            .dx12 => null,
        \\        };
        \\    }
        \\};
        \\
    );

    for (manifest.programs) |program| {
        const identifier = try sanitizeIdentifier(allocator, program.name);
        defer allocator.free(identifier);

        const vertex_stage = try compileStage(allocator, identifier, program, .vertex);
        defer {
            allocator.free(vertex_stage.spirv_bytes);
            allocator.free(vertex_stage.msl_bytes);
        }

        const fragment_stage = try compileStage(allocator, identifier, program, .fragment);
        defer {
            allocator.free(fragment_stage.spirv_bytes);
            allocator.free(fragment_stage.msl_bytes);
        }

        try emitByteArray(&writer, identifier, "vertex_spirv", vertex_stage.spirv_bytes);
        try emitByteArray(&writer, identifier, "fragment_spirv", fragment_stage.spirv_bytes);
        try emitByteArray(&writer, identifier, "vertex_msl", vertex_stage.msl_bytes);
        try emitByteArray(&writer, identifier, "fragment_msl", fragment_stage.msl_bytes);

        const vertex_msl_entry = try std.fmt.allocPrint(allocator, "guava_{s}_vertex_main", .{identifier});
        defer allocator.free(vertex_msl_entry);
        const fragment_msl_entry = try std.fmt.allocPrint(allocator, "guava_{s}_fragment_main", .{identifier});
        defer allocator.free(fragment_msl_entry);

        try writer.print(
            \\pub const {s} = ShaderProgram{{
            \\    .name = "{s}",
            \\    .vertex_spirv = .{{
            \\        .format = .spirv,
            \\        .entry_point = "main",
            \\        .code = {s}_vertex_spirv_code[0..],
            \\        .reflection = .{{ .num_samplers = {d}, .num_storage_textures = {d}, .num_storage_buffers = {d}, .num_uniform_buffers = {d} }},
            \\    }},
            \\    .fragment_spirv = .{{
            \\        .format = .spirv,
            \\        .entry_point = "main",
            \\        .code = {s}_fragment_spirv_code[0..],
            \\        .reflection = .{{ .num_samplers = {d}, .num_storage_textures = {d}, .num_storage_buffers = {d}, .num_uniform_buffers = {d} }},
            \\    }},
            \\    .vertex_msl = .{{
            \\        .format = .msl,
            \\        .entry_point = "{s}",
            \\        .code = {s}_vertex_msl_code[0..],
            \\        .reflection = .{{ .num_samplers = {d}, .num_storage_textures = {d}, .num_storage_buffers = {d}, .num_uniform_buffers = {d} }},
            \\    }},
            \\    .fragment_msl = .{{
            \\        .format = .msl,
            \\        .entry_point = "{s}",
            \\        .code = {s}_fragment_msl_code[0..],
            \\        .reflection = .{{ .num_samplers = {d}, .num_storage_textures = {d}, .num_storage_buffers = {d}, .num_uniform_buffers = {d} }},
            \\    }},
            \\}};
            \\
        ,
            .{
                identifier,
                program.name,
                identifier,
                vertex_stage.reflection.num_samplers,
                vertex_stage.reflection.num_storage_textures,
                vertex_stage.reflection.num_storage_buffers,
                vertex_stage.reflection.num_uniform_buffers,
                identifier,
                fragment_stage.reflection.num_samplers,
                fragment_stage.reflection.num_storage_textures,
                fragment_stage.reflection.num_storage_buffers,
                fragment_stage.reflection.num_uniform_buffers,
                vertex_msl_entry,
                identifier,
                vertex_stage.reflection.num_samplers,
                vertex_stage.reflection.num_storage_textures,
                vertex_stage.reflection.num_storage_buffers,
                vertex_stage.reflection.num_uniform_buffers,
                fragment_msl_entry,
                identifier,
                fragment_stage.reflection.num_samplers,
                fragment_stage.reflection.num_storage_textures,
                fragment_stage.reflection.num_storage_buffers,
                fragment_stage.reflection.num_uniform_buffers,
            },
        );
    }

    try writer.writeAll("pub const programs = [_]*const ShaderProgram{\n");
    for (manifest.programs) |program| {
        const identifier = try sanitizeIdentifier(allocator, program.name);
        defer allocator.free(identifier);
        try writer.print("    &{s},\n", .{identifier});
    }
    try writer.writeAll(
        \\};
        \\
        \\pub fn findProgram(name: []const u8) ?*const ShaderProgram {
        \\    inline for (programs) |program| {
        \\        if (std.mem.eql(u8, program.name, name)) {
        \\            return program;
        \\        }
        \\    }
        \\    return null;
        \\}
        \\
    );

    // ---- Compute Programs ----

    for (manifest.compute_programs) |program| {
        const identifier = try sanitizeIdentifier(allocator, program.name);
        defer allocator.free(identifier);

        const compute_stage = try compileComputeStage(allocator, identifier, program.compute);
        defer {
            allocator.free(compute_stage.spirv_bytes);
            allocator.free(compute_stage.msl_bytes);
        }

        try emitByteArray(&writer, identifier, "compute_spirv", compute_stage.spirv_bytes);
        try emitByteArray(&writer, identifier, "compute_msl", compute_stage.msl_bytes);

        const compute_msl_entry = try std.fmt.allocPrint(allocator, "guava_{s}_compute_main", .{identifier});
        defer allocator.free(compute_msl_entry);

        try writer.print(
            \\pub const {s} = ComputeShaderProgram{{
            \\    .name = "{s}",
            \\    .compute_spirv = .{{
            \\        .format = .spirv,
            \\        .entry_point = "main",
            \\        .code = {s}_compute_spirv_code[0..],
            \\        .reflection = .{{ .num_samplers = {d}, .num_storage_textures = {d}, .num_storage_buffers = {d}, .num_uniform_buffers = {d} }},
            \\    }},
            \\    .compute_msl = .{{
            \\        .format = .msl,
            \\        .entry_point = "{s}",
            \\        .code = {s}_compute_msl_code[0..],
            \\        .reflection = .{{ .num_samplers = {d}, .num_storage_textures = {d}, .num_storage_buffers = {d}, .num_uniform_buffers = {d} }},
            \\    }},
            \\    .threadcount_x = {d},
            \\    .threadcount_y = {d},
            \\    .threadcount_z = {d},
            \\}};
            \\
        ,
            .{
                identifier,
                program.name,
                identifier,
                compute_stage.reflection.num_samplers,
                compute_stage.reflection.num_storage_textures,
                compute_stage.reflection.num_storage_buffers,
                compute_stage.reflection.num_uniform_buffers,
                compute_msl_entry,
                identifier,
                compute_stage.reflection.num_samplers,
                compute_stage.reflection.num_storage_textures,
                compute_stage.reflection.num_storage_buffers,
                compute_stage.reflection.num_uniform_buffers,
                program.threadcount_x,
                program.threadcount_y,
                program.threadcount_z,
            },
        );
    }

    try writer.writeAll("pub const compute_programs = [_]*const ComputeShaderProgram{\n");
    for (manifest.compute_programs) |program| {
        const identifier = try sanitizeIdentifier(allocator, program.name);
        defer allocator.free(identifier);
        try writer.print("    &{s},\n", .{identifier});
    }
    try writer.writeAll(
        \\};
        \\
        \\pub fn findComputeProgram(name: []const u8) ?*const ComputeShaderProgram {
        \\    inline for (compute_programs) |program| {
        \\        if (std.mem.eql(u8, program.name, name)) {
        \\            return program;
        \\        }
        \\    }
        \\    return null;
        \\}
        \\
    );

    if (std.fs.path.dirname(output_path)) |directory| {
        try std.fs.cwd().makePath(directory);
    }

    try std.fs.cwd().writeFile(.{
        .sub_path = output_path,
        .data = out.items,
    });
}

fn compileStage(
    allocator: std.mem.Allocator,
    identifier: []const u8,
    program: Program,
    stage: Stage,
) !CompiledStage {
    const stage_name = switch (stage) {
        .vertex => "vert",
        .fragment => "frag",
        .compute => "comp",
    };
    const stage_label = switch (stage) {
        .vertex => "vertex",
        .fragment => "fragment",
        .compute => "compute",
    };
    const source_path = switch (stage) {
        .vertex => program.vertex,
        .fragment => program.fragment,
        .compute => unreachable, // use compileComputeStage
    };

    const output_basename = try std.fmt.allocPrint(allocator, "{s}.{s}.spv", .{ identifier, stage_name });
    defer allocator.free(output_basename);

    const source_absolute = try std.fs.cwd().realpathAlloc(allocator, source_path);
    defer allocator.free(source_absolute);

    try std.fs.cwd().makePath(".zig-cache/shader-gen");
    const spirv_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "shader-gen", output_basename });
    defer allocator.free(spirv_path);

    try runCommand(allocator, &.{
        "glslangValidator",
        "-V",
        source_absolute,
        "-S",
        stage_name,
        "-o",
        spirv_path,
    });

    const spirv_bytes = try std.fs.cwd().readFileAlloc(allocator, spirv_path, 4 * 1024 * 1024);

    const reflection_json = try runCommandCapture(allocator, &.{
        "spirv-cross",
        spirv_path,
        "--reflect",
    });
    defer allocator.free(reflection_json);
    const reflection = try parseReflection(allocator, reflection_json);

    const msl_entry = try std.fmt.allocPrint(allocator, "guava_{s}_{s}_main", .{ identifier, stage_label });
    defer allocator.free(msl_entry);

    const msl_source = try runCommandCapture(allocator, &.{
        "spirv-cross",
        spirv_path,
        "--msl",
        "--rename-entry-point",
        "main",
        msl_entry,
        stage_name,
    });

    return .{
        .spirv_bytes = spirv_bytes,
        .msl_bytes = msl_source,
        .reflection = reflection,
    };
}

fn compileComputeStage(
    allocator: std.mem.Allocator,
    identifier: []const u8,
    source_path: []const u8,
) !CompiledStage {
    const output_basename = try std.fmt.allocPrint(allocator, "{s}.comp.spv", .{identifier});
    defer allocator.free(output_basename);

    const source_absolute = try std.fs.cwd().realpathAlloc(allocator, source_path);
    defer allocator.free(source_absolute);

    try std.fs.cwd().makePath(".zig-cache/shader-gen");
    const spirv_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "shader-gen", output_basename });
    defer allocator.free(spirv_path);

    try runCommand(allocator, &.{
        "glslangValidator",
        "-V",
        source_absolute,
        "-S",
        "comp",
        "-o",
        spirv_path,
    });

    const spirv_bytes = try std.fs.cwd().readFileAlloc(allocator, spirv_path, 4 * 1024 * 1024);

    const reflection_json = try runCommandCapture(allocator, &.{
        "spirv-cross",
        spirv_path,
        "--reflect",
    });
    defer allocator.free(reflection_json);
    const reflection = try parseReflection(allocator, reflection_json);

    const msl_entry = try std.fmt.allocPrint(allocator, "guava_{s}_compute_main", .{identifier});
    defer allocator.free(msl_entry);

    const msl_source = try runCommandCapture(allocator, &.{
        "spirv-cross",
        spirv_path,
        "--msl",
        "--rename-entry-point",
        "main",
        msl_entry,
        "comp",
    });

    return .{
        .spirv_bytes = spirv_bytes,
        .msl_bytes = msl_source,
        .reflection = reflection,
    };
}

fn parseReflection(allocator: std.mem.Allocator, source: []const u8) !Reflection {
    var json = try std.json.parseFromSlice(std.json.Value, allocator, source, .{});
    defer json.deinit();

    const object = json.value.object;
    return .{
        .num_samplers = countArrayField(object, "textures"),
        .num_storage_textures = countArrayField(object, "images"),
        .num_storage_buffers = countArrayField(object, "ssbos"),
        .num_uniform_buffers = countArrayField(object, "ubos"),
    };
}

fn countArrayField(object: std.json.ObjectMap, field_name: []const u8) u32 {
    const value = object.get(field_name) orelse return 0;
    return switch (value) {
        .array => |array| @intCast(array.items.len),
        else => 0,
    };
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) {
                return;
            }
        },
        else => {},
    }

    std.log.err("command failed: {s}\n{s}", .{ argv[0], result.stderr });
    return error.CommandFailed;
}

fn runCommandCapture(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) {
                return result.stdout;
            }
        },
        else => {},
    }

    allocator.free(result.stdout);
    std.log.err("command failed: {s}\n{s}", .{ argv[0], result.stderr });
    return error.CommandFailed;
}

fn emitByteArray(
    writer: anytype,
    identifier: []const u8,
    suffix: []const u8,
    bytes: []const u8,
) !void {
    try writer.print("const {s}_{s}_code = [_]u8{{", .{ identifier, suffix });
    for (bytes, 0..) |byte, index| {
        if (index % 12 == 0) {
            try writer.writeAll("\n    ");
        }
        try writer.print("0x{X:0>2}, ", .{byte});
    }
    try writer.writeAll("\n};\n\n");
}

fn sanitizeIdentifier(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    for (name) |char| {
        if (std.ascii.isAlphanumeric(char)) {
            try out.append(allocator, std.ascii.toLower(char));
        } else {
            try out.append(allocator, '_');
        }
    }

    if (out.items.len == 0) {
        try out.appendSlice(allocator, "shader");
    }

    return out.toOwnedSlice(allocator);
}
