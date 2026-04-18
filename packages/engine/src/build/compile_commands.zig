const std = @import("std");
const sources = @import("sources.zig");
const utils = @import("utils.zig");

pub const Language = enum {
    c,
    cpp,
    objcpp,
};

pub const CompileCommand = struct {
    directory: []const u8,
    file: []const u8,
    arguments: []const []const u8,
};

/// Generate the full compile_commands.json content for clangd.
pub fn generateCompileCommandsJson(
    b: *std.Build,
    os_tag: std.Target.Os.Tag,
    sdl_prefix: []const u8,
) []const u8 {
    const root_dir = b.pathFromRoot(".");
    const sdl_include_path = b.pathResolve(&.{ sdl_prefix, "include" });
    const sysroot = detectAppleSysroot(b, os_tag);
    const c_compiler = compilerPath(b, .c, os_tag);
    const cpp_compiler = compilerPath(b, .cpp, os_tag);
    const objcpp_compiler = compilerPath(b, .objcpp, os_tag);

    var entries: std.ArrayList(CompileCommand) = .empty;
    defer entries.deinit(b.allocator);

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

    // Auto-scan from repository root and filter by ignored directory segments.
    const c_files = collectFromRootWithIgnores(b, ".", ".c", &ignored_dirs);
    defer b.allocator.free(c_files);

    const cpp_files = collectFromRootWithIgnores(b, ".", ".cpp", &ignored_dirs);
    defer b.allocator.free(cpp_files);

    appendAutoScannedCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        c_compiler,
        .c,
        c_files,
        &.{},
    );

    appendAutoScannedCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        cpp_compiler,
        .cpp,
        cpp_files,
        &.{},
    );

    if (os_tag == .macos) {
        const objcpp_files = collectFromRootWithIgnores(b, ".", ".mm", &ignored_dirs);
        defer b.allocator.free(objcpp_files);
        appendAutoScannedCommands(
            b,
            &entries,
            root_dir,
            sdl_include_path,
            sysroot,
            objcpp_compiler,
            .objcpp,
            objcpp_files,
            &.{},
        );
    }

    // Vulkan C bridge — detect include path via pkg-config
    const vulkan_include = utils.captureCommandOutput(b, &.{
        "pkg-config", "--variable=includedir", "vulkan",
    });
    {
        var vulkan_extra_includes: std.ArrayList([]const u8) = .empty;
        defer vulkan_extra_includes.deinit(b.allocator);
        if (vulkan_include) |p| vulkan_extra_includes.append(b.allocator, p) catch @panic("OOM");
        const vk_includes = vulkan_extra_includes.toOwnedSlice(b.allocator) catch @panic("OOM");
        appendAutoScannedCommands(
            b,
            &entries,
            root_dir,
            sdl_include_path,
            sysroot,
            c_compiler,
            .c,
            &sources.vulkan_c_sources,
            vk_includes,
        );
    }

    // Electron native addon (N-API)
    const napi_include = utils.captureCommandOutput(b, &.{
        "node",                                                                          "-e",
        "console.log(require('path').resolve('../editor/node_modules/node-addon-api'))",
    });
    const node_include = utils.captureCommandOutput(b, &.{
        "node",                                                                              "-e",
        "console.log(require('path').resolve(process.execPath,'..','..','include','node'))",
    });
    if (napi_include != null or node_include != null) {
        var napi_extra_includes: std.ArrayList([]const u8) = .empty;
        defer napi_extra_includes.deinit(b.allocator);
        if (napi_include) |p| napi_extra_includes.append(b.allocator, p) catch @panic("OOM");
        if (node_include) |p| napi_extra_includes.append(b.allocator, p) catch @panic("OOM");
        const napi_includes = napi_extra_includes.toOwnedSlice(b.allocator) catch @panic("OOM");

        if (os_tag == .macos) {
            appendAutoScannedCommands(
                b,
                &entries,
                root_dir,
                sdl_include_path,
                sysroot,
                objcpp_compiler,
                .objcpp,
                &.{"../editor/native/src/iosurface_view.mm"},
                napi_includes,
            );
        }
        appendAutoScannedCommands(
            b,
            &entries,
            root_dir,
            sdl_include_path,
            sysroot,
            cpp_compiler,
            .cpp,
            &.{"../editor/native/src/shm_view.cpp"},
            napi_includes,
        );
    }

    var out: std.Io.Writer.Allocating = .init(b.allocator);
    defer out.deinit();
    std.json.Stringify.value(entries.items, .{ .whitespace = .indent_2 }, &out.writer) catch @panic("OOM");
    out.writer.writeAll("\n") catch @panic("OOM");
    return b.allocator.dupe(u8, out.written()) catch @panic("OOM");
}

fn appendAutoScannedCommands(
    b: *std.Build,
    entries: *std.ArrayList(CompileCommand),
    root_dir: []const u8,
    sdl_include_path: []const u8,
    sysroot: ?[]const u8,
    compiler: []const u8,
    language: Language,
    files: []const []const u8,
    extra_include_paths: []const []const u8,
) void {
    for (files) |file| {
        const absolute_file = b.pathFromRoot(file);
        var arguments: std.ArrayList([]const u8) = .empty;
        defer arguments.deinit(b.allocator);

        arguments.append(b.allocator, compiler) catch @panic("OOM");
        if (sysroot) |sdk_path| {
            arguments.append(b.allocator, "-isysroot") catch @panic("OOM");
            arguments.append(b.allocator, sdk_path) catch @panic("OOM");
        }
        appendAutoFlagsForFile(b, &arguments, language, file) catch @panic("OOM");
        arguments.append(b.allocator, b.fmt("-I{s}", .{sdl_include_path})) catch @panic("OOM");
        for (sources.engine_include_paths) |include_path| {
            arguments.append(b.allocator, b.fmt("-I{s}", .{b.pathFromRoot(include_path)})) catch @panic("OOM");
        }

        // Optional Vulkan include path improves clangd resolution for bridge files.
        if (std.mem.indexOf(u8, file, "vulkan") != null) {
            if (utils.captureCommandOutput(b, &.{ "pkg-config", "--variable=includedir", "vulkan" })) |vk_inc| {
                arguments.append(b.allocator, b.fmt("-I{s}", .{vk_inc})) catch @panic("OOM");
            }
        }

        for (extra_include_paths) |include_path| {
            arguments.append(b.allocator, b.fmt("-I{s}", .{include_path})) catch @panic("OOM");
        }
        arguments.append(b.allocator, absolute_file) catch @panic("OOM");

        entries.append(b.allocator, .{
            .directory = root_dir,
            .file = absolute_file,
            .arguments = arguments.toOwnedSlice(b.allocator) catch @panic("OOM"),
        }) catch @panic("OOM");
    }
}

fn appendAutoFlagsForFile(
    b: *std.Build,
    arguments: *std.ArrayList([]const u8),
    language: Language,
    file: []const u8,
) !void {
    switch (language) {
        .c => try arguments.append(b.allocator, "-std=c11"),
        .cpp, .objcpp => try arguments.append(b.allocator, "-std=c++17"),
    }

    if (language == .objcpp) {
        try arguments.append(b.allocator, "-fobjc-arc");
    }

    if (std.mem.indexOf(u8, file, "third_party/lunasvg/plutovg") != null) {
        try arguments.appendSlice(b.allocator, &.{
            "-DPLUTOVG_BUILD=1",
            "-DPLUTOVG_BUILD_STATIC=1",
        });
    } else if (std.mem.indexOf(u8, file, "third_party/lunasvg") != null) {
        try arguments.appendSlice(b.allocator, &.{
            "-DLUNASVG_BUILD=1",
            "-DLUNASVG_BUILD_STATIC=1",
            "-DPLUTOVG_BUILD=1",
            "-DPLUTOVG_BUILD_STATIC=1",
        });
    }

    if (std.mem.indexOf(u8, file, "third_party/soloud") != null and language != .c) {
        try arguments.appendSlice(b.allocator, &.{
            "-DWITH_MINIAUDIO=1",
            "-DWITH_COREAUDIO=1",
        });
    }
}

fn collectFromRootWithIgnores(
    b: *std.Build,
    root: []const u8,
    extension: []const u8,
    ignored_dirs: []const []const u8,
) []const []const u8 {
    const files = utils.collectSourceFiles(b, root, extension);
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
        .c => "clang",
        .cpp, .objcpp => "clang++",
    };
    if (os_tag == .macos) {
        if (utils.captureCommandOutput(b, &.{ "xcrun", "--find", tool_name })) |path| {
            return path;
        }
    }
    return tool_name;
}

fn detectAppleSysroot(b: *std.Build, os_tag: std.Target.Os.Tag) ?[]const u8 {
    if (os_tag != .macos) {
        return null;
    }
    return utils.captureCommandOutput(b, &.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" });
}
