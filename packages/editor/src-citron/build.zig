const std = @import("std");
const citron_build = @import("citron");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const citron_dep = b.dependency("citron", .{
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption(
        []const u8,
        "engine_binary_fallback",
        b.pathResolve(&.{"../../engine/zig-out/bin/guava-engine"}),
    );

    const exe = b.addExecutable(.{
        .name = "guava-editor",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "citron", .module = citron_dep.module("citron") },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });

    citron_build.bundleMacApp(b, exe, citron_dep, .{
        .app_name = "Guava Editor",
        .bundle_id = "com.guava.editor",
        .exe_name = "guava-editor",
        .include_default_index = false,
    });

    const frontend = b.addInstallDirectory(.{
        .source_dir = b.path("../dist-citron"),
        .install_dir = .{ .custom = "Guava Editor.app/Contents" },
        .install_subdir = "Resources",
    });
    b.getInstallStep().dependOn(&frontend.step);
}
