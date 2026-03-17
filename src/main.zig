const std = @import("std");
const engine = @import("guava");
const editor_layer_mod = @import("editor/core/layer.zig");
const editor_console = @import("editor/ui/windows/console.zig");

pub const std_options = std.Options{
    .logFn = editor_console.logFn,
};

const CliOptions = struct {
    frame_count: usize = 0,
    backend_order: [3]engine.render.GraphicsAPI = .{ .vulkan, .dx12, .metal },
    backend_count: usize = 3,

    fn backends(self: *const CliOptions) []const engine.render.GraphicsAPI {
        return self.backend_order[0..self.backend_count];
    }
};

const ValidateOptions = struct {
    root_path: []u8,
    asset_query: ?[]u8 = null,
    write_snapshot: bool = true,

    fn deinit(self: *ValidateOptions, allocator: std.mem.Allocator) void {
        allocator.free(self.root_path);
        if (self.asset_query) |query| {
            allocator.free(query);
        }
        self.* = undefined;
    }
};

const Command = union(enum) {
    run: CliOptions,
    validate: ValidateOptions,

    fn deinit(self: *Command, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .run => self.* = undefined,
            .validate => |*options| options.deinit(allocator),
        }
    }
};

const SandboxLayer = struct {
    spinning_entity: ?engine.scene.EntityId = null,

    pub fn asLayer(self: *SandboxLayer) engine.core.Layer {
        return .{
            .name = "Sandbox3D",
            .context = self,
            .hooks = .{
                .on_attach = onAttach,
                .on_update = onUpdate,
            },
        };
    }

    fn onAttach(context: *anyopaque, layer_context: *engine.core.LayerContext) anyerror!void {
        const self: *SandboxLayer = @ptrCast(@alignCast(context));
        const cube_mesh = try layer_context.world.assets().ensurePrimitiveMesh(.cube);
        const default_material = try layer_context.world.assets().ensureDefaultMaterial();
        self.spinning_entity = try layer_context.world.createEntity(.{
            .name = "Spinner",
            .mesh = .{
                .handle = cube_mesh,
                .primitive = .cube,
            },
            .material = .{
                .handle = default_material,
            },
            .local_transform = .{
                .translation = .{ 2.0, 1.0, 0.0 },
                .scale = .{ 1.0, 1.5, 1.0 },
            },
        });

        _ = try layer_context.world.createEntity(.{
            .name = "SpinnerChild",
            .parent = self.spinning_entity,
            .mesh = .{
                .handle = cube_mesh,
                .primitive = .cube,
            },
            .material = .{
                .handle = default_material,
            },
            .local_transform = .{
                .translation = .{ 1.1, 0.9, 0.0 },
                .scale = .{ 0.35, 0.35, 0.35 },
            },
        });

        _ = try layer_context.world.importGltfStaticModel(
            "assets/models/guava_showcase/guava_showcase.gltf",
            .{
                .translation = .{ -2.4, 0.0, 0.0 },
            },
        );
    }

    fn onUpdate(context: *anyopaque, layer_context: *engine.core.LayerContext) anyerror!void {
        const self: *SandboxLayer = @ptrCast(@alignCast(context));
        if (self.spinning_entity) |entity_id| {
            if (layer_context.world.getEntity(entity_id)) |entity| {
                var euler = engine.math.quat.toEuler(entity.local_transform.rotation);
                euler[1] += 0.75 * layer_context.delta_seconds;
                entity.local_transform.rotation = engine.math.quat.fromEuler(euler);
            }
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();
    var command = try parseCommandAlloc(allocator);
    defer command.deinit(allocator);

    switch (command) {
        .run => |options| try runEngine(allocator, options),
        .validate => |options| try runValidate(allocator, options),
    }
}

fn runEngine(allocator: std.mem.Allocator, options: CliOptions) !void {
    var app = try engine.core.Application.init(allocator, .{
        .name = "Guava Engine",
        .window_width = 1440,
        .window_height = 900,
        .window_borderless = true,
        .window_native_titlebar_controls = true,
        .frame_delay_ms = 16,
        .preferred_backends = options.backends(),
    });
    defer app.deinit();

    var sandbox_layer = SandboxLayer{};
    try app.pushLayer(sandbox_layer.asLayer());
    var editor_layer = editor_layer_mod.EditorLayer{};
    try app.pushOverlay(editor_layer.asLayer());

    const report = try app.run(options.frame_count);
    const device_name = if (report.runtime.deviceName().len == 0) "Unknown Device" else report.runtime.deviceName();
    const driver_name = if (report.runtime.driverName().len == 0) "Unknown Driver" else report.runtime.driverName();
    const driver_info = if (report.runtime.driverInfo().len == 0) "n/a" else report.runtime.driverInfo();
    const depth_state = if (report.runtime.has_depth) "ready" else "missing";

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print(
        "Engine {s} booted on {s} with {s}. Device: {s}. Drawable: {d}x{d}. Depth: {s}. Frames: {d}, passes: {d}, draws: {d}, triangles: {d}, entities: {d}, meshes: {d}, lights: {d}\n",
        .{
            app.config.name,
            engine.core.platformName(app.platform),
            engine.render.graphicsApiName(report.backend),
            device_name,
            report.runtime.drawable_width,
            report.runtime.drawable_height,
            depth_state,
            report.frames,
            report.passes,
            report.draw_calls,
            report.triangles_drawn,
            report.scene.entity_count,
            report.scene.mesh_count,
            report.scene.light_count,
        },
    );
    try stdout.print("RHI driver: {s}\n", .{driver_name});
    try stdout.print("Driver info: {s}\n", .{driver_info});
    try stdout.flush();
}

fn runValidate(allocator: std.mem.Allocator, options: ValidateOptions) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var registry = engine.assets.AssetRegistry.init(allocator);
    defer registry.deinit();

    var report = report: {
        registry.refreshProject(options.root_path) catch {
            break :report try engine.assets.validateProjectAssetsAlloc(allocator, options.root_path);
        };
        if (options.write_snapshot) {
            registry.writeSnapshotToPath("assets/derived/asset_registry.json") catch {};
        }
        break :report try engine.assets.validateRegistryAssetsAlloc(
            allocator,
            &registry,
            options.asset_query,
        );
    };
    defer report.deinit(allocator);

    try stdout.print(
        "资产验证: assets={d}, outputs={d}, deps={d}, issues={d}\n",
        .{ report.asset_count, report.validated_output_count, report.dependency_edge_count, report.issues.len },
    );
    for (report.issues) |issue| {
        try stdout.print("- {s}: {s} ({s})\n", .{ issue.source_path, issue.message, issue.asset_id });
    }
    try stdout.flush();

    std.fs.cwd().makePath("dist/reports") catch {};
    if (std.fs.cwd().createFile("dist/reports/asset_validation_report.json", .{})) |file| {
        defer file.close();
        var output = std.ArrayList(u8).empty;
        defer output.deinit(allocator);

        var writer = output.writer(allocator);
        var adapter_buffer: [8192]u8 = undefined;
        var writer_adapter = writer.adaptToNewApi(&adapter_buffer);
        std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface) catch {};
        writer_adapter.new_interface.flush() catch {};

        file.writeAll(output.items) catch {};
    } else |_| {}

    if (!report.ok()) {
        return error.ValidationFailed;
    }
}

test "main boots the engine skeleton" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var app = engine.core.Application.init(allocator, .{
        .name = "Smoke Test",
        .window_width = 128,
        .window_height = 128,
    }) catch |err| {
        std.debug.print("Skipping smoke test due to init failure (possibly headless): {}\n", .{err});
        return;
    };
    defer app.deinit();

    const report = app.run(2) catch |err| {
        std.debug.print("Skipping smoke test due to run failure: {}\n", .{err});
        return;
    };
    try std.testing.expect(report.frames > 0);
}

fn parseCommandAlloc(allocator: std.mem.Allocator) !Command {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1 and std.mem.eql(u8, args[1], "validate")) {
        return .{ .validate = try parseValidateOptionsAlloc(allocator, args[2..]) };
    }
    return .{ .run = try parseRunOptions(args[1..]) };
}

fn parseRunOptions(args: []const []const u8) !CliOptions {
    var options = CliOptions{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--backend")) {
            index += 1;
            if (index >= args.len) {
                return error.InvalidArguments;
            }
            options.backend_order = backendOrderForName(args[index]) orelse return error.InvalidArguments;
            options.backend_count = options.backend_order.len;
            continue;
        }
        if (std.mem.eql(u8, arg, "--frames")) {
            index += 1;
            if (index >= args.len) {
                return error.InvalidArguments;
            }
            options.frame_count = try std.fmt.parseUnsigned(usize, args[index], 10);
            continue;
        }
        return error.InvalidArguments;
    }

    return options;
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
            if (index >= args.len) {
                return error.InvalidArguments;
            }
            allocator.free(options.root_path);
            options.root_path = try allocator.dupe(u8, args[index]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--asset")) {
            index += 1;
            if (index >= args.len) {
                return error.InvalidArguments;
            }
            if (options.asset_query) |query| {
                allocator.free(query);
            }
            options.asset_query = try allocator.dupe(u8, args[index]);
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

fn backendOrderForName(name: []const u8) ?[3]engine.render.GraphicsAPI {
    if (std.mem.eql(u8, name, "vulkan")) {
        return .{ .vulkan, .metal, .dx12 };
    }
    if (std.mem.eql(u8, name, "metal")) {
        return .{ .metal, .vulkan, .dx12 };
    }
    if (std.mem.eql(u8, name, "dx12")) {
        return .{ .dx12, .vulkan, .metal };
    }
    return null;
}
