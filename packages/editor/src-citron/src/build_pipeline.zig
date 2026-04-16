const std = @import("std");
const citron = @import("citron");
const build_options = @import("build_options");
const state_mod = @import("state.zig");

const globals = citron.globals;

pub const BuildPlatform = enum {
    macos,
    windows,
    linux,
};

pub const BuildState = struct {
    active: bool = false,
    cancel_requested: bool = false,
    child: ?std.process.Child = null,
};

var g_build: BuildState = .{};

pub fn isActive() bool {
    return g_build.active;
}

pub fn requestCancel() bool {
    if (!g_build.active) return false;
    g_build.cancel_requested = true;
    if (g_build.child) |*child| {
        child.kill(globals.global_io);
    }
    return true;
}

fn emitProgress(allocator: std.mem.Allocator, stage: []const u8, percent: u8, detail: ?[]const u8) void {
    const payload = if (detail) |d|
        std.json.Stringify.valueAlloc(allocator, .{ .stage = stage, .percent = percent, .detail = d }, .{}) catch return
    else
        std.json.Stringify.valueAlloc(allocator, .{ .stage = stage, .percent = percent }, .{}) catch return;
    defer allocator.free(payload);
    citron.ipc.enqueueEventJson("build.progress", payload);
}

fn emitLog(allocator: std.mem.Allocator, stage: []const u8, percent: u8, log: []const u8) void {
    const payload = std.json.Stringify.valueAlloc(allocator, .{ .stage = stage, .percent = percent, .log = log }, .{}) catch return;
    defer allocator.free(payload);
    citron.ipc.enqueueEventJson("build.progress", payload);
}

fn readScriptsDir(allocator: std.mem.Allocator, project_path: []const u8) []const u8 {
    const marker_path = std.fs.path.join(allocator, &.{ project_path, ".guava" }) catch return "Content/Scripts";
    defer allocator.free(marker_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(globals.global_io, marker_path, allocator, .limited(1024 * 1024)) catch return "Content/Scripts";
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return "Content/Scripts";
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("scripts_dir")) |val| {
            if (val == .string and val.string.len > 0) {
                return allocator.dupe(u8, val.string) catch return "Content/Scripts";
            }
        }
    }
    return "Content/Scripts";
}

fn readGameName(allocator: std.mem.Allocator, project_path: []const u8) []const u8 {
    const marker_path = std.fs.path.join(allocator, &.{ project_path, ".guava" }) catch return "Game";
    defer allocator.free(marker_path);

    const bytes = std.Io.Dir.cwd().readFileAlloc(globals.global_io, marker_path, allocator, .limited(1024 * 1024)) catch return "Game";
    defer allocator.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{}) catch return "Game";
    defer parsed.deinit();

    if (parsed.value == .object) {
        if (parsed.value.object.get("name")) |val| {
            if (val == .string and val.string.len > 0) {
                return allocator.dupe(u8, val.string) catch return "Game";
            }
        }
    }
    return "Game";
}

fn resolveEngineRoot(allocator: std.mem.Allocator) ![]u8 {
    const exe_dir = std.fs.path.dirname(globals.exe_path) orelse ".";
    // Bundled: ../Resources/engine/ for a packaged app
    const bundled = try std.fs.path.join(allocator, &.{ exe_dir, "..", "Resources", "engine" });
    if (std.Io.Dir.cwd().access(globals.global_io, bundled, .{})) |_| {
        return bundled;
    } else |_| {
        allocator.free(bundled);
    }
    // Fallback to the workspace engine directory
    return allocator.dupe(u8, build_options.engine_root_fallback);
}

fn runCmd(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !struct { stdout: []u8, stderr: []u8, success: bool } {
    const result = try std.process.run(allocator, globals.global_io, .{
        .argv = argv,
        .cwd = if (cwd) |c| .{ .path = c } else .{ .path = "." },
        .stdout_limit = .limited(256 * 1024),
        .stderr_limit = .limited(256 * 1024),
    });
    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    return .{ .stdout = result.stdout, .stderr = result.stderr, .success = success };
}

fn pathExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(globals.global_io, path, .{}) catch return false;
    return true;
}

fn copyTree(allocator: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const result = try runCmd(allocator, &.{ "/bin/cp", "-R", src, dst }, null);
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.success) return error.CopyFailed;
}

fn removeItem(allocator: std.mem.Allocator, path: []const u8) void {
    const result = runCmd(allocator, &.{ "/bin/rm", "-rf", path }, null) catch return;
    allocator.free(result.stdout);
    allocator.free(result.stderr);
}

/// Full build pipeline: compile player → assemble package → fix dylibs
pub fn buildPackage(
    allocator: std.mem.Allocator,
    project_path: []const u8,
    output_dir: []const u8,
    optimize: []const u8,
) ![]u8 {
    if (g_build.active) return error.BuildAlreadyActive;

    g_build = .{ .active = true };
    defer {
        g_build = .{};
    }

    const engine_root = try resolveEngineRoot(allocator);
    defer allocator.free(engine_root);

    const game_name = readGameName(allocator, project_path);
    const game_name_owned = if (std.mem.eql(u8, game_name, "Game")) game_name else game_name;
    _ = game_name_owned;

    // ── Stage 1: Compile guava-player ─────────────────────────
    emitProgress(allocator, "compile", 0, "Compiling guava-player...");

    if (g_build.cancel_requested) return error.BuildCancelled;

    const zig_exe = resolveZigExe(allocator);
    defer if (!std.mem.eql(u8, zig_exe, "zig")) allocator.free(zig_exe);

    {
        const optimize_arg = try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{optimize});
        defer allocator.free(optimize_arg);

        const argv = [_][]const u8{ zig_exe, "build", "player", optimize_arg };
        const result = try std.process.run(allocator, globals.global_io, .{
            .argv = &argv,
            .cwd = .{ .path = engine_root },
            .stdout_limit = .limited(256 * 1024),
            .stderr_limit = .limited(256 * 1024),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (result.stderr.len > 0) {
            emitLog(allocator, "compile", 15, result.stderr);
        }

        const success = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!success) {
            emitProgress(allocator, "error", 0, "Compilation failed");
            return error.CompilationFailed;
        }
    }

    emitProgress(allocator, "compile", 30, "Compilation complete");

    if (g_build.cancel_requested) return error.BuildCancelled;

    // ── Stage 2: Assemble macOS .app bundle ───────────────────
    emitProgress(allocator, "package", 35, "Assembling package...");

    const bundle_root = try std.fs.path.join(allocator, &.{ output_dir, try std.fmt.allocPrint(allocator, "{s}.app", .{game_name}), "Contents" });
    defer allocator.free(bundle_root);

    const bin_dir = try std.fs.path.join(allocator, &.{ bundle_root, "MacOS" });
    defer allocator.free(bin_dir);
    const assets_dir = try std.fs.path.join(allocator, &.{ bundle_root, "Resources" });
    defer allocator.free(assets_dir);
    const frameworks_dir = try std.fs.path.join(allocator, &.{ bundle_root, "Frameworks" });
    defer allocator.free(frameworks_dir);

    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), globals.global_io, bin_dir);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), globals.global_io, assets_dir);
    try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), globals.global_io, frameworks_dir);

    // Copy player binary
    {
        const player_src = try std.fs.path.join(allocator, &.{ engine_root, "zig-out", "bin", "guava-player" });
        defer allocator.free(player_src);
        const player_dst = try std.fs.path.join(allocator, &.{ bin_dir, "guava-player" });
        defer allocator.free(player_dst);

        emitLog(allocator, "package", 40, "Copy guava-player binary");
        const cp_result = try runCmd(allocator, &.{ "/bin/cp", player_src, player_dst }, null);
        defer allocator.free(cp_result.stdout);
        defer allocator.free(cp_result.stderr);
        if (!cp_result.success) return error.CopyFailed;

        const chmod_result = try runCmd(allocator, &.{ "/bin/chmod", "+x", player_dst }, null);
        defer allocator.free(chmod_result.stdout);
        defer allocator.free(chmod_result.stderr);
    }

    if (g_build.cancel_requested) return error.BuildCancelled;

    // Copy engine shaders
    {
        const shaders_src = try std.fs.path.join(allocator, &.{ engine_root, "assets", "shaders" });
        defer allocator.free(shaders_src);
        if (pathExists(shaders_src)) {
            const shaders_dst = try std.fs.path.join(allocator, &.{ assets_dir, "assets", "shaders" });
            defer allocator.free(shaders_dst);
            try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), globals.global_io, std.fs.path.dirname(shaders_dst) orelse ".");
            emitLog(allocator, "package", 45, "Copy engine shaders");
            try copyTree(allocator, shaders_src, shaders_dst);
        }
    }

    // Copy engine logo
    {
        const logo_src = try std.fs.path.join(allocator, &.{ engine_root, "assets", "Guava_Engine_Logo.png" });
        defer allocator.free(logo_src);
        if (pathExists(logo_src)) {
            const logo_dst_dir = try std.fs.path.join(allocator, &.{ assets_dir, "assets" });
            defer allocator.free(logo_dst_dir);
            try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), globals.global_io, logo_dst_dir);
            const logo_dst = try std.fs.path.join(allocator, &.{ logo_dst_dir, "Guava_Engine_Logo.png" });
            defer allocator.free(logo_dst);
            const cp = try runCmd(allocator, &.{ "/bin/cp", logo_src, logo_dst }, null);
            allocator.free(cp.stdout);
            allocator.free(cp.stderr);
        }
    }

    emitProgress(allocator, "package", 50, "Copying project assets...");

    // Copy project Content/
    {
        const content_src = try std.fs.path.join(allocator, &.{ project_path, "Content" });
        defer allocator.free(content_src);
        if (pathExists(content_src)) {
            const content_dst = try std.fs.path.join(allocator, &.{ assets_dir, "Content" });
            defer allocator.free(content_dst);
            emitLog(allocator, "package", 55, "Copy project Content/");
            try copyTree(allocator, content_src, content_dst);
            // Post-process scene files: relativize asset paths
            try relativizeScenePaths(allocator, content_dst, project_path);
        }
    }

    if (g_build.cancel_requested) return error.BuildCancelled;

    // Copy project scripts
    {
        const scripts_dir_name = readScriptsDir(allocator, project_path);
        const scripts_src = try std.fs.path.join(allocator, &.{ project_path, scripts_dir_name });
        defer allocator.free(scripts_src);
        if (pathExists(scripts_src)) {
            const scripts_dst = try std.fs.path.join(allocator, &.{ assets_dir, scripts_dir_name });
            defer allocator.free(scripts_dst);
            emitLog(allocator, "package", 60, "Copy project scripts");
            try copyTree(allocator, scripts_src, scripts_dst);
        }
    }

    // Copy Derived/
    {
        const derived_src = try std.fs.path.join(allocator, &.{ project_path, "Derived" });
        defer allocator.free(derived_src);
        if (pathExists(derived_src)) {
            const derived_dst = try std.fs.path.join(allocator, &.{ assets_dir, "Derived" });
            defer allocator.free(derived_dst);
            emitLog(allocator, "package", 65, "Copy Derived/");
            try copyTree(allocator, derived_src, derived_dst);
        }
    }

    // Copy engine derived assets (models, textures)
    for ([_][]const u8{ "models", "textures" }) |subdir| {
        const src = try std.fs.path.join(allocator, &.{ engine_root, "assets", "derived", subdir });
        defer allocator.free(src);
        if (pathExists(src)) {
            const dst = try std.fs.path.join(allocator, &.{ assets_dir, "assets", "derived", subdir });
            defer allocator.free(dst);
            try std.Io.Dir.createDirPath(std.Io.Dir.cwd(), globals.global_io, std.fs.path.dirname(dst) orelse ".");
            try copyTree(allocator, src, dst);
        }
    }

    // Copy .guava config
    {
        const guava_src = try std.fs.path.join(allocator, &.{ project_path, ".guava" });
        defer allocator.free(guava_src);
        const guava_dst = try std.fs.path.join(allocator, &.{ assets_dir, ".guava" });
        defer allocator.free(guava_dst);
        if (pathExists(guava_src)) {
            const cp = try runCmd(allocator, &.{ "/bin/cp", guava_src, guava_dst }, null);
            allocator.free(cp.stdout);
            allocator.free(cp.stderr);
        }
    }

    emitProgress(allocator, "package", 75, "Writing Info.plist...");

    // Write Info.plist
    {
        const safe_bundle_id = try sanitizeBundleId(allocator, game_name);
        defer allocator.free(safe_bundle_id);

        const plist = try std.fmt.allocPrint(allocator,
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
            \\  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\  <key>CFBundleExecutable</key>
            \\  <string>guava-player</string>
            \\  <key>CFBundleIdentifier</key>
            \\  <string>com.guava.{s}</string>
            \\  <key>CFBundleInfoDictionaryVersion</key>
            \\  <string>6.0</string>
            \\  <key>CFBundleName</key>
            \\  <string>{s}</string>
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
        , .{ safe_bundle_id, game_name });
        defer allocator.free(plist);

        const plist_path = try std.fs.path.join(allocator, &.{ bundle_root, "Info.plist" });
        defer allocator.free(plist_path);

        try std.Io.Dir.writeFile(std.Io.Dir.cwd(), globals.global_io, .{
            .sub_path = plist_path,
            .data = plist,
        });
    }

    // Copy SDL3 framework
    {
        const sdl_src = "/opt/homebrew/lib/libSDL3.0.dylib";
        if (pathExists(sdl_src)) {
            emitLog(allocator, "package", 80, "Copy SDL3 framework");
            const sdl_dst = try std.fs.path.join(allocator, &.{ frameworks_dir, "libSDL3.0.dylib" });
            defer allocator.free(sdl_dst);
            removeItem(allocator, sdl_dst);
            const cp = try runCmd(allocator, &.{ "/bin/cp", sdl_src, sdl_dst }, null);
            allocator.free(cp.stdout);
            allocator.free(cp.stderr);
        }
    }

    if (g_build.cancel_requested) return error.BuildCancelled;

    // ── Stage 3: Fix dylib references ─────────────────────────
    emitProgress(allocator, "finalize", 90, "Fixing dylib references...");

    {
        const player_bin = try std.fs.path.join(allocator, &.{ bin_dir, "guava-player" });
        defer allocator.free(player_bin);

        if (pathExists(player_bin)) {
            const result = try runCmd(allocator, &.{
                "/usr/bin/install_name_tool",
                "-change",
                "/opt/homebrew/lib/libSDL3.0.dylib",
                "@executable_path/../Frameworks/libSDL3.0.dylib",
                player_bin,
            }, null);
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
        }
    }

    // Ad-hoc codesign the output
    {
        const app_path = try std.fs.path.join(allocator, &.{ output_dir, try std.fmt.allocPrint(allocator, "{s}.app", .{game_name}) });
        defer allocator.free(app_path);

        emitLog(allocator, "finalize", 95, "Code signing...");
        const result = try runCmd(allocator, &.{
            "/usr/bin/codesign",
            "--force",
            "--deep",
            "--sign",
            "-",
            app_path,
        }, null);
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }

    emitProgress(allocator, "done", 100, "Build complete");

    const out_path = try std.fmt.allocPrint(allocator, "{s}/{s}.app", .{ output_dir, game_name });
    return out_path;
}

fn sanitizeBundleId(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var result = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        result[i] = switch (c) {
            'A'...'Z' => c + 32, // lowercase
            'a'...'z', '0'...'9', '-', '.' => c,
            ' ' => '-',
            else => '-',
        };
    }
    return result;
}

fn resolveZigExe(allocator: std.mem.Allocator) []const u8 {
    // Check if zig is on PATH first
    const result = runCmd(allocator, &.{ "/usr/bin/which", "zig" }, null) catch return "zig";
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.success and result.stdout.len > 0) {
        const trimmed = std.mem.trim(u8, result.stdout, "\r\n ");
        return allocator.dupe(u8, trimmed) catch return "zig";
    }
    return "zig";
}

/// Rewrite absolute `source_path` entries in .guava_scene files
/// so they become relative to the project root.
fn relativizeScenePaths(allocator: std.mem.Allocator, content_dir: []const u8, project_root: []const u8) !void {
    // Use find + sed for simplicity — the pattern is:
    // "source_path": "/absolute/project/path/Content/..." → "source_path": "Content/..."
    const escaped_root = try escapeForSed(allocator, project_root);
    defer allocator.free(escaped_root);

    const slash_root = if (project_root[project_root.len - 1] == '/')
        escaped_root
    else
        try std.fmt.allocPrint(allocator, "{s}/", .{escaped_root});
    const free_slash = !std.mem.eql(u8, slash_root, escaped_root);
    defer if (free_slash) allocator.free(slash_root);

    const sed_expr = try std.fmt.allocPrint(allocator, "s|\"source_path\": \"{s}|\"source_path\": \"|g", .{slash_root});
    defer allocator.free(sed_expr);

    // Find all .guava_scene files and process them
    const find_result = try runCmd(allocator, &.{
        "/usr/bin/find", content_dir, "-name", "*.guava_scene", "-type", "f",
    }, null);
    defer allocator.free(find_result.stdout);
    defer allocator.free(find_result.stderr);

    var iter = std.mem.splitScalar(u8, find_result.stdout, '\n');
    while (iter.next()) |line| {
        const file_path = std.mem.trim(u8, line, " \r\t");
        if (file_path.len == 0) continue;
        const sed = try runCmd(allocator, &.{ "/usr/bin/sed", "-i", "", sed_expr, file_path }, null);
        allocator.free(sed.stdout);
        allocator.free(sed.stderr);
    }
}

fn escapeForSed(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (input) |c| {
        switch (c) {
            '/', '|', '&', '\\' => {
                try out.append(allocator, '\\');
                try out.append(allocator, c);
            },
            else => try out.append(allocator, c),
        }
    }
    return try out.toOwnedSlice(allocator);
}
