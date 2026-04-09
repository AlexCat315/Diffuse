const std = @import("std");
const sources = @import("build/sources.zig");
const compile_commands = @import("build/compile_commands.zig");
const packaging = @import("build/packaging.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const default_sdl_prefix = switch (target.result.os.tag) {
        .macos => "/opt/homebrew",
        .windows => "C:/SDL3",
        else => "/usr/local",
    };
    const sdl_prefix = b.option([]const u8, "sdl-prefix", "Prefix path for an SDL3 installation") orelse default_sdl_prefix;

    // ── Shader codegen ──────────────────────────────────────────────────────
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

    const shaders_step = b.step("shaders", "Compile shaders and regenerate reflection metadata");
    shaders_step.dependOn(&run_shader_codegen.step);

    // ── Engine module ───────────────────────────────────────────────────────
    const engine_mod = b.addModule("guava", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    sources.configureEngineModule(b, engine_mod, target.result.os.tag, sdl_prefix);

    // ── Executables ─────────────────────────────────────────────────────────
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
    exe.linker_allow_shlib_undefined = true;
    exe.step.dependOn(&run_shader_codegen.step);
    b.installArtifact(exe);

    const player = b.addExecutable(.{
        .name = "guava-player",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/player_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "guava", .module = engine_mod },
            },
        }),
    });
    player.linkLibC();
    player.linkLibCpp();
    player.linker_allow_shlib_undefined = true;
    player.step.dependOn(&run_shader_codegen.step);
    b.installArtifact(player);

    // ── Run steps ───────────────────────────────────────────────────────────
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the engine directly");
    run_step.dependOn(&run_cmd.step);

    const run_engine_cmd = b.addRunArtifact(exe);
    run_engine_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_engine_cmd.addArgs(args);

    const run_engine_step = b.step("run-engine", "Run the engine directly (alias for run)");
    run_engine_step.dependOn(&run_engine_cmd.step);

    const run_player_cmd = b.addRunArtifact(player);
    run_player_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_player_cmd.addArgs(args);

    const build_player_step = b.step("player", "Build the standalone player runtime");
    build_player_step.dependOn(b.getInstallStep());

    const run_player_step = b.step("run-player", "Run the standalone player runtime");
    run_player_step.dependOn(&run_player_cmd.step);

    // Player smoke test
    const player_smoke_cmd = b.addRunArtifact(player);
    player_smoke_cmd.step.dependOn(b.getInstallStep());
    player_smoke_cmd.addArgs(&.{ "--frames", "5" });
    player_smoke_cmd.setCwd(b.path("."));

    const test_player_step = b.step("test-player", "Run player-only smoke test (boot → 5 frames → shutdown)");
    test_player_step.dependOn(&player_smoke_cmd.step);

    // ── Electron Editor ─────────────────────────────────────────────────────
    const run_editor_cmd = b.addSystemCommand(&.{ "npm", "run", "dev" });
    run_editor_cmd.setCwd(b.path("../editor"));
    run_editor_cmd.step.dependOn(b.getInstallStep());
    run_editor_cmd.setEnvironmentVariable("NODE_ENV", "development");

    const run_editor_step = b.step("run-editor", "Build engine & launch the Electron editor (dev mode)");
    run_editor_step.dependOn(&run_editor_cmd.step);

    // ── Validate & render-test ──────────────────────────────────────────────
    const validate_cmd = b.addRunArtifact(exe);
    validate_cmd.step.dependOn(b.getInstallStep());
    validate_cmd.addArg("validate");
    if (b.args) |args| validate_cmd.addArgs(args);

    const validate_step = b.step("validate", "Validate project assets");
    validate_step.dependOn(&validate_cmd.step);

    const render_test_cmd = b.addRunArtifact(exe);
    render_test_cmd.step.dependOn(b.getInstallStep());
    render_test_cmd.addArg("render-test");
    if (b.args) |args| render_test_cmd.addArgs(args);

    const render_test_step = b.step("render-test", "Run automated render tests with pixel analysis");
    render_test_step.dependOn(&render_test_cmd.step);

    // ── Tests ───────────────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_main.zig"),
        .target = target,
    });
    sources.configureEngineModule(b, test_mod, target.result.os.tag, sdl_prefix);

    const mod_tests = b.addTest(.{ .root_module = test_mod });
    mod_tests.linkLibC();
    mod_tests.linkLibCpp();
    mod_tests.step.dependOn(&run_shader_codegen.step);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    exe_tests.linkLibC();
    exe_tests.linkLibCpp();
    exe_tests.step.dependOn(&run_shader_codegen.step);

    const run_mod_tests = b.addRunArtifact(mod_tests);
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    const player_tests = b.addTest(.{ .root_module = player.root_module });
    player_tests.linkLibC();
    player_tests.linkLibCpp();
    player_tests.step.dependOn(&run_shader_codegen.step);

    const run_player_tests = b.addRunArtifact(player_tests);
    const test_player_unit_step = b.step("test-player-unit", "Run player module unit tests");
    test_player_unit_step.dependOn(&run_player_tests.step);
    test_step.dependOn(&run_player_tests.step);

    const script_vm_test_mod = b.createModule(.{
        .root_source_file = b.path("src/script_vm_test_main.zig"),
        .target = target,
    });
    sources.configureEngineModule(b, script_vm_test_mod, target.result.os.tag, sdl_prefix);

    const script_vm_tests = b.addTest(.{ .root_module = script_vm_test_mod });
    script_vm_tests.linkLibC();
    script_vm_tests.linkLibCpp();
    script_vm_tests.step.dependOn(&run_shader_codegen.step);

    const run_script_vm_tests = b.addRunArtifact(script_vm_tests);
    const script_vm_test_step = b.step("test-script-vm", "Run script VM tests");
    script_vm_test_step.dependOn(&run_script_vm_tests.step);

    const run_csharp_nativeaot_tests = b.addRunArtifact(script_vm_tests);
    run_csharp_nativeaot_tests.setEnvironmentVariable("GUAVA_RUN_NATIVEAOT_TESTS", "1");
    const csharp_nativeaot_test_step = b.step("test-csharp-nativeaot", "Run C# NativeAOT script VM integration tests");
    csharp_nativeaot_test_step.dependOn(&run_csharp_nativeaot_tests.step);

    const console_test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_console.zig"),
        .target = target,
    });
    sources.configureEngineModule(b, console_test_mod, target.result.os.tag, sdl_prefix);

    const console_test_exe = b.addExecutable(.{
        .name = "test-console",
        .root_module = console_test_mod,
    });
    console_test_exe.linkLibC();
    console_test_exe.linkLibCpp();
    console_test_exe.step.dependOn(&run_shader_codegen.step);

    const console_test_cmd = b.addRunArtifact(console_test_exe);
    const console_test_step = b.step("test-console", "Test console logging");
    console_test_step.dependOn(&console_test_cmd.step);

    // ── Packaging, cook, scripts ────────────────────────────────────────────
    packaging.addPackageSteps(b, target, exe, player, sdl_prefix);

    // ── compile-commands (clangd) ───────────────────────────────────────────
    const compile_commands_step = b.step("compile-commands", "Generate compile_commands.json for clangd (engine + Qt)");

    // Build Qt editor to generate its compile_commands.json
    const cmake_configure = b.addSystemCommand(&.{
        "cmake",
        "-B",
        "packages/editor_qt/build",
        "-S",
        "packages/editor_qt",
        "-G",
        "Ninja",
        "-DCMAKE_BUILD_TYPE=Release",
    });

    const build_qt_cmd = b.addSystemCommand(&.{
        "cmake",
        "--build",
        "packages/editor_qt/build",
        "--config",
        "Release",
    });
    build_qt_cmd.step.dependOn(&cmake_configure.step);

    // Generate engine compile_commands.json
    const update_compile_commands = b.addUpdateSourceFiles();
    update_compile_commands.addBytesToSource(
        compile_commands.generateCompileCommandsJson(b, target.result.os.tag, sdl_prefix),
        "compile_commands.json",
    );

    // Merge Qt compile_commands.json if it exists
    const merge_compile_commands = b.addSystemCommand(&.{
        "python3",
        "packages/engine/build/merge_compile_commands.py",
    });
    merge_compile_commands.step.dependOn(&build_qt_cmd.step);
    merge_compile_commands.step.dependOn(&update_compile_commands.step);

    compile_commands_step.dependOn(&merge_compile_commands.step);
}
