const std = @import("std");

const engine_include_paths = [_][]const u8{
    "third_party/stb",
    "third_party/imgui",
    "third_party/lunasvg/include",
    "third_party/lunasvg/source",
    "third_party/lunasvg/plutovg/include",
    "third_party/lunasvg/plutovg/source",
    "src/engine/assets",
    "src/engine/ui",
};

const plutovg_c_sources = [_][]const u8{
    "third_party/lunasvg/plutovg/source/plutovg-blend.c",
    "third_party/lunasvg/plutovg/source/plutovg-canvas.c",
    "third_party/lunasvg/plutovg/source/plutovg-font.c",
    "third_party/lunasvg/plutovg/source/plutovg-ft-math.c",
    "third_party/lunasvg/plutovg/source/plutovg-ft-raster.c",
    "third_party/lunasvg/plutovg/source/plutovg-ft-stroker.c",
    "third_party/lunasvg/plutovg/source/plutovg-matrix.c",
    "third_party/lunasvg/plutovg/source/plutovg-paint.c",
    "third_party/lunasvg/plutovg/source/plutovg-path.c",
    "third_party/lunasvg/plutovg/source/plutovg-rasterize.c",
    "third_party/lunasvg/plutovg/source/plutovg-surface.c",
};

const engine_cpp_sources = [_][]const u8{
    "third_party/imgui/imgui.cpp",
    "third_party/imgui/imgui_draw.cpp",
    "third_party/imgui/imgui_tables.cpp",
    "third_party/imgui/imgui_widgets.cpp",
    "third_party/imgui/backends/imgui_impl_sdl3.cpp",
    "third_party/imgui/backends/imgui_impl_sdlgpu3.cpp",
    "third_party/lunasvg/source/graphics.cpp",
    "third_party/lunasvg/source/lunasvg.cpp",
    "third_party/lunasvg/source/svgelement.cpp",
    "third_party/lunasvg/source/svggeometryelement.cpp",
    "third_party/lunasvg/source/svglayoutstate.cpp",
    "third_party/lunasvg/source/svgpaintelement.cpp",
    "third_party/lunasvg/source/svgparser.cpp",
    "third_party/lunasvg/source/svgproperty.cpp",
    "third_party/lunasvg/source/svgrenderstate.cpp",
    "third_party/lunasvg/source/svgtextelement.cpp",
    "src/engine/assets/svg_raster_bridge.cpp",
    "src/engine/ui/imgui_bridge.cpp",
};

const macos_objcpp_sources = [_][]const u8{
    "src/engine/platform/window_native_macos.mm",
};

const windows_cpp_sources = [_][]const u8{
    "src/engine/platform/window_native_windows.cpp",
};

const plutovg_c_flags = [_][]const u8{
    "-std=c11",
    "-DPLUTOVG_BUILD=1",
    "-DPLUTOVG_BUILD_STATIC=1",
};

const engine_cpp_flags = [_][]const u8{
    "-std=c++17",
    "-DLUNASVG_BUILD=1",
    "-DLUNASVG_BUILD_STATIC=1",
    "-DPLUTOVG_BUILD=1",
    "-DPLUTOVG_BUILD_STATIC=1",
};

const macos_objcpp_flags = [_][]const u8{
    "-std=c++17",
    "-fobjc-arc",
};

const windows_platform_cpp_flags = [_][]const u8{
    "-std=c++17",
};

const Language = enum {
    c,
    cpp,
    objcpp,
};

const CompileCommand = struct {
    directory: []const u8,
    file: []const u8,
    arguments: []const []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const default_sdl_prefix = switch (target.result.os.tag) {
        .macos => "/opt/homebrew",
        .windows => "C:/SDL3",
        else => "/usr/local",
    };
    const sdl_prefix = b.option([]const u8, "sdl-prefix", "Prefix path for an SDL3 installation") orelse default_sdl_prefix;

    const shader_codegen = b.addExecutable(.{
        .name = "shader-codegen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/shader_codegen.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_shader_codegen = b.addRunArtifact(shader_codegen);
    run_shader_codegen.addFileArg(b.path("assets/shaders/manifest.json"));
    run_shader_codegen.addFileArg(b.path("src/engine/generated/shaders.zig"));

    const engine_mod = b.addModule("guava", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    configureEngineModule(b, engine_mod, target.result.os.tag, sdl_prefix);

    const exe = b.addExecutable(.{
        .name = "guava-engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "guava", .module = engine_mod },
            },
        }),
    });
    exe.linkLibC();
    exe.linkLibCpp();
    // When cross-linking against a prebuilt system SDL3 shared library (e.g. Arch),
    // we don't want the link to fail due to unresolved glibc symbol versions that
    // will be provided by the target runtime.
    exe.linker_allow_shlib_undefined = true;
    exe.step.dependOn(&run_shader_codegen.step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const validate_cmd = b.addRunArtifact(exe);
    validate_cmd.step.dependOn(b.getInstallStep());
    validate_cmd.addArg("validate");
    if (b.args) |args| {
        validate_cmd.addArgs(args);
    }

    const validate_step = b.step("validate", "Validate project assets");
    validate_step.dependOn(&validate_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = engine_mod,
    });
    mod_tests.linkLibC();
    mod_tests.linkLibCpp();
    mod_tests.step.dependOn(&run_shader_codegen.step);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.linkLibC();
    exe_tests.linkLibCpp();
    exe_tests.step.dependOn(&run_shader_codegen.step);

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const shaders_step = b.step("shaders", "Compile shaders and regenerate reflection metadata");
    shaders_step.dependOn(&run_shader_codegen.step);

    const compile_commands_step = b.step("compile-commands", "Generate compile_commands.json for clangd");
    const update_compile_commands = b.addUpdateSourceFiles();
    update_compile_commands.addBytesToSource(
        generateCompileCommandsJson(b, target.result.os.tag, sdl_prefix),
        "compile_commands.json",
    );
    compile_commands_step.dependOn(&update_compile_commands.step);
}

fn configureEngineModule(
    b: *std.Build,
    module: *std.Build.Module,
    os_tag: std.Target.Os.Tag,
    sdl_prefix: []const u8,
) void {
    const sdl_include_path = b.pathJoin(&.{ sdl_prefix, "include" });
    const sdl_library_path = b.pathJoin(&.{ sdl_prefix, "lib" });

    module.addIncludePath(.{ .cwd_relative = sdl_include_path });
    for (engine_include_paths) |include_path| {
        module.addIncludePath(.{ .cwd_relative = include_path });
    }

    module.addLibraryPath(.{ .cwd_relative = sdl_library_path });
    if (os_tag != .windows) {
        module.addRPath(.{ .cwd_relative = sdl_library_path });
    }

    module.addCSourceFiles(.{
        .files = &plutovg_c_sources,
        .flags = &plutovg_c_flags,
    });
    module.addCSourceFiles(.{
        .files = &engine_cpp_sources,
        .flags = &engine_cpp_flags,
    });
    if (os_tag == .macos) {
        module.addCSourceFiles(.{
            .files = &macos_objcpp_sources,
            .flags = &macos_objcpp_flags,
        });
        module.linkFramework("AppKit", .{});
    }
    if (os_tag == .windows) {
        module.addCSourceFiles(.{
            .files = &windows_cpp_sources,
            .flags = &windows_platform_cpp_flags,
        });
        module.linkSystemLibrary("comctl32", .{});
        module.linkSystemLibrary("dwmapi", .{});
        module.linkSystemLibrary("uxtheme", .{});
    }
    module.linkSystemLibrary("SDL3", .{});
}

fn generateCompileCommandsJson(
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

    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        c_compiler,
        &plutovg_c_flags,
        &plutovg_c_sources,
    );
    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        cpp_compiler,
        &engine_cpp_flags,
        &engine_cpp_sources,
    );

    if (os_tag == .macos) {
        appendCompileCommands(
            b,
            &entries,
            root_dir,
            sdl_include_path,
            sysroot,
            objcpp_compiler,
            &macos_objcpp_flags,
            &macos_objcpp_sources,
        );
    }
    if (os_tag == .windows) {
        appendCompileCommands(
            b,
            &entries,
            root_dir,
            sdl_include_path,
            sysroot,
            cpp_compiler,
            &windows_platform_cpp_flags,
            &windows_cpp_sources,
        );
    }

    var out: std.io.Writer.Allocating = .init(b.allocator);
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
        for (engine_include_paths) |include_path| {
            arguments.append(b.allocator, b.fmt("-I{s}", .{b.pathFromRoot(include_path)})) catch @panic("OOM");
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
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = argv,
    }) catch return null;
    defer {
        b.allocator.free(result.stdout);
        b.allocator.free(result.stderr);
    }

    switch (result.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trimEnd(u8, result.stdout, "\r\n");
    return b.allocator.dupe(u8, trimmed) catch @panic("OOM");
}
