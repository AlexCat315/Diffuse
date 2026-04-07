const std = @import("std");

pub const marker_file_name = ".guava";
pub const current_project_version: u32 = 1;
pub const default_content_dir = "Content";
pub const default_start_scene = "Content/Scenes/Main.guava_scene";
pub const default_scripts_dir = "Content/Scripts";

const PersistedProjectFile = struct {
    version: u32 = current_project_version,
    name: []const u8,
    content_dir: []const u8 = default_content_dir,
    start_scene: ?[]const u8 = default_start_scene,
    scripts_dir: []const u8 = default_scripts_dir,
};

pub const ProjectFile = struct {
    version: u32 = current_project_version,
    name: []u8,
    content_dir: []u8,
    start_scene: ?[]u8 = null,
    scripts_dir: []u8,

    pub fn deinit(self: *ProjectFile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.content_dir);
        allocator.free(self.scripts_dir);
        if (self.start_scene) |value| {
            allocator.free(value);
        }
        self.* = undefined;
    }
};

pub fn markerPathAlloc(allocator: std.mem.Allocator, project_root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ project_root, marker_file_name });
}

pub fn contentPathAlloc(allocator: std.mem.Allocator, project_root: []const u8, project: *const ProjectFile) ![]u8 {
    return std.fs.path.join(allocator, &.{ project_root, project.content_dir });
}

pub fn projectExistsAlloc(allocator: std.mem.Allocator, project_root: []const u8) !bool {
    const marker_path = try markerPathAlloc(allocator, project_root);
    defer allocator.free(marker_path);
    return pathExists(marker_path);
}

pub fn loadAlloc(allocator: std.mem.Allocator, project_root: []const u8) !ProjectFile {
    const marker_path = try markerPathAlloc(allocator, project_root);
    defer allocator.free(marker_path);

    const encoded = try std.fs.cwd().readFileAlloc(allocator, marker_path, 1024 * 1024);
    defer allocator.free(encoded);

    var parsed = try std.json.parseFromSlice(PersistedProjectFile, allocator, encoded, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const doc = parsed.value;
    if (doc.version != current_project_version) {
        return error.UnsupportedProjectVersion;
    }
    if (std.mem.trim(u8, doc.name, " \t\r\n").len == 0) {
        return error.InvalidProjectFile;
    }
    if (std.mem.trim(u8, doc.content_dir, " \t\r\n").len == 0) {
        return error.InvalidProjectFile;
    }

    return .{
        .version = doc.version,
        .name = try allocator.dupe(u8, doc.name),
        .content_dir = try allocator.dupe(u8, doc.content_dir),
        .start_scene = if (doc.start_scene) |value| try allocator.dupe(u8, value) else null,
        .scripts_dir = try allocator.dupe(u8, doc.scripts_dir),
    };
}

pub fn createNewAlloc(allocator: std.mem.Allocator, project_root: []const u8, project_name: []const u8) !ProjectFile {
    if (try projectExistsAlloc(allocator, project_root)) {
        return error.ProjectAlreadyExists;
    }
    return initializeAlloc(allocator, project_root, project_name);
}

pub fn initializeAlloc(allocator: std.mem.Allocator, project_root: []const u8, project_name: []const u8) !ProjectFile {
    if (!isValidProjectName(project_name)) {
        return error.InvalidProjectName;
    }

    try std.fs.cwd().makePath(project_root);

    const content_path = try std.fs.path.join(allocator, &.{ project_root, default_content_dir });
    defer allocator.free(content_path);
    try std.fs.cwd().makePath(content_path);

    const scenes_path = try std.fs.path.join(allocator, &.{ project_root, default_content_dir, "Scenes" });
    defer allocator.free(scenes_path);
    try std.fs.cwd().makePath(scenes_path);

    const derived_path = try std.fs.path.join(allocator, &.{ project_root, "Derived" });
    defer allocator.free(derived_path);
    try std.fs.cwd().makePath(derived_path);

    const scripts_path = try std.fs.path.join(allocator, &.{ project_root, default_scripts_dir });
    defer allocator.free(scripts_path);
    try std.fs.cwd().makePath(scripts_path);

    const marker_path = try markerPathAlloc(allocator, project_root);
    defer allocator.free(marker_path);

    const payload = try stringifyAlloc(allocator, PersistedProjectFile{
        .name = project_name,
        .content_dir = default_content_dir,
        .start_scene = default_start_scene,
        .scripts_dir = default_scripts_dir,
    });
    defer allocator.free(payload);

    try std.fs.cwd().writeFile(.{
        .sub_path = marker_path,
        .data = payload,
    });

    return loadAlloc(allocator, project_root);
}

pub fn defaultProjectName(path: []const u8) []const u8 {
    const trimmed_len = trimmedPathLen(path);
    if (trimmed_len == 0) {
        return "GuavaProject";
    }

    const base_name = std.fs.path.basename(path[0..trimmed_len]);
    return if (base_name.len == 0) "GuavaProject" else base_name;
}

fn isValidProjectName(name: []const u8) bool {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    if (trimmed.len == 0) {
        return false;
    }
    if (std.mem.eql(u8, trimmed, ".") or std.mem.eql(u8, trimmed, "..")) {
        return false;
    }
    return std.mem.indexOfAny(u8, trimmed, "/\\") == null;
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn trimmedPathLen(path: []const u8) usize {
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

test "project file initialize and load roundtrip" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    const cwd = std.fs.cwd();
    var original = try cwd.openDir(".", .{});
    defer original.close();
    try temp_dir.dir.setAsCwd();
    defer original.setAsCwd() catch {};

    var project = try createNewAlloc(std.testing.allocator, "Projects/MyGame", "MyGame");
    defer project.deinit(std.testing.allocator);

    try std.testing.expect(try projectExistsAlloc(std.testing.allocator, "Projects/MyGame"));
    try std.testing.expectEqualStrings("MyGame", project.name);
    try std.testing.expectEqualStrings(default_content_dir, project.content_dir);
    try std.testing.expectEqualStrings(default_start_scene, project.start_scene.?);

    var loaded = try loadAlloc(std.testing.allocator, "Projects/MyGame");
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings(project.name, loaded.name);
    try std.testing.expectEqualStrings(project.content_dir, loaded.content_dir);
    try std.testing.expectEqualStrings(project.start_scene.?, loaded.start_scene.?);
}

test "default project name ignores trailing separators" {
    try std.testing.expectEqualStrings("Demo", defaultProjectName("/tmp/Demo/"));
    try std.testing.expectEqualStrings("GuavaProject", defaultProjectName("/"));
}
