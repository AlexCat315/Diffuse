const std = @import("std");
const citron = @import("citron");
const build_options = @import("build_options");
const templates = @import("project_templates.zig");

const globals = citron.globals;

pub const engine_port: u16 = 9100;

pub const RecentProject = struct {
    path: []const u8,
    name: []const u8,
    lastOpened: []const u8,
};

pub const AppState = struct {
    allocator: std.mem.Allocator,
    current_project_path: ?[]u8 = null,
    engine_child: ?std.process.Child = null,

    pub fn init(allocator: std.mem.Allocator) AppState {
        return .{ .allocator = allocator };
    }

    pub fn appMode(self: *const AppState) []const u8 {
        return if (self.current_project_path != null) "editor" else "launcher";
    }

    pub fn bootstrapFromArgs(self: *AppState, args: []const [*:0]const u8) void {
        var index: usize = 0;
        while (index + 1 < args.len) : (index += 1) {
            const arg = std.mem.sliceTo(args[index], 0);
            if (std.mem.eql(u8, arg, "--project-path")) {
                const project_path = std.mem.sliceTo(args[index + 1], 0);
                self.setCurrentProjectPath(project_path) catch {};
                return;
            }
        }
    }

    pub fn startInitialProject(self: *AppState) !void {
        if (self.current_project_path != null) {
            try self.startEngine();
        }
    }

    pub fn setCurrentProjectPath(self: *AppState, project_path: []const u8) !void {
        if (self.current_project_path) |existing| {
            self.allocator.free(existing);
        }
        self.current_project_path = try self.allocator.dupe(u8, project_path);
    }

    pub fn resolveProjectPath(self: *const AppState, allocator: std.mem.Allocator, relative_path: []const u8) ![]u8 {
        const root = self.current_project_path orelse return error.NoProjectOpen;
        if (relative_path.len == 0) return error.InvalidPath;
        if (std.fs.path.isAbsolute(relative_path)) return error.InvalidPath;
        if (std.mem.indexOf(u8, relative_path, "..") != null) return error.InvalidPath;
        return std.fs.path.join(allocator, &.{ root, relative_path });
    }

    pub fn isGuavaProject(self: *const AppState, project_path: []const u8) bool {
        const marker = std.fs.path.join(self.allocator, &.{ project_path, ".guava" }) catch return false;
        defer self.allocator.free(marker);
        std.Io.Dir.cwd().access(globals.global_io, marker, .{}) catch return false;
        return true;
    }

    pub fn readProjectName(_: *const AppState, allocator: std.mem.Allocator, project_path: []const u8) ![]u8 {
        const marker = try std.fs.path.join(allocator, &.{ project_path, ".guava" });
        defer allocator.free(marker);

        const bytes = std.Io.Dir.cwd().readFileAlloc(globals.global_io, marker, allocator, .limited(1024 * 1024)) catch {
            return allocator.dupe(u8, std.fs.path.basename(project_path));
        };
        defer allocator.free(bytes);

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch {
            return allocator.dupe(u8, std.fs.path.basename(project_path));
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            if (parsed.value.object.get("name")) |name_val| {
                if (name_val == .string and name_val.string.len > 0) {
                    return allocator.dupe(u8, name_val.string);
                }
            }
        }
        return allocator.dupe(u8, std.fs.path.basename(project_path));
    }

    pub fn createProject(self: *AppState, allocator: std.mem.Allocator, project_path: []const u8, project_name: []const u8, template_id: []const u8) !void {
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), globals.global_io, project_path);

        const scenes_dir = try std.fs.path.join(allocator, &.{ project_path, "Content", "Scenes" });
        defer allocator.free(scenes_dir);
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), globals.global_io, scenes_dir);

        const scripts_dir = try std.fs.path.join(allocator, &.{ project_path, "Content", "Scripts" });
        defer allocator.free(scripts_dir);
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), globals.global_io, scripts_dir);

        const derived_dir = try std.fs.path.join(allocator, &.{ project_path, "Derived" });
        defer allocator.free(derived_dir);
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), globals.global_io, derived_dir);

        const marker_path = try std.fs.path.join(allocator, &.{ project_path, ".guava" });
        defer allocator.free(marker_path);

        const marker_json = try std.json.Stringify.valueAlloc(allocator, .{
            .version = @as(i32, 1),
            .name = project_name,
            .content_dir = "Content",
            .start_scene = "Content/Scenes/Main.guava_scene",
            .scripts_dir = "Content/Scripts",
        }, .{ .whitespace = .indent_2 });
        defer allocator.free(marker_json);

        try std.Io.Dir.writeFile(std.Io.Dir.cwd(), globals.global_io, .{
            .sub_path = marker_path,
            .data = marker_json,
        });

        try self.applyTemplate(allocator, project_path, template_id);
        try self.addRecentProject(project_path, project_name);
        try self.setCurrentProjectPath(project_path);
        try self.startEngine();
    }

    pub fn openProject(self: *AppState, allocator: std.mem.Allocator, project_path: []const u8) !void {
        if (!self.isGuavaProject(project_path)) return error.InvalidProject;
        const project_name = try self.readProjectName(allocator, project_path);
        defer allocator.free(project_name);
        try self.addRecentProject(project_path, project_name);
        try self.setCurrentProjectPath(project_path);
        try self.startEngine();
    }

    fn applyTemplate(self: *AppState, allocator: std.mem.Allocator, project_path: []const u8, template_id: []const u8) !void {
        _ = self;

        const scene_path = try std.fs.path.join(allocator, &.{ project_path, "Content", "Scenes", "Main.guava_scene" });
        defer allocator.free(scene_path);

        const scene_data = if (std.mem.eql(u8, template_id, "3d-basic")) templates.basic_scene_json else templates.empty_scene_json;
        try std.Io.Dir.writeFile(std.Io.Dir.cwd(), globals.global_io, .{
            .sub_path = scene_path,
            .data = scene_data,
        });

        if (std.mem.eql(u8, template_id, "3d-basic")) {
            const script_path = try std.fs.path.join(allocator, &.{ project_path, "Content", "Scripts", "rotate.zig" });
            defer allocator.free(script_path);
            try std.Io.Dir.writeFile(std.Io.Dir.cwd(), globals.global_io, .{
                .sub_path = script_path,
                .data = templates.starter_script,
            });
        }
    }

    pub fn startEngine(self: *AppState) !void {
        const project_path = self.current_project_path orelse return error.NoProjectOpen;
        self.stopEngine();

        const engine_binary = try self.resolveEngineBinaryPath(self.allocator);
        defer self.allocator.free(engine_binary);

        const argv = [_][]const u8{
            engine_binary,
            "--editor-server",
            "--editor-port",
            "9100",
            "--project-path",
            project_path,
        };

        self.engine_child = try std.process.spawn(globals.global_io, .{
            .argv = &argv,
            .cwd = .{ .path = std.fs.path.dirname(engine_binary) orelse "." },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
    }

    pub fn stopEngine(self: *AppState) void {
        if (self.engine_child) |*child| {
            child.kill(globals.global_io);
            self.engine_child = null;
        }
    }

    fn resolveEngineBinaryPath(self: *const AppState, allocator: std.mem.Allocator) ![]u8 {
        _ = self;

        const exe_dir = std.fs.path.dirname(globals.exe_path) orelse ".";
        const bundled = try std.fs.path.join(allocator, &.{ exe_dir, "..", "Resources", "guava-engine" });
        if (std.Io.Dir.cwd().access(globals.global_io, bundled, .{})) |_| {
            return bundled;
        } else |_| {
            allocator.free(bundled);
        }

        return allocator.dupe(u8, build_options.engine_binary_fallback);
    }

    pub fn loadRecentProjects(self: *const AppState, allocator: std.mem.Allocator) !std.json.Parsed([]RecentProject) {
        const file_path = try self.recentProjectsFilePath(allocator);
        defer allocator.free(file_path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(globals.global_io, file_path, allocator, .limited(1024 * 1024)) catch {
            return emptyRecentProjects(allocator);
        };
        defer allocator.free(bytes);

        return std.json.parseFromSlice([]RecentProject, allocator, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        }) catch {
            return emptyRecentProjects(allocator);
        };
    }

    pub fn addRecentProject(self: *const AppState, project_path: []const u8, project_name: []const u8) !void {
        var loaded = try self.loadRecentProjects(self.allocator);
        defer loaded.deinit();

        var projects = std.ArrayList(RecentProject).empty;
        defer {
            for (projects.items) |item| {
                self.allocator.free(item.path);
                self.allocator.free(item.name);
                self.allocator.free(item.lastOpened);
            }
            projects.deinit(self.allocator);
        }

        const now = try currentIsoTimestamp(self.allocator);
        try projects.append(self.allocator, .{
            .path = try self.allocator.dupe(u8, project_path),
            .name = try self.allocator.dupe(u8, project_name),
            .lastOpened = now,
        });

        for (loaded.value) |project| {
            if (std.mem.eql(u8, project.path, project_path)) continue;
            if (projects.items.len >= 20) break;
            try projects.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, project.path),
                .name = try self.allocator.dupe(u8, project.name),
                .lastOpened = try self.allocator.dupe(u8, project.lastOpened),
            });
        }

        try self.saveRecentProjects(projects.items);
    }

    pub fn removeRecentProject(self: *const AppState, project_path: []const u8) !void {
        var loaded = try self.loadRecentProjects(self.allocator);
        defer loaded.deinit();

        var projects = std.ArrayList(RecentProject).empty;
        defer {
            for (projects.items) |item| {
                self.allocator.free(item.path);
                self.allocator.free(item.name);
                self.allocator.free(item.lastOpened);
            }
            projects.deinit(self.allocator);
        }

        for (loaded.value) |project| {
            if (std.mem.eql(u8, project.path, project_path)) continue;
            try projects.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, project.path),
                .name = try self.allocator.dupe(u8, project.name),
                .lastOpened = try self.allocator.dupe(u8, project.lastOpened),
            });
        }

        try self.saveRecentProjects(projects.items);
    }

    fn saveRecentProjects(self: *const AppState, projects: []const RecentProject) !void {
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, projects, .{ .whitespace = .indent_2 });
        defer self.allocator.free(encoded);

        const file_path = try self.recentProjectsFilePath(self.allocator);
        defer self.allocator.free(file_path);

        const parent = std.fs.path.dirname(file_path) orelse return error.InvalidPath;
        try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), globals.global_io, parent);
        try std.Io.Dir.writeFile(std.Io.Dir.cwd(), globals.global_io, .{
            .sub_path = file_path,
            .data = encoded,
        });
    }

    fn recentProjectsFilePath(self: *const AppState, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        const home_c = std.c.getenv("HOME") orelse return error.HomeNotFound;
        const home = std.mem.span(home_c);
        return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "guava-editor", "recent-projects.json" });
    }
};

fn emptyRecentProjects(allocator: std.mem.Allocator) !std.json.Parsed([]RecentProject) {
    return std.json.parseFromSlice([]RecentProject, allocator, "[]", .{});
}

fn currentIsoTimestamp(allocator: std.mem.Allocator) ![]u8 {
    const result = try std.process.run(allocator, globals.global_io, .{
        .argv = &.{ "/bin/date", "-u", "+%Y-%m-%dT%H:%M:%SZ" },
        .stdout_limit = .limited(128),
        .stderr_limit = .limited(128),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, "\r\n"));
}
