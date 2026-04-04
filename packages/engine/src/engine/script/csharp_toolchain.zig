const builtin = @import("builtin");
const std = @import("std");

pub const PublishError = error{
    DotnetNotFound,
    UnsupportedPlatform,
    PublishFailed,
    ArtifactNotFound,
};

pub const PublishOptions = struct {
    project_path: []const u8,
    output_dir: ?[]const u8 = null,
    configuration: []const u8 = "Release",
    publish_aot: bool = true,
    native_lib: []const u8 = "Shared",
    self_contained: bool = true,
};

pub fn isDotnetProjectPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".csproj");
}

pub fn isCSharpSourcePath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".cs");
}

pub fn isSharedLibraryPath(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".dll") or
        std.mem.endsWith(u8, path, ".so") or
        std.mem.endsWith(u8, path, ".dylib");
}

pub fn findDotnetBinary(allocator: std.mem.Allocator) !?[]u8 {
    if (try getOwnedEnvVarOrNull(allocator, "GUAVA_DOTNET")) |override| {
        if (override.len != 0) {
            return override;
        }
        allocator.free(override);
    }

    const executable_name = if (builtin.os.tag == .windows) "dotnet.exe" else "dotnet";
    const dotnet_root_vars = [_][]const u8{
        "DOTNET_ROOT",
        "DOTNET_ROOT_X64",
        "DOTNET_ROOT_X86",
        "DOTNET_ROOT(x86)",
    };

    for (dotnet_root_vars) |env_name| {
        const root = (try getOwnedEnvVarOrNull(allocator, env_name)) orelse continue;
        defer allocator.free(root);
        if (root.len == 0) continue;

        const candidate = try std.fs.path.join(allocator, &.{ root, executable_name });
        errdefer allocator.free(candidate);
        if (pathExists(candidate)) {
            return candidate;
        }
        allocator.free(candidate);
    }

    if (try findExecutableInPath(allocator, executable_name)) |candidate| {
        return candidate;
    }

    for (fallbackDotnetPaths()) |candidate| {
        if (pathExists(candidate)) {
            return try allocator.dupe(u8, candidate);
        }
    }
    return null;
}

pub fn nativeAotRuntimeIdentifier() ?[]const u8 {
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "osx-arm64",
            .x86_64 => "osx-x64",
            else => null,
        },
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => "linux-arm64",
            .x86_64 => "linux-x64",
            else => null,
        },
        .windows => switch (builtin.cpu.arch) {
            .aarch64 => "win-arm64",
            .x86_64 => "win-x64",
            else => null,
        },
        else => null,
    };
}

pub fn defaultPublishOutputDirAlloc(allocator: std.mem.Allocator, project_path: []const u8) ![]u8 {
    const rid = nativeAotRuntimeIdentifier() orelse return PublishError.UnsupportedPlatform;
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(project_path);
    const digest = hasher.final();
    return std.fmt.allocPrint(allocator, "zig-cache/guava/csharp/{x}/{s}", .{ digest, rid });
}

pub fn publishNativeAotLibraryAlloc(allocator: std.mem.Allocator, options: PublishOptions) ![]u8 {
    const dotnet = (try findDotnetBinary(allocator)) orelse return PublishError.DotnetNotFound;
    defer allocator.free(dotnet);

    const rid = nativeAotRuntimeIdentifier() orelse return PublishError.UnsupportedPlatform;
    const output_dir = if (options.output_dir) |dir|
        try allocator.dupe(u8, dir)
    else
        try defaultPublishOutputDirAlloc(allocator, options.project_path);
    defer allocator.free(output_dir);

    try std.fs.cwd().makePath(output_dir);

    const publish_aot = if (options.publish_aot) "true" else "false";
    const self_contained = if (options.self_contained) "true" else "false";
    const publish_aot_arg = try std.fmt.allocPrint(allocator, "-p:PublishAot={s}", .{publish_aot});
    defer allocator.free(publish_aot_arg);
    const native_lib_arg = try std.fmt.allocPrint(allocator, "-p:NativeLib={s}", .{options.native_lib});
    defer allocator.free(native_lib_arg);
    const self_contained_arg = try std.fmt.allocPrint(allocator, "-p:SelfContained={s}", .{self_contained});
    defer allocator.free(self_contained_arg);

    const argv = [_][]const u8{
        dotnet,
        "publish",
        options.project_path,
        "-c",
        options.configuration,
        "-r",
        rid,
        "-o",
        output_dir,
        publish_aot_arg,
        native_lib_arg,
        self_contained_arg,
    };

    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 8 * 1024 * 1024,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("dotnet publish failed for {s}:\n{s}\n{s}\n", .{
                    options.project_path,
                    result.stdout,
                    result.stderr,
                });
                return PublishError.PublishFailed;
            }
        },
        else => return PublishError.PublishFailed,
    }

    return findPublishedNativeAotLibrary(allocator, output_dir);
}

pub fn ensurePublishedNativeAotLibraryAlloc(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    existing_artifact_path: ?[]const u8,
) ![]u8 {
    if (existing_artifact_path) |artifact_path| {
        if (isSharedLibraryPath(artifact_path) and !try projectNeedsPublish(project_path, artifact_path)) {
            return try allocator.dupe(u8, artifact_path);
        }
    }

    const output_dir = if (existing_artifact_path) |artifact_path|
        if (isSharedLibraryPath(artifact_path))
            try publishOutputDirForArtifactAlloc(allocator, artifact_path)
        else
            null
    else
        null;
    defer if (output_dir) |dir| allocator.free(dir);

    return publishNativeAotLibraryAlloc(allocator, .{
        .project_path = project_path,
        .output_dir = output_dir,
    });
}

pub fn projectNeedsPublish(project_path: []const u8, artifact_path: []const u8) !bool {
    if (!pathExists(project_path) or !pathExists(artifact_path)) {
        return true;
    }
    const project_mtime = try getFileMtime(project_path);
    const artifact_mtime = try getFileMtime(artifact_path);
    return project_mtime > artifact_mtime;
}

pub fn collectProjectWatchPathsAlloc(allocator: std.mem.Allocator, project_path: []const u8) ![][]u8 {
    var paths = std.ArrayList([]u8).empty;
    errdefer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    try appendUniquePath(allocator, &paths, project_path);

    const project_dir_path = std.fs.path.dirname(project_path) orelse ".";
    var project_dir = try std.fs.cwd().openDir(project_dir_path, .{ .iterate = true });
    defer project_dir.close();

    var walker = try project_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (shouldSkipProjectEntry(entry.path)) {
            continue;
        }
        if (entry.kind != .file) {
            continue;
        }
        if (!isCSharpSourcePath(entry.basename) and !isDotnetProjectPath(entry.basename)) {
            continue;
        }

        const watched_path = try joinProjectPathAlloc(allocator, project_dir_path, entry.path);
        errdefer allocator.free(watched_path);
        try appendOwnedUniquePath(allocator, &paths, watched_path);
    }

    return try paths.toOwnedSlice(allocator);
}

fn appendUniquePath(allocator: std.mem.Allocator, paths: *std.ArrayList([]u8), path: []const u8) !void {
    const owned = try allocator.dupe(u8, path);
    errdefer allocator.free(owned);
    try appendOwnedUniquePath(allocator, paths, owned);
}

fn appendOwnedUniquePath(allocator: std.mem.Allocator, paths: *std.ArrayList([]u8), owned_path: []u8) !void {
    for (paths.items) |existing| {
        if (std.mem.eql(u8, existing, owned_path)) {
            allocator.free(owned_path);
            return;
        }
    }
    try paths.append(allocator, owned_path);
}

fn joinProjectPathAlloc(allocator: std.mem.Allocator, base_dir: []const u8, relative_path: []const u8) ![]u8 {
    if (std.mem.eql(u8, base_dir, ".") or base_dir.len == 0) {
        return try allocator.dupe(u8, relative_path);
    }
    return try std.fs.path.join(allocator, &.{ base_dir, relative_path });
}

fn shouldSkipProjectEntry(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "bin/") or std.mem.eql(u8, path, "bin")) return true;
    if (std.mem.startsWith(u8, path, "obj/") or std.mem.eql(u8, path, "obj")) return true;
    if (std.mem.indexOf(u8, path, "/bin/") != null) return true;
    if (std.mem.indexOf(u8, path, "/obj/") != null) return true;
    return false;
}

fn publishOutputDirForArtifactAlloc(allocator: std.mem.Allocator, artifact_path: []const u8) !?[]u8 {
    const dir = std.fs.path.dirname(artifact_path) orelse return null;
    return try allocator.dupe(u8, dir);
}

fn getOwnedEnvVarOrNull(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => return err,
    };
}

fn findExecutableInPath(allocator: std.mem.Allocator, executable_name: []const u8) !?[]u8 {
    const path_env = (try getOwnedEnvVarOrNull(allocator, "PATH")) orelse return null;
    defer allocator.free(path_env);
    return findExecutableInPathString(allocator, path_env, executable_name);
}

fn findExecutableInPathString(allocator: std.mem.Allocator, path_env: []const u8, executable_name: []const u8) !?[]u8 {
    var path_it = std.mem.tokenizeScalar(u8, path_env, std.fs.path.delimiter);
    while (path_it.next()) |entry| {
        const dir = if (entry.len == 0) "." else entry;
        const candidate = try std.fs.path.join(allocator, &.{ dir, executable_name });
        errdefer allocator.free(candidate);
        if (pathExists(candidate)) {
            return candidate;
        }
        allocator.free(candidate);
    }
    return null;
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn fallbackDotnetPaths() []const []const u8 {
    return switch (builtin.os.tag) {
        .windows => &.{
            "C:\\Program Files\\dotnet\\dotnet.exe",
            "C:\\Program Files (x86)\\dotnet\\dotnet.exe",
        },
        .linux => &.{
            "/usr/bin/dotnet",
            "/usr/local/bin/dotnet",
            "/usr/share/dotnet/dotnet",
            "/snap/bin/dotnet",
        },
        .macos => &.{
            "/usr/local/share/dotnet/dotnet",
            "/opt/homebrew/share/dotnet/dotnet",
            "/usr/local/bin/dotnet",
            "/opt/homebrew/bin/dotnet",
        },
        else => &.{},
    };
}

fn getFileMtime(path: []const u8) !i128 {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const stat = try file.stat();
    return stat.mtime;
}

fn findPublishedNativeAotLibrary(allocator: std.mem.Allocator, output_dir: []const u8) ![]u8 {
    var dir = try std.fs.cwd().openDir(output_dir, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!isSharedLibraryPath(entry.name)) continue;
        return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, entry.name });
    }
    return PublishError.ArtifactNotFound;
}

test "dotnet lookup finds executable in PATH entries" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.makePath("sdk");

    const executable_name = if (builtin.os.tag == .windows) "dotnet.exe" else "dotnet";

    var relative_path_buf: [64]u8 = undefined;
    const relative_path = try std.fmt.bufPrint(&relative_path_buf, "sdk/{s}", .{executable_name});
    try temp_dir.dir.writeFile(.{
        .sub_path = relative_path,
        .data = "",
    });

    var original = try std.fs.cwd().openDir(".", .{});
    defer original.close();
    try temp_dir.dir.setAsCwd();
    defer original.setAsCwd() catch {};

    const found = try findExecutableInPathString(std.testing.allocator, "sdk", executable_name);
    defer if (found) |path| std.testing.allocator.free(path);

    try std.testing.expect(found != null);

    const expected = try std.fs.path.join(std.testing.allocator, &.{ "sdk", executable_name });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, found.?);
}

test "collect project watch paths includes cs and csproj but skips bin obj" {
    var temp_dir = std.testing.tmpDir(.{});
    defer temp_dir.cleanup();

    try temp_dir.dir.makePath("game/bin");
    try temp_dir.dir.makePath("game/obj");
    try temp_dir.dir.makePath("game/Sub");
    try temp_dir.dir.writeFile(.{
        .sub_path = "game/Game.csproj",
        .data = "<Project />",
    });
    try temp_dir.dir.writeFile(.{
        .sub_path = "game/Player.cs",
        .data = "class Player {}",
    });
    try temp_dir.dir.writeFile(.{
        .sub_path = "game/Sub/Enemy.cs",
        .data = "class Enemy {}",
    });
    try temp_dir.dir.writeFile(.{
        .sub_path = "game/bin/Ignore.cs",
        .data = "class Ignore {}",
    });
    try temp_dir.dir.writeFile(.{
        .sub_path = "game/obj/IgnoreToo.cs",
        .data = "class IgnoreToo {}",
    });

    var original = try std.fs.cwd().openDir(".", .{});
    defer original.close();
    try temp_dir.dir.setAsCwd();
    defer original.setAsCwd() catch {};

    const watched = try collectProjectWatchPathsAlloc(std.testing.allocator, "game/Game.csproj");
    defer {
        for (watched) |path| std.testing.allocator.free(path);
        std.testing.allocator.free(watched);
    }

    try std.testing.expectEqual(@as(usize, 3), watched.len);
    try std.testing.expectEqualStrings("game/Game.csproj", watched[0]);
    try std.testing.expect(std.mem.indexOfScalar(u8, watched[1], 'I') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, watched[2], 'I') == null);
}
