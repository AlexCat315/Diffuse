const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const default_sdl_prefix = switch (target.result.os.tag) {
        .macos => "/opt/homebrew",
        .windows => "C:/SDL3",
        else => "/usr/local",
    };
    const sdl_prefix = b.option([]const u8, "sdl-prefix", "Prefix path for an SDL3 installation") orelse default_sdl_prefix;

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
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const mod_tests = b.addTest(.{
        .root_module = engine_mod,
    });
    mod_tests.linkLibC();

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    exe_tests.linkLibC();

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
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
    module.addLibraryPath(.{ .cwd_relative = sdl_library_path });
    if (os_tag != .windows) {
        module.addRPath(.{ .cwd_relative = sdl_library_path });
    }
    module.linkSystemLibrary("SDL3", .{});
}
