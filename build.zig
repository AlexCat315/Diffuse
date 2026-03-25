const std = @import("std");

const engine_include_paths = [_][]const u8{
    "third_party/stb",
    "third_party/imgui",
    "third_party/jolt",
    "third_party/lunasvg/include",
    "third_party/lunasvg/source",
    "third_party/lunasvg/plutovg/include",
    "third_party/lunasvg/plutovg/source",
    "third_party/wamr/core",
    "third_party/wamr/core/iwasm/include",
    "third_party/wamr/core/iwasm/common",
    "third_party/wamr/core/iwasm/interpreter",
    "third_party/wamr/core/shared/mem-alloc",
    "third_party/wamr/core/shared/platform/include",
    "third_party/wamr/core/shared/platform/common/libc-util",
    "third_party/wamr/core/shared/utils",
    "third_party/soloud/include",
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
    "src/engine/assets/stb_image_impl.c",
    "src/engine/assets/stb_image_write_impl.c",
};

const wamr_mem_alloc_c_sources = [_][]const u8{
    "third_party/wamr/core/shared/mem-alloc/mem_alloc.c",
    "third_party/wamr/core/shared/mem-alloc/ems/ems_alloc.c",
    "third_party/wamr/core/shared/mem-alloc/ems/ems_gc.c",
    "third_party/wamr/core/shared/mem-alloc/ems/ems_hmu.c",
    "third_party/wamr/core/shared/mem-alloc/ems/ems_kfc.c",
};

const wamr_utils_c_sources = [_][]const u8{
    "third_party/wamr/core/shared/utils/bh_assert.c",
    "third_party/wamr/core/shared/utils/bh_bitmap.c",
    "third_party/wamr/core/shared/utils/bh_common.c",
    "third_party/wamr/core/shared/utils/bh_hashmap.c",
    "third_party/wamr/core/shared/utils/bh_leb128.c",
    "third_party/wamr/core/shared/utils/bh_list.c",
    "third_party/wamr/core/shared/utils/bh_log.c",
    "third_party/wamr/core/shared/utils/bh_queue.c",
    "third_party/wamr/core/shared/utils/bh_vector.c",
    "third_party/wamr/core/shared/utils/runtime_timer.c",
};

const wamr_common_c_sources = [_][]const u8{
    "third_party/wamr/core/iwasm/common/arch/invokeNative_general.c",
    "third_party/wamr/core/iwasm/common/wasm_blocking_op.c",
    "third_party/wamr/core/iwasm/common/wasm_c_api.c",
    "third_party/wamr/core/iwasm/common/wasm_exec_env.c",
    "third_party/wamr/core/iwasm/common/wasm_loader_common.c",
    "third_party/wamr/core/iwasm/common/wasm_memory.c",
    "third_party/wamr/core/iwasm/common/wasm_native.c",
    "third_party/wamr/core/iwasm/common/wasm_runtime_common.c",
    "third_party/wamr/core/iwasm/common/wasm_shared_memory.c",
};

const wamr_interpreter_c_sources = [_][]const u8{
    "third_party/wamr/core/iwasm/interpreter/wasm_interp_classic.c",
    "third_party/wamr/core/iwasm/interpreter/wasm_loader.c",
    "third_party/wamr/core/iwasm/interpreter/wasm_runtime.c",
};

const wamr_posix_platform_c_sources = [_][]const u8{
    "third_party/wamr/core/shared/platform/common/libc-util/libc_errno.c",
    "third_party/wamr/core/shared/platform/common/math/math.c",
    "third_party/wamr/core/shared/platform/common/memory/mremap.c",
    "third_party/wamr/core/shared/platform/common/posix/posix_blocking_op.c",
    "third_party/wamr/core/shared/platform/common/posix/posix_clock.c",
    "third_party/wamr/core/shared/platform/common/posix/posix_file.c",
    "third_party/wamr/core/shared/platform/common/posix/posix_malloc.c",
    "third_party/wamr/core/shared/platform/common/posix/posix_memmap.c",
    "third_party/wamr/core/shared/platform/common/posix/posix_sleep.c",
    "third_party/wamr/core/shared/platform/common/posix/posix_socket.c",
    "third_party/wamr/core/shared/platform/common/posix/posix_thread.c",
    "third_party/wamr/core/shared/platform/common/posix/posix_time.c",
};

const wamr_linux_platform_c_sources = [_][]const u8{
    "third_party/wamr/core/shared/platform/linux/platform_init.c",
};

const wamr_darwin_platform_c_sources = [_][]const u8{
    "third_party/wamr/core/shared/platform/darwin/platform_init.c",
};

const wamr_windows_platform_c_sources = [_][]const u8{
    "third_party/wamr/core/shared/platform/windows/platform_init.c",
    "third_party/wamr/core/shared/platform/windows/win_clock.c",
    "third_party/wamr/core/shared/platform/windows/win_file.c",
    "third_party/wamr/core/shared/platform/windows/win_malloc.c",
    "third_party/wamr/core/shared/platform/windows/win_memmap.c",
    "third_party/wamr/core/shared/platform/windows/win_socket.c",
    "third_party/wamr/core/shared/platform/windows/win_thread.c",
    "third_party/wamr/core/shared/platform/windows/win_time.c",
    "third_party/wamr/core/shared/platform/windows/win_util.c",
};

const wamr_bridge_c_sources = [_][]const u8{
    "src/engine/script/wasm_vm_bridge.c",
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

/// SoLoud C language API wrapper (for potential WASM/scripting integration)
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
    "src/engine/physics/jolt_bridge.cpp",
};

const macos_objcpp_sources = [_][]const u8{
    "src/engine/platform/window_native_macos.mm",
    "src/engine/rt/metal_rt_bridge.mm",
    "src/engine/rhi/metal/metal_rhi_bridge.mm",
    "third_party/imgui/backends/imgui_impl_metal.mm",
    "src/engine/ui/imgui_metal_backend.mm",
};

const windows_cpp_sources = [_][]const u8{
    "third_party/wamr/core/shared/platform/windows/win_atomic.cpp",
    "src/engine/platform/window_native_windows.cpp",
};

const vulkan_c_sources = [_][]const u8{
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

const wamr_base_c_flags = [_][]const u8{
    "-std=c11",
    "-DBH_MALLOC=wasm_runtime_malloc",
    "-DBH_FREE=wasm_runtime_free",
    "-DWAMR_BUILD_INVOKE_NATIVE_GENERAL=1",
    "-DWAMR_DISABLE_APP_ENTRY=1",
    "-DWASM_ENABLE_INTERP=1",
    "-DWASM_ENABLE_FAST_INTERP=0",
    "-DWASM_ENABLE_AOT=0",
    "-DWASM_ENABLE_JIT=0",
    "-DWASM_ENABLE_FAST_JIT=0",
    "-DWASM_ENABLE_LIBC_BUILTIN=0",
    "-DWASM_ENABLE_LIBC_WASI=0",
    "-DWASM_ENABLE_MULTI_MODULE=0",
    "-DWASM_ENABLE_SHARED_MEMORY=0",
    "-DWASM_ENABLE_BULK_MEMORY=1",
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
    const wamr_c_sources = wamrCSources(b, os_tag);
    const wamr_c_flags = wamrCFlags(b, os_tag);

    module.addIncludePath(.{ .cwd_relative = sdl_include_path });
    for (engine_include_paths) |include_path| {
        module.addIncludePath(.{ .cwd_relative = include_path });
    }
    module.addIncludePath(.{ .cwd_relative = wamrPlatformIncludePath(os_tag) });

    module.addLibraryPath(.{ .cwd_relative = sdl_library_path });
    if (os_tag != .windows) {
        module.addRPath(.{ .cwd_relative = sdl_library_path });
    }

    module.addCSourceFiles(.{
        .files = &plutovg_c_sources,
        .flags = &plutovg_c_flags,
    });
    module.addCSourceFiles(.{
        .files = wamr_c_sources,
        .flags = wamr_c_flags,
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
    if (os_tag == .macos) {
        module.addCSourceFiles(.{
            .files = &macos_objcpp_sources,
            .flags = &macos_objcpp_flags,
        });
        module.linkFramework("AppKit", .{});
        module.linkFramework("Metal", .{});
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
    const wamr_c_sources = wamrCSources(b, os_tag);
    const wamr_c_flags = wamrCFlags(b, os_tag);
    const wamr_platform_include_path = b.pathFromRoot(wamrPlatformIncludePath(os_tag));

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
        &.{wamr_platform_include_path},
    );
    appendCompileCommands(
        b,
        &entries,
        root_dir,
        sdl_include_path,
        sysroot,
        c_compiler,
        wamr_c_flags,
        wamr_c_sources,
        &.{wamr_platform_include_path},
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
        &.{wamr_platform_include_path},
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
        &.{wamr_platform_include_path},
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
        &.{wamr_platform_include_path},
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
        &.{wamr_platform_include_path},
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
        &.{wamr_platform_include_path},
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
        &.{wamr_platform_include_path},
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
        &.{wamr_platform_include_path},
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
        &.{wamr_platform_include_path},
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
        &.{wamr_platform_include_path},
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
            &.{wamr_platform_include_path},
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
            &.{wamr_platform_include_path},
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

fn wamrPlatformIncludePath(os_tag: std.Target.Os.Tag) []const u8 {
    return switch (os_tag) {
        .macos => "third_party/wamr/core/shared/platform/darwin",
        .linux => "third_party/wamr/core/shared/platform/linux",
        .windows => "third_party/wamr/core/shared/platform/windows",
        else => @panic("unsupported WAMR host platform"),
    };
}

fn wamrCFlags(b: *std.Build, os_tag: std.Target.Os.Tag) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(b.allocator);

    list.appendSlice(b.allocator, &wamr_base_c_flags) catch @panic("OOM");
    list.append(b.allocator, switch (os_tag) {
        .macos => "-DBH_PLATFORM_DARWIN",
        .linux => "-DBH_PLATFORM_LINUX",
        .windows => "-DBH_PLATFORM_WINDOWS",
        else => @panic("unsupported WAMR host platform"),
    }) catch @panic("OOM");

    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn wamrCSources(b: *std.Build, os_tag: std.Target.Os.Tag) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(b.allocator);

    list.appendSlice(b.allocator, &wamr_mem_alloc_c_sources) catch @panic("OOM");
    list.appendSlice(b.allocator, &wamr_utils_c_sources) catch @panic("OOM");
    list.appendSlice(b.allocator, &wamr_common_c_sources) catch @panic("OOM");
    list.appendSlice(b.allocator, &wamr_interpreter_c_sources) catch @panic("OOM");
    list.appendSlice(b.allocator, &wamr_bridge_c_sources) catch @panic("OOM");

    switch (os_tag) {
        .macos => {
            list.appendSlice(b.allocator, &wamr_posix_platform_c_sources) catch @panic("OOM");
            list.appendSlice(b.allocator, &wamr_darwin_platform_c_sources) catch @panic("OOM");
        },
        .linux => {
            list.appendSlice(b.allocator, &wamr_posix_platform_c_sources) catch @panic("OOM");
            list.appendSlice(b.allocator, &wamr_linux_platform_c_sources) catch @panic("OOM");
        },
        .windows => {
            list.appendSlice(b.allocator, &wamr_windows_platform_c_sources) catch @panic("OOM");
        },
        else => @panic("unsupported WAMR host platform"),
    }

    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
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
