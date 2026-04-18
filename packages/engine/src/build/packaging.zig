const std = @import("std");

/// Configure all packaging, cook, and script compilation steps.
pub fn addPackageSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    exe: *std.Build.Step.Compile,
    player: *std.Build.Step.Compile,
    sdl_prefix: []const u8,
) void {
    const package_step = b.step("package", "Build distributable game package (use -Doptimize=ReleaseSafe)");

    if (target.result.os.tag == .macos) {
        addMacOSBundle(b, package_step, player, sdl_prefix);
    } else if (target.result.os.tag == .windows) {
        addWindowsPackage(b, package_step, player);
    } else {
        addLinuxPackage(b, package_step, player);
    }

    // Cook step
    const cook_step = b.step("cook", "Pre-cook all project assets (runs engine validate to refresh derived outputs)");
    const cook_cmd = b.addRunArtifact(exe);
    cook_cmd.step.dependOn(b.getInstallStep());
    cook_cmd.addArg("validate");
    cook_step.dependOn(&cook_cmd.step);

    // Editor package step — builds guava-engine then runs electron-builder
    // Usage: zig build editor-package -Doptimize=ReleaseFast
    const editor_package_cmd = b.addSystemCommand(&.{ "npm", "run", "package" });
    editor_package_cmd.setCwd(b.path("../editor"));
    // Ensure guava-engine binary is built and installed before electron-builder runs
    editor_package_cmd.step.dependOn(b.getInstallStep());

    const editor_package_step = b.step(
        "editor-package",
        "Build guava-engine then package the Electron editor into a distributable app",
    );
    editor_package_step.dependOn(&editor_package_cmd.step);

    // Scripts compilation step
    addScriptsStep(b, target);
}

// ─── macOS .app bundle ──────────────────────────────────────────────────────

fn addMacOSBundle(
    b: *std.Build,
    package_step: *std.Build.Step,
    player: *std.Build.Step.Compile,
    sdl_prefix: []const u8,
) void {
    const bundle_base = "package/GuavaGame.app/Contents";

    // Build manifest generator
    const package_dir = b.getInstallPath(.{ .custom = "package" }, "");
    const gen_manifest = b.addSystemCommand(&.{
        "/bin/sh", "-c",
        std.fmt.allocPrint(
            b.allocator,
            "cd '{s}' && find . -type f -not -name build_manifest.json " ++
                "| LC_ALL=C sort | xargs shasum -a 256 > build_manifest.json",
            .{package_dir},
        ) catch @panic("OOM"),
    });
    package_step.dependOn(&gen_manifest.step);

    // Player binary → .app/Contents/MacOS/
    const pkg_player = b.addInstallArtifact(player, .{
        .dest_dir = .{ .override = .{ .custom = bundle_base ++ "/MacOS" } },
    });
    gen_manifest.step.dependOn(&pkg_player.step);

    // Info.plist → .app/Contents/
    const wf = b.addWriteFiles();
    const plist_source = wf.add("Info.plist",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
        \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>CFBundleExecutable</key>
        \\  <string>guava-player</string>
        \\  <key>CFBundleIdentifier</key>
        \\  <string>com.guava.game</string>
        \\  <key>CFBundleInfoDictionaryVersion</key>
        \\  <string>6.0</string>
        \\  <key>CFBundleName</key>
        \\  <string>GuavaGame</string>
        \\  <key>CFBundlePackageType</key>
        \\  <string>APPL</string>
        \\  <key>CFBundleVersion</key>
        \\  <string>1.0</string>
        \\  <key>CFBundleShortVersionString</key>
        \\  <string>1.0</string>
        \\  <key>LSMinimumSystemVersion</key>
        \\  <string>12.0</string>
        \\  <key>NSHighResolutionCapable</key>
        \\  <true/>
        \\</dict>
        \\</plist>
        \\
    );
    const install_plist = b.addInstallFileWithDir(plist_source, .{ .custom = bundle_base }, "Info.plist");
    gen_manifest.step.dependOn(&install_plist.step);

    // SDL3 dylib → .app/Contents/Frameworks/
    const sdl_dylib_path = b.pathJoin(&.{ sdl_prefix, "lib", "libSDL3.0.dylib" });
    const install_sdl = b.addInstallFileWithDir(
        .{ .cwd_relative = sdl_dylib_path },
        .{ .custom = bundle_base ++ "/Frameworks" },
        "libSDL3.0.dylib",
    );
    gen_manifest.step.dependOn(&install_sdl.step);

    // Rewrite the SDL3 load path
    const installed_player_path = b.getInstallPath(.{ .custom = bundle_base ++ "/MacOS" }, "guava-player");
    const fix_dylib_ref = b.addSystemCommand(&.{
        "/bin/sh", "-c",
        std.fmt.allocPrint(
            b.allocator,
            "OLD=$(/usr/bin/otool -L '{s}' | grep libSDL3 | head -1 | awk '{{print $1}}') && " ++
                "/usr/bin/install_name_tool -change \"$OLD\" '@executable_path/../Frameworks/libSDL3.0.dylib' '{s}'",
            .{ installed_player_path, installed_player_path },
        ) catch @panic("OOM"),
    });
    fix_dylib_ref.step.dependOn(&pkg_player.step);
    gen_manifest.step.dependOn(&fix_dylib_ref.step);

    // Source assets
    inline for (.{ "shaders", "models", "scenes", "ui" }) |subdir| {
        const install_assets = b.addInstallDirectory(.{
            .source_dir = b.path("assets/" ++ subdir),
            .install_dir = .{ .custom = bundle_base ++ "/assets/" ++ subdir },
            .install_subdir = "",
            .exclude_extensions = &.{ ".meta", ".DS_Store" },
        });
        gen_manifest.step.dependOn(&install_assets.step);
    }
    const install_logo = b.addInstallFileWithDir(
        b.path("assets/Guava_Engine_Logo.png"),
        .{ .custom = bundle_base ++ "/assets" },
        "Guava_Engine_Logo.png",
    );
    gen_manifest.step.dependOn(&install_logo.step);

    // Derived assets
    inline for (.{ "models", "textures" }) |subdir| {
        const install_derived = b.addInstallDirectory(.{
            .source_dir = b.path("assets/derived/" ++ subdir),
            .install_dir = .{ .custom = bundle_base ++ "/assets/derived/" ++ subdir },
            .install_subdir = "",
            .exclude_extensions = &.{ ".meta", ".DS_Store" },
        });
        gen_manifest.step.dependOn(&install_derived.step);
    }
    const install_registry = b.addInstallFileWithDir(
        b.path("assets/derived/asset_registry.json"),
        .{ .custom = bundle_base ++ "/assets/derived" },
        "asset_registry.json",
    );
    gen_manifest.step.dependOn(&install_registry.step);

    // Pre-compiled scripts
    inline for (.{"csharp"}) |subdir| {
        const scripts_source_dir = b.getInstallPath(.{ .custom = "scripts/" ++ subdir }, "");
        if (std.Io.Dir.cwd().access(b.graph.io, scripts_source_dir, .{})) |_| {
            const install_scripts = b.addInstallDirectory(.{
                .source_dir = .{ .cwd_relative = scripts_source_dir },
                .install_dir = .{ .custom = bundle_base ++ "/scripts/" ++ subdir },
                .install_subdir = "",
                .exclude_extensions = &.{".dSYM"},
            });
            gen_manifest.step.dependOn(&install_scripts.step);
        } else |_| {}
    }
}

// ─── Windows flat package ───────────────────────────────────────────────────

fn addWindowsPackage(
    b: *std.Build,
    package_step: *std.Build.Step,
    player: *std.Build.Step.Compile,
) void {
    const win_base = "package/GuavaGame";
    const pkg_player = b.addInstallArtifact(player, .{
        .dest_dir = .{ .override = .{ .custom = win_base } },
    });
    package_step.dependOn(&pkg_player.step);
    inline for (.{ "shaders", "models", "scenes", "ui" }) |subdir| {
        const install_assets = b.addInstallDirectory(.{
            .source_dir = b.path("assets/" ++ subdir),
            .install_dir = .{ .custom = win_base ++ "/assets/" ++ subdir },
            .install_subdir = "",
            .exclude_extensions = &.{ ".meta", ".DS_Store" },
        });
        package_step.dependOn(&install_assets.step);
    }
    inline for (.{ "models", "textures" }) |subdir| {
        const install_derived = b.addInstallDirectory(.{
            .source_dir = b.path("assets/derived/" ++ subdir),
            .install_dir = .{ .custom = win_base ++ "/assets/derived/" ++ subdir },
            .install_subdir = "",
            .exclude_extensions = &.{".meta"},
        });
        package_step.dependOn(&install_derived.step);
    }
}

// ─── Linux FHS package ──────────────────────────────────────────────────────

fn addLinuxPackage(
    b: *std.Build,
    package_step: *std.Build.Step,
    player: *std.Build.Step.Compile,
) void {
    const linux_base = "package/guava-game";
    const pkg_player = b.addInstallArtifact(player, .{
        .dest_dir = .{ .override = .{ .custom = linux_base ++ "/bin" } },
    });
    package_step.dependOn(&pkg_player.step);
    inline for (.{ "shaders", "models", "scenes", "ui" }) |subdir| {
        const install_assets = b.addInstallDirectory(.{
            .source_dir = b.path("assets/" ++ subdir),
            .install_dir = .{ .custom = linux_base ++ "/share/assets/" ++ subdir },
            .install_subdir = "",
            .exclude_extensions = &.{ ".meta", ".DS_Store" },
        });
        package_step.dependOn(&install_assets.step);
    }
    inline for (.{ "models", "textures" }) |subdir| {
        const install_derived = b.addInstallDirectory(.{
            .source_dir = b.path("assets/derived/" ++ subdir),
            .install_dir = .{ .custom = linux_base ++ "/share/assets/derived/" ++ subdir },
            .install_subdir = "",
            .exclude_extensions = &.{".meta"},
        });
        package_step.dependOn(&install_derived.step);
    }
}

// ─── C# NativeAOT script compilation ───────────────────────────────────────

fn addScriptsStep(b: *std.Build, target: std.Build.ResolvedTarget) void {
    const scripts_step = b.step("scripts", "Compile project scripts (C# NativeAOT)");

    const rid: ?[]const u8 = switch (target.result.os.tag) {
        .macos => switch (target.result.cpu.arch) {
            .aarch64 => "osx-arm64",
            .x86_64 => "osx-x64",
            else => null,
        },
        .linux => switch (target.result.cpu.arch) {
            .aarch64 => "linux-arm64",
            .x86_64 => "linux-x64",
            else => null,
        },
        .windows => switch (target.result.cpu.arch) {
            .aarch64 => "win-arm64",
            .x86_64 => "win-x64",
            else => null,
        },
        else => null,
    };

    const runtime_id = rid orelse return;
    const csharp_output_dir = b.getInstallPath(.{ .custom = "scripts/csharp" }, "");

    const dir = std.Io.Dir.cwd().openDir(b.graph.io, "examples/csharp", .{ .iterate = true }) catch return;
    var iter = dir.iterate();
    while (iter.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const csproj_glob = b.pathJoin(&.{ "examples/csharp", entry.name });
        const subdir = std.Io.Dir.cwd().openDir(b.graph.io, csproj_glob, .{ .iterate = true }) catch continue;
        var sub_iter = subdir.iterate();
        while (sub_iter.next(b.graph.io) catch null) |sub_entry| {
            if (sub_entry.kind != .file) continue;
            const name = sub_entry.name;
            if (name.len > 7 and std.mem.eql(u8, name[name.len - 7 ..], ".csproj")) {
                const csproj_path = b.pathJoin(&.{ "examples/csharp", entry.name, name });
                const dotnet_cmd = b.addSystemCommand(&.{
                    "dotnet",             "publish",             csproj_path,
                    "-c",                 "Release",             "-r",
                    runtime_id,           "-o",                  csharp_output_dir,
                    "-p:PublishAot=true", "-p:NativeLib=Shared", "-p:SelfContained=true",
                });
                scripts_step.dependOn(&dotnet_cmd.step);
                break;
            }
        }
    }
}
