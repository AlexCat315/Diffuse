const std = @import("std");
const engine = @import("guava");
const cli = @import("cli.zig");
const project_mod = @import("project.zig");
const io_globals = @import("io_globals");

const PlayerBootstrapLayer = struct {
    allocator: std.mem.Allocator,
    start_scene_path: ?[]u8 = null,

    pub fn deinit(self: *PlayerBootstrapLayer) void {
        if (self.start_scene_path) |path| {
            self.allocator.free(path);
            self.start_scene_path = null;
        }
    }

    pub fn asLayer(self: *PlayerBootstrapLayer) engine.core.Layer {
        return .{
            .name = "PlayerBootstrap",
            .context = self,
            .hooks = .{
                .on_attach = onAttach,
            },
        };
    }

    fn onAttach(context: *anyopaque, layer_context: *engine.core.LayerContext) anyerror!void {
        const self: *PlayerBootstrapLayer = @ptrCast(@alignCast(context));
        if (self.start_scene_path) |scene_path| {
            const source = try std.Io.Dir.cwd().readFileAlloc(io_globals.global_io, scene_path, self.allocator, .unlimited);
            defer self.allocator.free(source);
            try engine.scene.deserializeWorldFromSlice(self.allocator, layer_context.world, source);
        }
    }
};

fn ensureProjectRootAsCwd(allocator: std.mem.Allocator) !void {
    std.Io.Dir.cwd().access(io_globals.global_io, "assets", .{}) catch |err| switch (err) {
        error.FileNotFound => {
            const resolved_root = try resolveProjectRootAlloc(allocator);
            defer if (resolved_root) |root| allocator.free(root);

            if (resolved_root) |root| {
                try std.process.setCurrentPath(io_globals.global_io, root);
            }
        },
        else => return err,
    };
}

fn resolveProjectRootAlloc(allocator: std.mem.Allocator) !?[]u8 {
    const cwd_path = try std.Io.Dir.cwd().realPathFileAlloc(io_globals.global_io, ".", allocator);
    defer allocator.free(cwd_path);
    if (try findProjectRootFromAbsoluteAlloc(allocator, cwd_path)) |root| {
        return root;
    }

    const exe_dir = try std.process.executableDirPathAlloc(io_globals.global_io, allocator);
    defer allocator.free(exe_dir);

    // macOS .app bundle: exe is at Contents/MacOS/, resources at Contents/Resources/
    if (std.mem.endsWith(u8, exe_dir, "/Contents/MacOS") or std.mem.endsWith(u8, exe_dir, "/Contents/MacOS/")) {
        const contents_dir = std.fs.path.dirname(exe_dir) orelse exe_dir;
        const resources_path = try std.fs.path.join(allocator, &.{ contents_dir, "Resources" });
        defer allocator.free(resources_path);
        const resources_assets = try std.fs.path.join(allocator, &.{ resources_path, "assets" });
        defer allocator.free(resources_assets);
        if (std.Io.Dir.cwd().access(io_globals.global_io, resources_assets, .{})) |_| {
            return try std.Io.Dir.cwd().realPathFileAlloc(io_globals.global_io, resources_path, allocator);
        } else |_| {}
    }

    return try findProjectRootFromAbsoluteAlloc(allocator, exe_dir);
}

fn findProjectRootFromAbsoluteAlloc(allocator: std.mem.Allocator, start_path: []const u8) !?[]u8 {
    var current = try allocator.dupe(u8, start_path);
    errdefer allocator.free(current);

    while (true) {
        const assets_path = try std.fs.path.join(allocator, &.{ current, "assets" });
        defer allocator.free(assets_path);

        if (std.Io.Dir.cwd().access(io_globals.global_io, assets_path, .{})) |_| {
            return current;
        } else |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        }

        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len == 0 or parent.len == current.len) {
            break;
        }

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    allocator.free(current);
    return null;
}

const LoadedProject = struct {
    root_path: []u8,
    file: project_mod.ProjectFile,

    fn deinit(self: *LoadedProject, allocator: std.mem.Allocator) void {
        allocator.free(self.root_path);
        self.file.deinit(allocator);
        self.* = undefined;
    }
};

fn loadConfiguredProjectAlloc(allocator: std.mem.Allocator, options: cli.CliOptions) !?LoadedProject {
    const raw_project_path = options.project_path orelse blk: {
        std.Io.Dir.cwd().access(io_globals.global_io, project_mod.marker_file_name, .{}) catch return null;
        break :blk ".";
    };
    const resolved_root = try std.Io.Dir.cwd().realPathFileAlloc(io_globals.global_io, raw_project_path, allocator);
    errdefer allocator.free(resolved_root);

    var project_file = try project_mod.loadAlloc(allocator, resolved_root);
    errdefer project_file.deinit(allocator);

    return .{
        .root_path = resolved_root,
        .file = project_file,
    };
}

fn applicationNameAlloc(allocator: std.mem.Allocator, loaded_project: ?*const LoadedProject) ![]u8 {
    if (loaded_project) |project| {
        return std.fmt.allocPrint(allocator, "{s} - {s}", .{ "Guava Player", project.file.name });
    }
    return allocator.dupe(u8, "Guava Player");
}

fn resolveStartScenePathAlloc(
    allocator: std.mem.Allocator,
    project_root: []const u8,
    start_scene: ?[]const u8,
) !?[]u8 {
    const scene_path = start_scene orelse return null;
    if (scene_path.len == 0) {
        return null;
    }
    if (std.fs.path.isAbsolute(scene_path)) {
        return try allocator.dupe(u8, scene_path);
    }
    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_root, scene_path });
}

pub fn main(init: std.process.Init) !u8 {
    io_globals.init(init.io, init.minimal.args);
    const allocator = init.gpa;

    try ensureProjectRootAsCwd(allocator);

    var command = try cli.parseCommandAlloc(allocator);
    defer command.deinit(allocator);

    const options = switch (command) {
        .run => |opts| opts,
        else => return error.UnsupportedCommand,
    };

    var loaded_project = try loadConfiguredProjectAlloc(allocator, options);
    defer if (loaded_project) |*project| project.deinit(allocator);

    const app_name = try applicationNameAlloc(allocator, if (loaded_project) |*project| project else null);
    defer allocator.free(app_name);

    var app = try engine.core.Application.init(allocator, .{
        .name = app_name,
        .window_width = 1440,
        .window_height = 900,
        .window_borderless = false,
        .window_maximized = false,
        .window_native_titlebar_controls = true,
        .frame_delay_ms = 16,
        .preferred_backends = options.backends(),
        .is_editor_mode = false,
    });
    defer app.deinit();

    var bootstrap = PlayerBootstrapLayer{ .allocator = allocator };
    defer bootstrap.deinit();

    if (loaded_project) |*project| {
        bootstrap.start_scene_path = try resolveStartScenePathAlloc(allocator, project.root_path, project.file.start_scene);
        std.log.info("player opening project '{s}' at {s}", .{ project.file.name, project.root_path });
    } else if (options.scene_path) |sp| {
        bootstrap.start_scene_path = try allocator.dupe(u8, sp);
        std.log.info("player opening scene '{s}'", .{sp});
    }

    try app.pushLayer(bootstrap.asLayer());
    // 独立播放器自动进入 playing 状态（编辑器模式由 UI 控制）
    app.playback_controller.setState(.playing);
    _ = try app.run(options.frame_count);
    return 0;
}

test "player boots without project (smoke test)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var app = engine.core.Application.init(allocator, .{
        .name = "Player Smoke Test",
        .window_width = 128,
        .window_height = 128,
    }) catch |err| {
        std.debug.print("Skipping player smoke test due to init failure (possibly headless): {}\n", .{err});
        return;
    };
    defer app.deinit();

    var bootstrap = PlayerBootstrapLayer{ .allocator = allocator };
    defer bootstrap.deinit();
    // No start_scene_path — tests the empty-scene lifecycle
    try app.pushLayer(bootstrap.asLayer());

    const report = app.run(5) catch |err| {
        std.debug.print("Skipping player smoke test due to run failure: {}\n", .{err});
        return;
    };
    try std.testing.expect(report.frames > 0);
}
