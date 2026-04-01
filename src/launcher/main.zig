const builtin = @import("builtin");
const std = @import("std");
const project_mod = @import("guava_project");

const recents_file_name = "recent_projects.json";
const recents_version: u32 = 1;
const max_recent_projects: usize = 10;

const LauncherArgs = struct {
    open_path: ?[]u8 = null,
    create_path: ?[]u8 = null,
    name: ?[]u8 = null,
    engine_path: ?[]u8 = null,
    no_launch: bool = false,
    help: bool = false,

    fn deinit(self: *LauncherArgs, allocator: std.mem.Allocator) void {
        if (self.open_path) |value| allocator.free(value);
        if (self.create_path) |value| allocator.free(value);
        if (self.name) |value| allocator.free(value);
        if (self.engine_path) |value| allocator.free(value);
        self.* = undefined;
    }
};

const ProjectSelection = struct {
    root_path: []u8,
    name: []u8,

    fn deinit(self: *ProjectSelection, allocator: std.mem.Allocator) void {
        allocator.free(self.root_path);
        allocator.free(self.name);
        self.* = undefined;
    }
};

const RecentProject = struct {
    name: []u8,
    path: []u8,
    last_opened_ms: i64 = 0,

    fn deinit(self: *RecentProject, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        self.* = undefined;
    }
};

const PersistedRecentProject = struct {
    name: []const u8,
    path: []const u8,
    last_opened_ms: i64 = 0,
};

const PersistedRecents = struct {
    version: u32 = recents_version,
    projects: []const PersistedRecentProject = &.{},
};

const LauncherAction = enum {
    open_recent,
    open_existing,
    create_new,
};

fn replaceOwnedArg(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    if (slot.*) |existing| {
        allocator.free(existing);
    }
    slot.* = try allocator.dupe(u8, value);
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.process.exit(1);
        }
    }

    var args = try parseArgsAlloc(allocator);
    defer args.deinit(allocator);

    if (args.help) {
        printHelp();
        return 0;
    }

    var selection = try selectionFromArgsAlloc(allocator, &args);
    if (selection == null) {
        selection = try selectProjectInteractiveAlloc(allocator);
    }

    if (selection == null) {
        return 0;
    }
    defer selection.?.deinit(allocator);

    try rememberRecentProject(allocator, &selection.?);

    if (args.no_launch) {
        return 0;
    }

    const engine_path = if (args.engine_path) |value|
        try allocator.dupe(u8, value)
    else
        try resolveEngineExecutableAlloc(allocator);
    defer allocator.free(engine_path);

    try launchEngine(allocator, engine_path, selection.?.root_path);
    return 0;
}

fn parseArgsAlloc(allocator: std.mem.Allocator) !LauncherArgs {
    var result = LauncherArgs{};
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--open")) {
            const next = args.next() orelse return error.MissingArgument;
            try replaceOwnedArg(allocator, &result.open_path, next);
            continue;
        }
        if (std.mem.eql(u8, arg, "--create")) {
            const next = args.next() orelse return error.MissingArgument;
            try replaceOwnedArg(allocator, &result.create_path, next);
            continue;
        }
        if (std.mem.eql(u8, arg, "--name")) {
            const next = args.next() orelse return error.MissingArgument;
            try replaceOwnedArg(allocator, &result.name, next);
            continue;
        }
        if (std.mem.eql(u8, arg, "--engine")) {
            const next = args.next() orelse return error.MissingArgument;
            try replaceOwnedArg(allocator, &result.engine_path, next);
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-launch")) {
            result.no_launch = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
            continue;
        }
        return error.InvalidArguments;
    }

    if (result.open_path != null and result.create_path != null) {
        return error.InvalidArguments;
    }
    if (result.create_path == null and result.name != null) {
        return error.InvalidArguments;
    }

    return result;
}

fn selectionFromArgsAlloc(allocator: std.mem.Allocator, args: *const LauncherArgs) !?ProjectSelection {
    if (args.create_path) |create_path| {
        const project_name = args.name orelse project_mod.defaultProjectName(create_path);
        var project = try project_mod.createNewAlloc(allocator, create_path, project_name);
        defer project.deinit(allocator);
        const resolved_root = try std.fs.cwd().realpathAlloc(allocator, create_path);
        return .{
            .root_path = resolved_root,
            .name = try allocator.dupe(u8, project.name),
        };
    }

    if (args.open_path) |open_path| {
        return try selectionFromProjectRootAlloc(allocator, open_path);
    }

    return null;
}

fn selectProjectInteractiveAlloc(allocator: std.mem.Allocator) !?ProjectSelection {
    if (builtin.os.tag != .macos) {
        std.debug.print("Interactive launcher dialogs are only implemented on macOS. Use --open or --create.\n", .{});
        return error.InteractiveLauncherUnsupported;
    }

    var recents = try loadRecentProjectsAlloc(allocator);
    defer deinitRecentProjects(&recents, allocator);

    const action = chooseLauncherActionAlloc(allocator, recents.items.len > 0) catch |err| switch (err) {
        error.UserCancelled => return null,
        else => return err,
    };

    return switch (action) {
        .open_recent => try chooseRecentProjectAlloc(allocator, recents.items),
        .open_existing => try chooseExistingProjectAlloc(allocator),
        .create_new => try createProjectFromDialogAlloc(allocator),
    };
}

fn chooseLauncherActionAlloc(allocator: std.mem.Allocator, has_recents: bool) !LauncherAction {
    const recent_choices = [_][]const u8{ "Open Recent", "Open Existing", "Create Project" };
    const default_choices = [_][]const u8{ "Open Existing", "Create Project" };
    const choices: []const []const u8 = if (has_recents) recent_choices[0..] else default_choices[0..];

    const result = try chooseFromListAlloc(allocator, choices, "Open or create a Guava project");
    defer allocator.free(result);

    if (std.mem.eql(u8, result, "Open Recent")) return .open_recent;
    if (std.mem.eql(u8, result, "Open Existing")) return .open_existing;
    if (std.mem.eql(u8, result, "Create Project")) return .create_new;
    return error.InvalidLauncherState;
}

fn chooseRecentProjectAlloc(allocator: std.mem.Allocator, recents: []const RecentProject) !?ProjectSelection {
    if (recents.len == 0) {
        return try chooseExistingProjectAlloc(allocator);
    }

    const choices = try allocator.alloc([]const u8, recents.len);
    defer allocator.free(choices);
    for (recents, 0..) |recent, index| {
        choices[index] = recent.path;
    }

    const selected_path = chooseFromListAlloc(allocator, choices, "Choose a recent Guava project") catch |err| switch (err) {
        error.UserCancelled => return null,
        else => return err,
    };
    defer allocator.free(selected_path);

    return try selectionFromProjectRootAlloc(allocator, selected_path);
}

fn chooseExistingProjectAlloc(allocator: std.mem.Allocator) !?ProjectSelection {
    const selected_folder = chooseFolderAlloc(allocator, "Choose a Guava project folder") catch |err| switch (err) {
        error.UserCancelled => return null,
        else => return err,
    };
    defer allocator.free(selected_folder);

    const resolved_root = try std.fs.cwd().realpathAlloc(allocator, selected_folder);
    errdefer allocator.free(resolved_root);

    if (try project_mod.projectExistsAlloc(allocator, resolved_root)) {
        return try selectionFromResolvedProjectRootAlloc(allocator, resolved_root);
    }

    const should_initialize = confirmInitializeProjectAlloc(allocator, resolved_root) catch |err| switch (err) {
        error.UserCancelled => return null,
        else => return err,
    };
    if (!should_initialize) {
        allocator.free(resolved_root);
        return null;
    }

    const default_name = project_mod.defaultProjectName(resolved_root);
    var project = try project_mod.initializeAlloc(allocator, resolved_root, default_name);
    defer project.deinit(allocator);

    return .{
        .root_path = resolved_root,
        .name = try allocator.dupe(u8, project.name),
    };
}

fn createProjectFromDialogAlloc(allocator: std.mem.Allocator) !?ProjectSelection {
    const project_name = askProjectNameAlloc(allocator) catch |err| switch (err) {
        error.UserCancelled => return null,
        else => return err,
    };
    defer allocator.free(project_name);

    const parent_folder = chooseFolderAlloc(allocator, "Choose where to create the new Guava project") catch |err| switch (err) {
        error.UserCancelled => return null,
        else => return err,
    };
    defer allocator.free(parent_folder);

    const requested_root = try std.fs.path.join(allocator, &.{ parent_folder, project_name });
    defer allocator.free(requested_root);

    var project = try project_mod.initializeAlloc(allocator, requested_root, project_name);
    defer project.deinit(allocator);

    const resolved_root = try std.fs.cwd().realpathAlloc(allocator, requested_root);
    return .{
        .root_path = resolved_root,
        .name = try allocator.dupe(u8, project.name),
    };
}

fn askProjectNameAlloc(allocator: std.mem.Allocator) ![]u8 {
    const message = try appleScriptQuotedAlloc(allocator, "Project name:");
    defer allocator.free(message);

    const line = try std.fmt.allocPrint(allocator, "return text returned of (display dialog {s} default answer \"MyGame\")", .{message});
    defer allocator.free(line);

    const result = try runAppleScriptAlloc(allocator, &.{line});
    const trimmed = std.mem.trim(u8, result, " \t\r\n");
    if (trimmed.len == 0) {
        allocator.free(result);
        return error.InvalidProjectName;
    }

    if (trimmed.len == result.len) {
        return result;
    }

    defer allocator.free(result);
    return allocator.dupe(u8, trimmed);
}

fn confirmInitializeProjectAlloc(allocator: std.mem.Allocator, project_root: []const u8) !bool {
    const message = try std.fmt.allocPrint(allocator, "The selected folder is not a Guava project:\n\n{s}\n\nInitialize it now?", .{project_root});
    defer allocator.free(message);

    const quoted = try appleScriptQuotedAlloc(allocator, message);
    defer allocator.free(quoted);

    const line = try std.fmt.allocPrint(allocator, "return button returned of (display dialog {s} buttons {{\"Cancel\", \"Initialize\"}} default button \"Initialize\")", .{quoted});
    defer allocator.free(line);

    const result = try runAppleScriptAlloc(allocator, &.{line});
    defer allocator.free(result);
    return std.mem.eql(u8, result, "Initialize");
}

fn chooseFolderAlloc(allocator: std.mem.Allocator, prompt: []const u8) ![]u8 {
    const quoted = try appleScriptQuotedAlloc(allocator, prompt);
    defer allocator.free(quoted);

    const line = try std.fmt.allocPrint(allocator, "return POSIX path of (choose folder with prompt {s})", .{quoted});
    defer allocator.free(line);

    const result = try runAppleScriptAlloc(allocator, &.{line});
    const trimmed_len = trimTrailingSeparators(result);
    if (trimmed_len == result.len) {
        return result;
    }

    defer allocator.free(result);
    return allocator.dupe(u8, result[0..trimmed_len]);
}

fn chooseFromListAlloc(allocator: std.mem.Allocator, items: []const []const u8, prompt: []const u8) ![]u8 {
    const prompt_quoted = try appleScriptQuotedAlloc(allocator, prompt);
    defer allocator.free(prompt_quoted);

    const list_literal = try appleScriptListLiteralAlloc(allocator, items);
    defer allocator.free(list_literal);

    const default_item = try appleScriptQuotedAlloc(allocator, items[0]);
    defer allocator.free(default_item);

    const line1 = try std.fmt.allocPrint(allocator, "set projectChoices to {s}", .{list_literal});
    defer allocator.free(line1);
    const line2 = try std.fmt.allocPrint(allocator, "set picked to choose from list projectChoices with prompt {s} default items {{{s}}}", .{ prompt_quoted, default_item });
    defer allocator.free(line2);

    const result = try runAppleScriptAlloc(allocator, &.{
        line1,
        line2,
        "if picked is false then",
        "  error number -128",
        "end if",
        "return item 1 of picked",
    });
    return result;
}

fn appleScriptListLiteralAlloc(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try buffer.append(allocator, '{');
    for (items, 0..) |item, index| {
        if (index > 0) {
            try buffer.appendSlice(allocator, ", ");
        }
        const quoted = try appleScriptQuotedAlloc(allocator, item);
        defer allocator.free(quoted);
        try buffer.appendSlice(allocator, quoted);
    }
    try buffer.append(allocator, '}');
    return buffer.toOwnedSlice(allocator);
}

fn appleScriptQuotedAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    try buffer.append(allocator, '"');
    for (value) |char| {
        switch (char) {
            '"' => try buffer.appendSlice(allocator, "\\\""),
            '\\' => try buffer.appendSlice(allocator, "\\\\"),
            '\n' => try buffer.appendSlice(allocator, "\\n"),
            '\r' => {},
            else => try buffer.append(allocator, char),
        }
    }
    try buffer.append(allocator, '"');
    return buffer.toOwnedSlice(allocator);
}

fn runAppleScriptAlloc(allocator: std.mem.Allocator, lines: []const []const u8) ![]u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "osascript");
    for (lines) |line| {
        try argv.append(allocator, "-e");
        try argv.append(allocator, line);
    }

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 256 * 1024,
    });
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                if (std.mem.indexOf(u8, result.stderr, "-128") != null or std.mem.indexOf(u8, result.stderr, "User canceled") != null) {
                    return error.UserCancelled;
                }
                std.log.err("osascript failed: {s}", .{result.stderr});
                return error.AppleScriptFailed;
            }
        },
        else => {
            allocator.free(result.stdout);
            return error.AppleScriptFailed;
        },
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == result.stdout.len) {
        return result.stdout;
    }

    defer allocator.free(result.stdout);
    return allocator.dupe(u8, trimmed);
}

fn resolveEngineExecutableAlloc(allocator: std.mem.Allocator) ![]u8 {
    const exe_dir = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_dir);

    const engine_name = if (builtin.os.tag == .windows) "guava-engine.exe" else "guava-engine";
    const engine_path = try std.fs.path.join(allocator, &.{ exe_dir, engine_name });
    errdefer allocator.free(engine_path);

    try std.fs.accessAbsolute(engine_path, .{});
    return engine_path;
}

fn launchEngine(allocator: std.mem.Allocator, engine_path: []const u8, project_root: []const u8) !void {
    const argv = [_][]const u8{
        engine_path,
        "--project-path",
        project_root,
    };

    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
}

fn selectionFromProjectRootAlloc(allocator: std.mem.Allocator, project_root: []const u8) !ProjectSelection {
    const resolved_root = try std.fs.cwd().realpathAlloc(allocator, project_root);
    return selectionFromResolvedProjectRootAlloc(allocator, resolved_root);
}

fn selectionFromResolvedProjectRootAlloc(allocator: std.mem.Allocator, resolved_root: []u8) !ProjectSelection {
    errdefer allocator.free(resolved_root);

    var project = try project_mod.loadAlloc(allocator, resolved_root);
    defer project.deinit(allocator);

    return .{
        .root_path = resolved_root,
        .name = try allocator.dupe(u8, project.name),
    };
}

fn loadRecentProjectsAlloc(allocator: std.mem.Allocator) !std.ArrayList(RecentProject) {
    var recents = std.ArrayList(RecentProject).empty;

    const recents_path = try recentProjectsPathAlloc(allocator);
    defer allocator.free(recents_path);

    const encoded = std.fs.cwd().readFileAlloc(allocator, recents_path, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return recents,
        else => return err,
    };
    defer allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(PersistedRecents, allocator, encoded, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value.version != recents_version) {
        return recents;
    }

    for (parsed.value.projects) |entry| {
        if (!try project_mod.projectExistsAlloc(allocator, entry.path)) {
            continue;
        }
        try recents.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .path = try allocator.dupe(u8, entry.path),
            .last_opened_ms = entry.last_opened_ms,
        });
        if (recents.items.len >= max_recent_projects) {
            break;
        }
    }

    return recents;
}

fn rememberRecentProject(allocator: std.mem.Allocator, selection: *const ProjectSelection) !void {
    var existing = try loadRecentProjectsAlloc(allocator);
    defer deinitRecentProjects(&existing, allocator);

    var merged = std.ArrayList(RecentProject).empty;
    defer deinitRecentProjects(&merged, allocator);

    try merged.append(allocator, .{
        .name = try allocator.dupe(u8, selection.name),
        .path = try allocator.dupe(u8, selection.root_path),
        .last_opened_ms = currentTimeMs(),
    });

    for (existing.items) |entry| {
        if (std.mem.eql(u8, entry.path, selection.root_path)) {
            continue;
        }
        if (merged.items.len >= max_recent_projects) {
            break;
        }
        try merged.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .path = try allocator.dupe(u8, entry.path),
            .last_opened_ms = entry.last_opened_ms,
        });
    }

    try saveRecentProjects(allocator, merged.items);
}

fn saveRecentProjects(allocator: std.mem.Allocator, recents: []const RecentProject) !void {
    var persisted = std.ArrayList(PersistedRecentProject).empty;
    defer persisted.deinit(allocator);

    for (recents) |entry| {
        try persisted.append(allocator, .{
            .name = entry.name,
            .path = entry.path,
            .last_opened_ms = entry.last_opened_ms,
        });
    }

    const payload = try stringifyAlloc(allocator, PersistedRecents{
        .projects = persisted.items,
    });
    defer allocator.free(payload);

    const recents_path = try recentProjectsPathAlloc(allocator);
    defer allocator.free(recents_path);

    if (std.fs.path.dirname(recents_path)) |dir_path| {
        try std.fs.cwd().makePath(dir_path);
    }

    try std.fs.cwd().writeFile(.{
        .sub_path = recents_path,
        .data = payload,
    });
}

fn recentProjectsPathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const support_dir = try launcherSupportDirAlloc(allocator);
    defer allocator.free(support_dir);
    return std.fs.path.join(allocator, &.{ support_dir, recents_file_name });
}

fn launcherSupportDirAlloc(allocator: std.mem.Allocator) ![]u8 {
    switch (builtin.os.tag) {
        .macos => {
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "Guava Engine", "Launcher" });
        },
        .windows => {
            const app_data = try std.process.getEnvVarOwned(allocator, "APPDATA");
            defer allocator.free(app_data);
            return std.fs.path.join(allocator, &.{ app_data, "Guava Engine", "Launcher" });
        },
        else => {
            const xdg_data = std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME") catch null;
            if (xdg_data) |value| {
                defer allocator.free(value);
                return std.fs.path.join(allocator, &.{ value, "Guava Engine", "Launcher" });
            }
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, ".local", "share", "Guava Engine", "Launcher" });
        },
    }
}

fn deinitRecentProjects(recents: *std.ArrayList(RecentProject), allocator: std.mem.Allocator) void {
    for (recents.items) |*entry| {
        entry.deinit(allocator);
    }
    recents.deinit(allocator);
    recents.* = .empty;
}

fn currentTimeMs() i64 {
    return @intCast(@divTrunc(std.time.nanoTimestamp(), std.time.ns_per_ms));
}

fn trimTrailingSeparators(path: []const u8) usize {
    var end = path.len;
    while (end > 1 and (path[end - 1] == '/' or path[end - 1] == '\\')) {
        end -= 1;
    }
    return end;
}

fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var writer = output.writer(allocator);
    var adapter_buffer: [2048]u8 = undefined;
    var writer_adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();
    if (writer_adapter.err) |err| {
        return err;
    }
    return output.toOwnedSlice(allocator);
}

fn printHelp() void {
    std.debug.print(
        "Guava Launcher\n" ++
            "  --open <path>      Open an existing Guava project\n" ++
            "  --create <path>    Create a new Guava project at the target path\n" ++
            "  --name <name>      Project name used with --create\n" ++
            "  --engine <path>    Override the engine executable path\n" ++
            "  --no-launch        Prepare the project but do not launch the editor\n" ++
            "  --help             Show this help text\n",
        .{},
    );
}
