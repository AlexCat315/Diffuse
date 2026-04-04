const std = @import("std");

const engine_include_paths = [_][]const u8{
    "third_party/stb",
    "third_party/imgui",
    "third_party/jolt",
    "third_party/lunasvg/include",
    "third_party/lunasvg/source",
    "third_party/lunasvg/plutovg/include",
    "third_party/lunasvg/plutovg/source",
    "third_party/soloud/include",
    "third_party/recast/Recast/Include",
    "third_party/recast/Detour/Include",
    "third_party/recast/DetourCrowd/Include",
    "src/engine/assets",
    "src/engine/navigation",
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
    "src/engine/assets/stb_image_impl.c",
    "src/engine/assets/stb_image_write_impl.c",
};

/// SoLoud audio engine core implementation
const soloud_core_cpp_sources = [_][]const u8{
    "third_party/soloud/src/core/soloud.cpp",
    "third_party/soloud/src/core/soloud_audiosource.cpp",
    "third_party/soloud/src/core/soloud_bus.cpp",
    "third_party/soloud/src/core/soloud_core_3d.cpp",
    "third_party/soloud/src/core/soloud_core_basicops.cpp",
    "third_party/soloud/src/core/soloud_core_faderops.cpp",
    "third_party/soloud/src/core/soloud_core_filterops.cpp",
    "third_party/soloud/src/core/soloud_core_getters.cpp",
    "third_party/soloud/src/core/soloud_core_setters.cpp",
    "third_party/soloud/src/core/soloud_core_voicegroup.cpp",
    "third_party/soloud/src/core/soloud_core_voiceops.cpp",
    "third_party/soloud/src/core/soloud_fader.cpp",
    "third_party/soloud/src/core/soloud_fft.cpp",
    "third_party/soloud/src/core/soloud_fft_lut.cpp",
    "third_party/soloud/src/core/soloud_file.cpp",
    "third_party/soloud/src/core/soloud_filter.cpp",
    "third_party/soloud/src/core/soloud_misc.cpp",
    "third_party/soloud/src/core/soloud_queue.cpp",
    "third_party/soloud/src/core/soloud_thread.cpp",
};

/// SoLoud WAV audio format support (PCM, OGG Vorbis, MP3, FLAC via dr_libs and stb_vorbis)
const soloud_wav_cpp_sources = [_][]const u8{
    "third_party/soloud/src/audiosource/wav/soloud_wav.cpp",
    "third_party/soloud/src/audiosource/wav/soloud_wavstream.cpp",
    "third_party/soloud/src/audiosource/wav/dr_impl.cpp",
};

const soloud_extra_audiosource_cpp_sources = [_][]const u8{
    "third_party/soloud/src/audiosource/ay/chipplayer.cpp",
    "third_party/soloud/src/audiosource/ay/sndbuffer.cpp",
    "third_party/soloud/src/audiosource/ay/sndchip.cpp",
    "third_party/soloud/src/audiosource/ay/sndrender.cpp",
    "third_party/soloud/src/audiosource/ay/soloud_ay.cpp",
    "third_party/soloud/src/audiosource/monotone/soloud_monotone.cpp",
    "third_party/soloud/src/audiosource/noise/soloud_noise.cpp",
    "third_party/soloud/src/audiosource/openmpt/soloud_openmpt.cpp",
    "third_party/soloud/src/audiosource/sfxr/soloud_sfxr.cpp",
    "third_party/soloud/src/audiosource/speech/darray.cpp",
    "third_party/soloud/src/audiosource/speech/klatt.cpp",
    "third_party/soloud/src/audiosource/speech/resonator.cpp",
    "third_party/soloud/src/audiosource/speech/soloud_speech.cpp",
    "third_party/soloud/src/audiosource/speech/tts.cpp",
    "third_party/soloud/src/audiosource/tedsid/sid.cpp",
    "third_party/soloud/src/audiosource/tedsid/soloud_tedsid.cpp",
    "third_party/soloud/src/audiosource/tedsid/ted.cpp",
    "third_party/soloud/src/audiosource/vic/soloud_vic.cpp",
    "third_party/soloud/src/audiosource/vizsn/soloud_vizsn.cpp",
};

const soloud_filter_cpp_sources = [_][]const u8{
    "third_party/soloud/src/filter/soloud_bassboostfilter.cpp",
    "third_party/soloud/src/filter/soloud_biquadresonantfilter.cpp",
    "third_party/soloud/src/filter/soloud_dcremovalfilter.cpp",
    "third_party/soloud/src/filter/soloud_duckfilter.cpp",
    "third_party/soloud/src/filter/soloud_echofilter.cpp",
    "third_party/soloud/src/filter/soloud_eqfilter.cpp",
    "third_party/soloud/src/filter/soloud_fftfilter.cpp",
    "third_party/soloud/src/filter/soloud_flangerfilter.cpp",
    "third_party/soloud/src/filter/soloud_freeverbfilter.cpp",
    "third_party/soloud/src/filter/soloud_lofifilter.cpp",
    "third_party/soloud/src/filter/soloud_robotizefilter.cpp",
    "third_party/soloud/src/filter/soloud_waveshaperfilter.cpp",
};

const soloud_support_c_sources = [_][]const u8{
    "third_party/soloud/src/audiosource/wav/stb_vorbis.c",
    "src/engine/audio/openmpt_stub.c",
};

/// SoLoud MiniAudio backend (portable audio across Windows/macOS/Linux)
const soloud_backend_cpp_sources = [_][]const u8{
    "third_party/soloud/src/backend/miniaudio/soloud_miniaudio.cpp",
};

/// SoLoud C language API wrapper
const soloud_c_api_cpp_sources = [_][]const u8{
    "third_party/soloud/src/c_api/soloud_c.cpp",
};

const engine_cpp_sources = [_][]const u8{
    "third_party/imgui/imgui.cpp",
    "third_party/imgui/imgui_draw.cpp",
    "third_party/imgui/imgui_tables.cpp",
    "third_party/imgui/imgui_widgets.cpp",
    "third_party/imgui/backends/imgui_impl_sdl3.cpp",
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
    "src/engine/ui/imgui_widgets.cpp",
    "src/engine/physics/jolt_bridge.cpp",
    "src/engine/navigation/recast_bridge.cpp",
};

const macos_objcpp_sources = [_][]const u8{
    "src/engine/platform/window_native_macos.mm",
    "src/engine/render/path_trace/path_trace_denoise_bridge.mm",
    "src/engine/rt/metal_rt_bridge.mm",
    "src/engine/rhi/metal/metal_rhi_bridge.mm",
    "third_party/imgui/backends/imgui_impl_metal.mm",
    "src/engine/ui/imgui_metal_backend.mm",
};

const windows_cpp_sources = [_][]const u8{
    "src/engine/platform/window_native_windows.cpp",
};

const vulkan_c_sources = [_][]const u8{
    "src/engine/platform/window_vulkan_sdl.c",
    "src/engine/rhi/vulkan/vk_bridge.c",
};

const vulkan_c_flags = [_][]const u8{
    "-std=c11",
};

const vulkan_cpp_sources = [_][]const u8{
    "third_party/imgui/backends/imgui_impl_vulkan.cpp",
    "src/engine/ui/imgui_vulkan_backend.cpp",
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

/// SoLoud specific compilation flags for MiniAudio backend
const soloud_cpp_flags = [_][]const u8{
    "-std=c++17",
    "-DWITH_MINIAUDIO=1",
};

const soloud_c_flags = [_][]const u8{
    "-std=c11",
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

    const project_mod = b.addModule("guava_project", .{
        .root_source_file = b.path("src/project.zig"),
        .target = target,
    });

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

    const launcher = b.addExecutable(.{
        .name = "guava-launcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/launcher/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "guava_project", .module = project_mod },
            },
        }),
    });
    b.installArtifact(launcher);

    const engine_binary_name = if (target.result.os.tag == .windows) "guava-engine.exe" else "guava-engine";
    const installed_engine_path = b.getInstallPath(.bin, engine_binary_name);

    const run_cmd = b.addRunArtifact(launcher);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addArg("--engine");
    run_cmd.addArg(installed_engine_path);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the project launcher");
    run_step.dependOn(&run_cmd.step);

    const run_engine_cmd = b.addRunArtifact(exe);
    run_engine_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_engine_cmd.addArgs(args);
    }

    const run_engine_step = b.step("run-engine", "Run the engine directly");
    run_engine_step.dependOn(&run_engine_cmd.step);

    const run_player_cmd = b.addRunArtifact(player);
    run_player_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_player_cmd.addArgs(args);
    }

    const build_player_step = b.step("player", "Build the standalone player runtime");
    build_player_step.dependOn(&player.step);

    const run_player_step = b.step("run-player", "Run the standalone player runtime");
    run_player_step.dependOn(&run_player_cmd.step);

    // ---- Player smoke test: boot → 5 frames → shutdown (no project) ----
    const player_smoke_cmd = b.addRunArtifact(player);
    player_smoke_cmd.step.dependOn(b.getInstallStep());
    player_smoke_cmd.addArgs(&.{ "--frames", "5" });
    player_smoke_cmd.setCwd(b.path(".")); // ensure cwd is workspace root (has assets/)

    const test_player_step = b.step("test-player", "Run player-only smoke test (boot → 5 frames → shutdown)");
    test_player_step.dependOn(&player_smoke_cmd.step);

    const run_launcher_cmd = b.addRunArtifact(launcher);
    run_launcher_cmd.step.dependOn(b.getInstallStep());
    run_launcher_cmd.addArg("--engine");
    run_launcher_cmd.addArg(installed_engine_path);
    if (b.args) |args| {
        run_launcher_cmd.addArgs(args);
    }

    const build_launcher_step = b.step("launcher", "Build the project launcher");
    build_launcher_step.dependOn(&launcher.step);

    const run_launcher_step = b.step("run-launcher", "Run the project launcher");
    run_launcher_step.dependOn(&run_launcher_cmd.step);

    // ---- Electron Editor: build engine + run electron dev server ----
    const run_editor_cmd = b.addSystemCommand(&.{
        "npm", "run", "dev",
    });
    run_editor_cmd.setCwd(b.path("../editor"));
    run_editor_cmd.step.dependOn(b.getInstallStep());
    // Pass through VITE_DEV_SERVER_URL so Electron uses the Vite dev server
    run_editor_cmd.setEnvironmentVariable("NODE_ENV", "development");

    const run_editor_step = b.step("run-editor", "Build engine & launch the Electron editor (dev mode)");
    run_editor_step.dependOn(&run_editor_cmd.step);

    const validate_cmd = b.addRunArtifact(exe);
    validate_cmd.step.dependOn(b.getInstallStep());
    validate_cmd.addArg("validate");
    if (b.args) |args| {
        validate_cmd.addArgs(args);
    }

    const validate_step = b.step("validate", "Validate project assets");
    validate_step.dependOn(&validate_cmd.step);

    const render_test_cmd = b.addRunArtifact(exe);
    render_test_cmd.step.dependOn(b.getInstallStep());
    render_test_cmd.addArg("render-test");
    if (b.args) |args| {
        render_test_cmd.addArgs(args);
    }

    const render_test_step = b.step("render-test", "Run automated render tests with pixel analysis");
    render_test_step.dependOn(&render_test_cmd.step);

    // 为 engine_mod 测试创建一个带日志配置的自定义根
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_main.zig"),
        .target = target,
    });
    configureEngineModule(b, test_mod, target.result.os.tag, sdl_prefix);

    const mod_tests = b.addTest(.{
        .root_module = test_mod,
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

    const player_tests = b.addTest(.{
        .root_module = player.root_module,
    });
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
    configureEngineModule(b, script_vm_test_mod, target.result.os.tag, sdl_prefix);

    const script_vm_tests = b.addTest(.{
        .root_module = script_vm_test_mod,
    });
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
    configureEngineModule(b, console_test_mod, target.result.os.tag, sdl_prefix);

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

    const shaders_step = b.step("shaders", "Compile shaders and regenerate reflection metadata");
    shaders_step.dependOn(&run_shader_codegen.step);

    // ---- Package step: build a distributable game bundle ----
    const package_step = b.step("package", "Build distributable game package (use -Doptimize=ReleaseSafe)");
    if (target.result.os.tag == .macos) {
        const bundle_base = "package/GuavaGame.app/Contents";

        // Build manifest generator (declared early so install steps can register as deps)
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
        const install_plist = b.addInstallFileWithDir(
            plist_source,
            .{ .custom = bundle_base },
            "Info.plist",
        );
        gen_manifest.step.dependOn(&install_plist.step);

        // SDL3 dylib → .app/Contents/Frameworks/
        const sdl_dylib_path = b.pathJoin(&.{ sdl_prefix, "lib", "libSDL3.0.dylib" });
        const install_sdl = b.addInstallFileWithDir(
            .{ .cwd_relative = sdl_dylib_path },
            .{ .custom = bundle_base ++ "/Frameworks" },
            "libSDL3.0.dylib",
        );
        gen_manifest.step.dependOn(&install_sdl.step);

        // Rewrite the SDL3 load path so the player finds the bundled dylib
        const installed_player_path = b.getInstallPath(
            .{ .custom = bundle_base ++ "/MacOS" },
            "guava-player",
        );
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

        // Source assets → .app/Contents/assets/ (excluding .meta and .DS_Store)
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

        // Cooked/derived assets → .app/Contents/assets/derived/
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

        // Pre-compiled scripts → .app/Contents/scripts/ (NativeAOT)
        // These are staged from zig-out/scripts/ which is populated by `zig build scripts`
        inline for (.{"csharp"}) |subdir| {
            const scripts_source_dir = b.getInstallPath(.{ .custom = "scripts/" ++ subdir }, "");
            if (std.fs.cwd().access(scripts_source_dir, .{})) |_| {
                const install_scripts = b.addInstallDirectory(.{
                    .source_dir = .{ .cwd_relative = scripts_source_dir },
                    .install_dir = .{ .custom = bundle_base ++ "/scripts/" ++ subdir },
                    .install_subdir = "",
                    .exclude_extensions = &.{".dSYM"},
                });
                gen_manifest.step.dependOn(&install_scripts.step);
            } else |_| {}
        }
    } else if (target.result.os.tag == .windows) {
        // Windows: flat directory layout
        //   package/GuavaGame/guava-player.exe
        //   package/GuavaGame/SDL3.dll
        //   package/GuavaGame/assets/...
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
    } else {
        // Linux: FHS-like layout
        //   package/guava-game/bin/guava-player
        //   package/guava-game/lib/libSDL3.so.0
        //   package/guava-game/share/assets/...
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

    // ---- Cook step: pre-cook all project assets via the engine validate pipeline ----
    const cook_step = b.step("cook", "Pre-cook all project assets (runs engine validate to refresh derived outputs)");
    const cook_cmd = b.addRunArtifact(exe);
    cook_cmd.step.dependOn(b.getInstallStep());
    cook_cmd.addArg("validate");
    cook_step.dependOn(&cook_cmd.step);

    // ---- Scripts step: compile project scripts into distributable artifacts ----
    const scripts_step = b.step("scripts", "Compile project scripts (C# NativeAOT)");
    {
        // Discover and compile C# NativeAOT projects from examples/csharp/
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
        if (rid) |runtime_id| {
            const csharp_output_dir = b.getInstallPath(.{ .custom = "scripts/csharp" }, "");
            if (std.fs.cwd().openDir("examples/csharp", .{ .iterate = true })) |dir| {
                var iter = dir.iterate();
                while (iter.next() catch null) |entry| {
                    if (entry.kind != .directory) continue;
                    const csproj_glob = b.pathJoin(&.{ "examples/csharp", entry.name });
                    // Look for .csproj files in the subdirectory
                    if (std.fs.cwd().openDir(csproj_glob, .{ .iterate = true })) |subdir| {
                        var sub_iter = subdir.iterate();
                        while (sub_iter.next() catch null) |sub_entry| {
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
                                break; // one csproj per directory
                            }
                        }
                    } else |_| {}
                }
            } else |_| {}
        }
    }

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

    // Add SoLoud audio engine sources
    module.addCSourceFiles(.{
        .files = &soloud_core_cpp_sources,
        .flags = &soloud_cpp_flags,
    });
    module.addCSourceFiles(.{
        .files = &soloud_wav_cpp_sources,
        .flags = &soloud_cpp_flags,
    });
    module.addCSourceFiles(.{
        .files = &soloud_extra_audiosource_cpp_sources,
        .flags = &soloud_cpp_flags,
    });
    module.addCSourceFiles(.{
        .files = &soloud_filter_cpp_sources,
        .flags = &soloud_cpp_flags,
    });
    module.addCSourceFiles(.{
        .files = &soloud_backend_cpp_sources,
        .flags = &soloud_cpp_flags,
    });
    module.addCSourceFiles(.{
        .files = &soloud_c_api_cpp_sources,
        .flags = &soloud_cpp_flags,
    });
    module.addCSourceFiles(.{
        .files = &soloud_support_c_sources,
        .flags = &soloud_c_flags,
    });

    const jolt_cpp_sources = collectSourceFiles(b, "third_party/jolt/Jolt", ".cpp");
    module.addCSourceFiles(.{
        .files = jolt_cpp_sources,
        .flags = &engine_cpp_flags,
    });

    const recast_cpp_sources = collectSourceFiles(b, "third_party/recast/Recast/Source", ".cpp");
    module.addCSourceFiles(.{
        .files = recast_cpp_sources,
        .flags = &engine_cpp_flags,
    });
    const detour_cpp_sources = collectSourceFiles(b, "third_party/recast/Detour/Source", ".cpp");
    module.addCSourceFiles(.{
        .files = detour_cpp_sources,
        .flags = &engine_cpp_flags,
    });
    const detour_crowd_cpp_sources = collectSourceFiles(b, "third_party/recast/DetourCrowd/Source", ".cpp");
    module.addCSourceFiles(.{
        .files = detour_crowd_cpp_sources,
        .flags = &engine_cpp_flags,
    });
    if (os_tag == .macos) {
        module.addCSourceFiles(.{
            .files = &macos_objcpp_sources,
            .flags = &macos_objcpp_flags,
        });
        module.linkFramework("AppKit", .{});
        module.linkFramework("Metal", .{});
        module.linkFramework("MetalPerformanceShaders", .{});
        module.linkFramework("QuartzCore", .{});
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
    // Vulkan C bridge + ImGui Vulkan backend — all platforms (macOS uses MoltenVK)
    module.addCSourceFiles(.{
        .files = &vulkan_c_sources,
        .flags = &vulkan_c_flags,
    });
    module.addCSourceFiles(.{
        .files = &vulkan_cpp_sources,
        .flags = &engine_cpp_flags,
    });
    module.linkSystemLibrary("vulkan", .{});

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
        &.{},
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
        &.{},
    );
    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        cpp_compiler,
        &soloud_cpp_flags,
        &soloud_core_cpp_sources,
        &.{},
    );
    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        cpp_compiler,
        &soloud_cpp_flags,
        &soloud_wav_cpp_sources,
        &.{},
    );
    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        cpp_compiler,
        &soloud_cpp_flags,
        &soloud_extra_audiosource_cpp_sources,
        &.{},
    );
    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        cpp_compiler,
        &soloud_cpp_flags,
        &soloud_filter_cpp_sources,
        &.{},
    );
    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        cpp_compiler,
        &soloud_cpp_flags,
        &soloud_backend_cpp_sources,
        &.{},
    );
    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        cpp_compiler,
        &soloud_cpp_flags,
        &soloud_c_api_cpp_sources,
        &.{},
    );
    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        c_compiler,
        &soloud_c_flags,
        &soloud_support_c_sources,
        &.{},
    );
    const jolt_cpp_sources = collectSourceFiles(b, "third_party/jolt/Jolt", ".cpp");
    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        cpp_compiler,
        &engine_cpp_flags,
        jolt_cpp_sources,
        &.{},
    );
    const recast_cpp_sources = collectSourceFiles(b, "third_party/recast/Recast/Source", ".cpp");
    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        cpp_compiler,
        &engine_cpp_flags,
        recast_cpp_sources,
        &.{},
    );
    const detour_cpp_sources = collectSourceFiles(b, "third_party/recast/Detour/Source", ".cpp");
    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        cpp_compiler,
        &engine_cpp_flags,
        detour_cpp_sources,
        &.{},
    );
    const detour_crowd_cpp_sources = collectSourceFiles(b, "third_party/recast/DetourCrowd/Source", ".cpp");
    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        cpp_compiler,
        &engine_cpp_flags,
        detour_crowd_cpp_sources,
        &.{},
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
            &.{},
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
            &.{},
        );
    }

    // ── Electron native addon (N-API) ──────────────────────────────
    // Detect node-addon-api and Node.js header include paths for clangd.
    const napi_include = captureCommandOutput(b, &.{
        "node",                                                                                "-e",
        "console.log(require('path').resolve('../editor/node_modules/node-addon-api'))",
    });
    const node_include = captureCommandOutput(b, &.{
        "node",                                                                              "-e",
        "console.log(require('path').resolve(process.execPath,'..','..','include','node'))",
    });
    if (napi_include != null or node_include != null) {
        var napi_extra_includes: std.ArrayList([]const u8) = .empty;
        defer napi_extra_includes.deinit(b.allocator);
        if (napi_include) |p| napi_extra_includes.append(b.allocator, p) catch @panic("OOM");
        if (node_include) |p| napi_extra_includes.append(b.allocator, p) catch @panic("OOM");
        const napi_includes = napi_extra_includes.toOwnedSlice(b.allocator) catch @panic("OOM");

        // Include both macOS and Linux addon sources for clangd completeness.
        if (os_tag == .macos) {
            appendCompileCommands(
                b,
                &entries,
                root_dir,
                sdl_include_path,
                sysroot,
                objcpp_compiler,
                &macos_objcpp_flags,
                &.{"../editor/native/src/iosurface_view.mm"},
                napi_includes,
            );
        }
        appendCompileCommands(
            b,
            &entries,
            root_dir,
            sdl_include_path,
            sysroot,
            cpp_compiler,
            &engine_cpp_flags,
            &.{"../editor/native/src/shm_view.cpp"},
            napi_includes,
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
        for (engine_include_paths) |include_path| {
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

fn collectSourceFiles(b: *std.Build, root: []const u8, extension: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(b.allocator);

    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch |err| {
        std.debug.panic("failed to open source root {s}: {s}", .{ root, @errorName(err) });
    };
    defer dir.close();

    var walker = dir.walk(b.allocator) catch |err| {
        std.debug.panic("failed to walk source root {s}: {s}", .{ root, @errorName(err) });
    };
    defer walker.deinit();

    while (walker.next() catch |err| {
        std.debug.panic("failed to iterate source root {s}: {s}", .{ root, @errorName(err) });
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, extension)) {
            continue;
        }
        list.append(b.allocator, b.pathJoin(&.{ root, entry.path })) catch @panic("OOM");
    }

    std.mem.sort([]const u8, list.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
}
