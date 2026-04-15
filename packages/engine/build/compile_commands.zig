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

    // PlutoVG / stb
    appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, c_compiler, &sources.plutovg_c_flags, &sources.plutovg_c_sources, &.{});

    // Engine C++ (LunaSVG, Jolt bridge, Recast bridge)
    appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, cpp_compiler, &sources.engine_cpp_flags, &sources.engine_cpp_sources, &.{});

    // SoLoud audio
    appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, cpp_compiler, &sources.soloud_cpp_flags, &sources.soloud_core_cpp_sources, &.{});
    appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, cpp_compiler, &sources.soloud_cpp_flags, &sources.soloud_wav_cpp_sources, &.{});
    appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, cpp_compiler, &sources.soloud_cpp_flags, &sources.soloud_extra_audiosource_cpp_sources, &.{});
    appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, cpp_compiler, &sources.soloud_cpp_flags, &sources.soloud_filter_cpp_sources, &.{});
    appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, cpp_compiler, &sources.soloud_cpp_flags, &sources.soloud_backend_cpp_sources, &.{});
    appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, cpp_compiler, &sources.soloud_cpp_flags, &sources.soloud_c_api_cpp_sources, &.{});
    appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, c_compiler, &sources.soloud_c_flags, &sources.soloud_support_c_sources, &.{});

    // Jolt Physics (auto-collected)
    const jolt_cpp_sources = utils.collectSourceFiles(b, "third_party/jolt/Jolt", ".cpp");
    appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, cpp_compiler, &sources.engine_cpp_flags, jolt_cpp_sources, &.{});

    // Recast/Detour navigation (auto-collected)
    const recast_cpp_sources = utils.collectSourceFiles(b, "third_party/recast/Recast/Source", ".cpp");
    appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, cpp_compiler, &sources.engine_cpp_flags, recast_cpp_sources, &.{});
    const detour_cpp_sources = utils.collectSourceFiles(b, "third_party/recast/Detour/Source", ".cpp");
    appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, cpp_compiler, &sources.engine_cpp_flags, detour_cpp_sources, &.{});
    const detour_crowd_cpp_sources = utils.collectSourceFiles(b, "third_party/recast/DetourCrowd/Source", ".cpp");
    appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, cpp_compiler, &sources.engine_cpp_flags, detour_crowd_cpp_sources, &.{});

    // Platform-specific
    if (os_tag == .macos) {
        appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, objcpp_compiler, &sources.macos_objcpp_flags, &sources.macos_objcpp_sources, &.{});
    }
    if (os_tag == .windows) {
        appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, cpp_compiler, &sources.windows_platform_cpp_flags, &sources.windows_cpp_sources, &.{});
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
        appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, c_compiler, &sources.vulkan_c_flags, &sources.vulkan_c_sources, vk_includes);
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
            appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, objcpp_compiler, &sources.macos_objcpp_flags, &.{"../editor/native/src/iosurface_view.mm"}, napi_includes);
        }
        appendCompileCommands(b, &entries, root_dir, sdl_include_path, sysroot, cpp_compiler, &sources.engine_cpp_flags, &.{"../editor/native/src/shm_view.cpp"}, napi_includes);
    }

    var out: std.Io.Writer.Allocating = .init(b.allocator);
    defer out.deinit();
    std.json.Stringify.value(entries.items, .{ .whitespace = .indent_2 }, &out.writer) catch @panic("OOM");
    out.writer.writeAll("\n") catch @panic("OOM");
    return b.allocator.dupe(u8, out.written()) catch @panic("OOM");
}

fn appendCompileCommands(
    b: *std.Build,
    entries: *std.ArrayList(CompileCommand),
    root_dir: []const u8,
    sdl_include_path: []const u8,
    sysroot: ?[]const u8,
    compiler: []const u8,
    flags: []const []const u8,
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
        arguments.appendSlice(b.allocator, flags) catch @panic("OOM");
        arguments.append(b.allocator, b.fmt("-I{s}", .{sdl_include_path})) catch @panic("OOM");
        for (sources.engine_include_paths) |include_path| {
            arguments.append(b.allocator, b.fmt("-I{s}", .{b.pathFromRoot(include_path)})) catch @panic("OOM");
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
