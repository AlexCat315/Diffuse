const std = @import("std");

pub const Language = enum {
    c,
    cpp,
    objc,
    objcpp,
};

pub const CompileCommand = struct {
    directory: []const u8,
    file: []const u8,
    arguments: []const []const u8,
};

const ScanSpec = struct {
    extension: []const u8,
    language: Language,
};

const scan_specs = [_]ScanSpec{
    .{ .extension = ".c", .language = .c },
    .{ .extension = ".cpp", .language = .cpp },
    .{ .extension = ".cc", .language = .cpp },
    .{ .extension = ".cxx", .language = .cpp },
    .{ .extension = ".m", .language = .objc },
    .{ .extension = ".mm", .language = .objcpp },
};

pub fn generateCompileCommandsJson(
    b: *std.Build,
    os_tag: std.Target.Os.Tag,
    include_paths: []const []const u8,
) []const u8 {
    const root_dir = b.pathFromRoot(".");
    const src_include_path = b.pathFromRoot("src");
    const sysroot = detectAppleSysroot(b, os_tag);
    const ignored_dirs = [_][]const u8{
        ".git",
        ".zig-cache",
        "zig-cache",
        "zig-out",
        "node_modules",
        "build",
        "CMakeFiles",
        "cmake-build-debug",
        "cmake-build-release",
        "dist",
        "dist-citron",
    };

    var entries: std.ArrayList(CompileCommand) = .empty;
    defer entries.deinit(b.allocator);

    for (scan_specs) |spec| {
        const files = collectFromRootWithIgnores(b, ".", spec.extension, &ignored_dirs);
        defer b.allocator.free(files);
        appendSources(
            b,
            &entries,
            root_dir,
            src_include_path,
            files,
            spec.language,
            os_tag,
            sysroot,
            include_paths,
        );
    }

    var out: std.Io.Writer.Allocating = .init(b.allocator);
    defer out.deinit();
    std.json.Stringify.value(entries.items, .{ .whitespace = .indent_2 }, &out.writer) catch @panic("OOM");
    out.writer.writeAll("\n") catch @panic("OOM");
    return b.allocator.dupe(u8, out.written()) catch @panic("OOM");
}

fn appendSources(
    b: *std.Build,
    entries: *std.ArrayList(CompileCommand),
    root_dir: []const u8,
    src_include_path: []const u8,
    files: []const []const u8,
    language: Language,
    os_tag: std.Target.Os.Tag,
    sysroot: ?[]const u8,
    include_paths: []const []const u8,
) void {
    const compiler = compilerPath(b, language, os_tag);

    for (files) |file| {
        const absolute_file = b.pathFromRoot(file);
        var arguments: std.ArrayList([]const u8) = .empty;
        defer arguments.deinit(b.allocator);

        arguments.append(b.allocator, compiler) catch @panic("OOM");
        if (sysroot) |sdk_path| {
            arguments.append(b.allocator, "-isysroot") catch @panic("OOM");
            arguments.append(b.allocator, sdk_path) catch @panic("OOM");
        }

        switch (language) {
            .c => arguments.append(b.allocator, "-std=c11") catch @panic("OOM"),
            .cpp, .objcpp => arguments.append(b.allocator, "-std=c++17") catch @panic("OOM"),
            .objc => {},
        }

        if ((language == .objc or language == .objcpp) and os_tag == .macos) {
            arguments.append(b.allocator, "-fobjc-arc") catch @panic("OOM");
        }

        appendIncludeIfMissing(b, &arguments, src_include_path);
        for (include_paths) |include_path| {
            appendIncludeIfMissing(b, &arguments, include_path);
        }

        arguments.append(b.allocator, absolute_file) catch @panic("OOM");

        entries.append(b.allocator, .{
            .directory = root_dir,
            .file = absolute_file,
            .arguments = arguments.toOwnedSlice(b.allocator) catch @panic("OOM"),
        }) catch @panic("OOM");
    }
}

fn collectFromRootWithIgnores(
    b: *std.Build,
    root: []const u8,
    extension: []const u8,
    ignored_dirs: []const []const u8,
) []const []const u8 {
    const files = collectSourceFiles(b, root, extension);
    defer b.allocator.free(files);

    var filtered: std.ArrayList([]const u8) = .empty;
    defer filtered.deinit(b.allocator);

    for (files) |file| {
        if (hasIgnoredPathSegment(file, ignored_dirs)) continue;
        filtered.append(b.allocator, file) catch @panic("OOM");
    }

    std.mem.sort([]const u8, filtered.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    var unique = std.ArrayList([]const u8).empty;
    defer unique.deinit(b.allocator);

    var previous: ?[]const u8 = null;
    for (filtered.items) |item| {
        if (previous) |p| {
            if (std.mem.eql(u8, p, item)) continue;
        }
        unique.append(b.allocator, item) catch @panic("OOM");
        previous = item;
    }

    return unique.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn collectSourceFiles(b: *std.Build, root: []const u8, extension: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(b.allocator);

    var dir = b.build_root.handle.openDir(b.graph.io, root, .{ .iterate = true }) catch return &.{};
    defer dir.close(b.graph.io);

    var walker = dir.walk(b.allocator) catch return &.{};
    defer walker.deinit();

    while (walker.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, extension)) continue;
        list.append(b.allocator, b.pathJoin(&.{ root, entry.path })) catch @panic("OOM");
    }

    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn appendIncludeIfMissing(b: *std.Build, arguments: *std.ArrayList([]const u8), include_path: []const u8) void {
    const include_arg = b.fmt("-I{s}", .{include_path});
    for (arguments.items) |arg| {
        if (std.mem.eql(u8, arg, include_arg)) return;
    }
    arguments.append(b.allocator, include_arg) catch @panic("OOM");
}

fn hasIgnoredPathSegment(path: []const u8, ignored_dirs: []const []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        for (ignored_dirs) |ignored| {
            if (std.mem.eql(u8, segment, ignored)) return true;
        }
    }
    return false;
}

fn compilerPath(b: *std.Build, language: Language, os_tag: std.Target.Os.Tag) []const u8 {
    const tool_name = switch (language) {
        .c, .objc => "clang",
        .cpp, .objcpp => "clang++",
    };
    if (os_tag == .macos) {
        if (captureCommandOutput(b, &.{ "xcrun", "--find", tool_name })) |path| {
            return path;
        }
    }
    return tool_name;
}

fn detectAppleSysroot(b: *std.Build, os_tag: std.Target.Os.Tag) ?[]const u8 {
    if (os_tag != .macos) {
        return null;
    }
    return captureCommandOutput(b, &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" });
}

fn captureCommandOutput(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{ .argv = argv }) catch return null;
    defer {
        b.allocator.free(result.stdout);
        b.allocator.free(result.stderr);
    }

    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trimEnd(u8, result.stdout, "\r\n");
    return b.allocator.dupe(u8, trimmed) catch @panic("OOM");
}
