//! CLI 命令解析模块
//!
//! 处理命令行参数解析，定义所有可用命令和选项类型。

const std = @import("std");
const engine = @import("guava");

pub const McpTransport = enum {
    stdio,
};

pub const CliOptions = struct {
    frame_count: usize = 0,
    backend_order: [3]engine.render.GraphicsAPI = engine.render.defaultBackendOrder(),
    backend_count: usize = 3,
    mcp_enabled: bool = false,
    mcp_transport: McpTransport = .stdio,

    pub fn backends(self: *const CliOptions) []const engine.render.GraphicsAPI {
        return self.backend_order[0..self.backend_count];
    }
};

pub const ValidateOptions = struct {
    root_path: []u8,
    asset_query: ?[]u8 = null,
    write_snapshot: bool = true,

    pub fn deinit(self: *ValidateOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.root_path);
        if (self.asset_query) |query| {
            allocator.free(query);
        }
        self.* = undefined;
    }
};

pub const Command = union(enum) {
    run: CliOptions,
    validate: ValidateOptions,
    benchmark: struct {
        scene_path: []const u8,
        update_golden: bool = false,
        allocated: bool = false,
    },
    @"generate-benchmark": struct {
        output_path: []const u8,
        allocated: bool = false,
    },
    @"compare-render": struct {
        scene_path: []const u8,
        output_dir: []const u8,
        allocated: bool = false,
    },

    pub fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .run => self.* = undefined,
            .validate => |*options| options.deinit(allocator),
            .benchmark => |options| if (options.allocated) allocator.free(options.scene_path),
            .@"generate-benchmark" => |options| if (options.allocated) allocator.free(options.output_path),
            .@"compare-render" => |options| if (options.allocated) {
                allocator.free(options.scene_path);
                allocator.free(options.output_dir);
            },
        }
    }
};

pub fn parseCommandAlloc(allocator: std.mem.Allocator) !Command {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next(); // skip program name

    const command_name = args.next();
    if (command_name == null) {
        return .{ .run = try parseRunOptions(&.{}) };
    }

    if (std.mem.eql(u8, command_name.?, "validate")) {
        var remaining = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer remaining.deinit(allocator);
        while (args.next()) |arg| {
            try remaining.append(allocator, arg);
        }
        return .{ .validate = try parseValidateOptionsAlloc(allocator, remaining.items) };
    }

    if (std.mem.eql(u8, command_name.?, "mcp")) {
        var remaining = try std.ArrayList([]const u8).initCapacity(allocator, 0);
        defer remaining.deinit(allocator);
        try remaining.append(allocator, "--mcp");
        while (args.next()) |arg| {
            try remaining.append(allocator, arg);
        }
        return .{ .run = try parseRunOptions(remaining.items) };
    }

    if (std.mem.eql(u8, command_name.?, "benchmark")) {
        var scene_path: []const u8 = "assets/benchmarks/material_p0.json";
        var update_golden = false;
        while (args.next()) |arg| {
            if (std.mem.eql(u8, arg, "--scene")) {
                const next_arg = args.next();
                if (next_arg) |next| {
                    scene_path = next;
                } else {
                    return error.MissingArgument;
                }
            } else if (std.mem.eql(u8, arg, "--update-golden")) {
                update_golden = true;
            } else {
                return error.InvalidArgument;
            }
        }
        return .{ .benchmark = .{
            .scene_path = try allocator.dupe(u8, scene_path),
            .update_golden = update_golden,
            .allocated = true,
        } };
    }

    if (std.mem.eql(u8, command_name.?, "generate-benchmark")) {
        const output_path_arg = args.next();
        const output_path = if (output_path_arg) |path| path else "assets/scenes/benchmark_p0.json";
        if (args.next()) |extra| {
            std.debug.print("Unexpected argument: {s}\n", .{extra});
            return error.InvalidArgument;
        }
        return .{ .@"generate-benchmark" = .{
            .output_path = try allocator.dupe(u8, output_path),
            .allocated = output_path_arg != null,
        } };
    }

    if (std.mem.eql(u8, command_name.?, "compare-render")) {
        const scene_path_arg = args.next();
        const output_dir_arg = args.next();
        const scene_path = if (scene_path_arg) |path| path else "assets/scenes/benchmark_p0.json";
        const output_dir = if (output_dir_arg) |dir| dir else "dist/reports/render_comparison";
        if (args.next()) |extra| {
            std.debug.print("Unexpected argument: {s}\n", .{extra});
            return error.InvalidArgument;
        }
        return .{ .@"compare-render" = .{
            .scene_path = try allocator.dupe(u8, scene_path),
            .output_dir = try allocator.dupe(u8, output_dir),
            .allocated = true,
        } };
    }

    var run_args = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer run_args.deinit(allocator);
    try run_args.append(allocator, command_name.?);
    while (args.next()) |arg| {
        try run_args.append(allocator, arg);
    }
    return .{ .run = try parseRunOptions(run_args.items) };
}

fn parseRunOptions(args: []const []const u8) !CliOptions {
    var options = CliOptions{};
    var transport_specified = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--mcp")) {
            options.mcp_enabled = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--backend")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.backend_order = backendOrderForName(args[index]) orelse return error.InvalidArguments;
            options.backend_count = options.backend_order.len;
            continue;
        }
        if (std.mem.eql(u8, arg, "--frames")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.frame_count = try std.fmt.parseUnsigned(usize, args[index], 10);
            continue;
        }
        if (std.mem.eql(u8, arg, "--transport")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            options.mcp_transport = parseMcpTransport(args[index]) orelse return error.InvalidArguments;
            transport_specified = true;
            continue;
        }
        return error.InvalidArguments;
    }
    if (transport_specified and !options.mcp_enabled) return error.InvalidArguments;
    return options;
}

fn parseMcpTransport(name: []const u8) ?McpTransport {
    if (std.mem.eql(u8, name, "stdio")) return .stdio;
    return null;
}

fn parseValidateOptionsAlloc(allocator: std.mem.Allocator, args: []const []const u8) !ValidateOptions {
    var options = ValidateOptions{
        .root_path = try allocator.dupe(u8, "assets"),
    };
    errdefer options.deinit(allocator);

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--root")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            const next_root_path = try allocator.dupe(u8, args[index]);
            allocator.free(options.root_path);
            options.root_path = next_root_path;
            continue;
        }
        if (std.mem.eql(u8, arg, "--asset")) {
            index += 1;
            if (index >= args.len) return error.InvalidArguments;
            const next_query = try allocator.dupe(u8, args[index]);
            if (options.asset_query) |query| allocator.free(query);
            options.asset_query = next_query;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-snapshot")) {
            options.write_snapshot = false;
            continue;
        }
        return error.InvalidArguments;
    }
    return options;
}

pub fn backendOrderForName(name: []const u8) ?[3]engine.render.GraphicsAPI {
    if (std.mem.eql(u8, name, "vulkan")) return .{ .vulkan, .metal, .dx12 };
    if (std.mem.eql(u8, name, "metal")) return .{ .metal, .vulkan, .dx12 };
    if (std.mem.eql(u8, name, "dx12")) return .{ .dx12, .vulkan, .metal };
    return null;
}
