const std = @import("std");
const utils = @import("utils.zig");

// ─── Include paths ──────────────────────────────────────────────────────────

pub const engine_include_paths = [_][]const u8{
    "third_party/stb",
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
};

// ─── PlutoVG / stb sources ─────────────────────────────────────────────────

pub const plutovg_c_sources = [_][]const u8{
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
    "src/engine/assets/stb_truetype_impl.c",
};

// ─── SoLoud audio engine ────────────────────────────────────────────────────

pub const soloud_core_cpp_sources = [_][]const u8{
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

pub const soloud_wav_cpp_sources = [_][]const u8{
    "third_party/soloud/src/audiosource/wav/soloud_wav.cpp",
    "third_party/soloud/src/audiosource/wav/soloud_wavstream.cpp",
    "third_party/soloud/src/audiosource/wav/dr_impl.cpp",
};

pub const soloud_extra_audiosource_cpp_sources = [_][]const u8{
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

pub const soloud_filter_cpp_sources = [_][]const u8{
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

pub const soloud_support_c_sources = [_][]const u8{
    "third_party/soloud/src/audiosource/wav/stb_vorbis.c",
    "src/engine/audio/openmpt_stub.c",
};

pub const soloud_backend_cpp_sources = [_][]const u8{
    "third_party/soloud/src/backend/miniaudio/soloud_miniaudio.cpp",
};

pub const soloud_coreaudio_cpp_sources = [_][]const u8{
    "third_party/soloud/src/backend/coreaudio/soloud_coreaudio.cpp",
};

pub const soloud_c_api_cpp_sources = [_][]const u8{
    "third_party/soloud/src/c_api/soloud_c.cpp",
};

// ─── Engine C++ sources (LunaSVG, Jolt bridge, Recast bridge) ──────────────

pub const engine_cpp_sources = [_][]const u8{
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
    "src/engine/physics/jolt_bridge.cpp",
    "src/engine/navigation/recast_bridge.cpp",
};

// ─── Platform-specific sources ─────────────────────────────────────────────

pub const macos_objcpp_sources = [_][]const u8{
    "src/engine/render/path_trace/path_trace_denoise_bridge.mm",
    "src/engine/rt/metal_rt_bridge.mm",
};

pub const windows_cpp_sources = [_][]const u8{};

pub const vulkan_c_sources = [_][]const u8{};

pub const vulkan_cpp_sources = [_][]const u8{};

// ─── Compilation flags ─────────────────────────────────────────────────────

pub const plutovg_c_flags = [_][]const u8{
    "-std=c11",
    "-DPLUTOVG_BUILD=1",
    "-DPLUTOVG_BUILD_STATIC=1",
};

pub const engine_cpp_flags = [_][]const u8{
    "-std=c++17",
    "-DLUNASVG_BUILD=1",
    "-DLUNASVG_BUILD_STATIC=1",
    "-DPLUTOVG_BUILD=1",
    "-DPLUTOVG_BUILD_STATIC=1",
};

pub const soloud_cpp_flags = [_][]const u8{
    "-std=c++17",
    "-DWITH_MINIAUDIO=1",
    "-DWITH_COREAUDIO=1",
};

pub const soloud_coreaudio_cpp_flags = [_][]const u8{
    "-std=c++17",
    "-DWITH_COREAUDIO=1",
};

pub const soloud_c_flags = [_][]const u8{
    "-std=c11",
};

pub const vulkan_c_flags = [_][]const u8{
    "-std=c11",
};

pub const macos_objcpp_flags = [_][]const u8{
    "-std=c++17",
    "-fobjc-arc",
};

pub const windows_platform_cpp_flags = [_][]const u8{
    "-std=c++17",
};

// ─── Module configuration ──────────────────────────────────────────────────

/// Add all C/C++/ObjC++ source files and link system libraries to a Zig module.
pub fn configureEngineModule(
    b: *std.Build,
    module: *std.Build.Module,
    os_tag: std.Target.Os.Tag,
    sdl_prefix: []const u8,
    c_translations: CTranslations,
) void {
    const sdl_include_path = b.pathJoin(&.{ sdl_prefix, "include" });
    const sdl_library_path = b.pathJoin(&.{ sdl_prefix, "lib" });

    module.addIncludePath(.{ .cwd_relative = sdl_include_path });
    for (engine_include_paths) |include_path| {
        module.addIncludePath(b.path(include_path));
    }

    module.addLibraryPath(.{ .cwd_relative = sdl_library_path });
    if (os_tag != .windows) {
        module.addRPath(.{ .cwd_relative = sdl_library_path });
    }

    module.addCSourceFiles(.{ .files = &plutovg_c_sources, .flags = &plutovg_c_flags });
    module.addCSourceFiles(.{ .files = &engine_cpp_sources, .flags = &engine_cpp_flags });

    // SoLoud audio engine
    module.addCSourceFiles(.{ .files = &soloud_core_cpp_sources, .flags = &soloud_cpp_flags });
    module.addCSourceFiles(.{ .files = &soloud_wav_cpp_sources, .flags = &soloud_cpp_flags });
    module.addCSourceFiles(.{ .files = &soloud_extra_audiosource_cpp_sources, .flags = &soloud_cpp_flags });
    module.addCSourceFiles(.{ .files = &soloud_filter_cpp_sources, .flags = &soloud_cpp_flags });
    module.addCSourceFiles(.{ .files = &soloud_backend_cpp_sources, .flags = &soloud_cpp_flags });
    module.addCSourceFiles(.{ .files = &soloud_c_api_cpp_sources, .flags = &soloud_cpp_flags });
    module.addCSourceFiles(.{ .files = &soloud_support_c_sources, .flags = &soloud_c_flags });

    // Jolt Physics (auto-collected)
    const jolt_cpp_sources = utils.collectSourceFiles(b, "third_party/jolt/Jolt", ".cpp");
    module.addCSourceFiles(.{ .files = jolt_cpp_sources, .flags = &engine_cpp_flags });

    // Recast/Detour navigation (auto-collected)
    const recast_cpp_sources = utils.collectSourceFiles(b, "third_party/recast/Recast/Source", ".cpp");
    module.addCSourceFiles(.{ .files = recast_cpp_sources, .flags = &engine_cpp_flags });
    const detour_cpp_sources = utils.collectSourceFiles(b, "third_party/recast/Detour/Source", ".cpp");
    module.addCSourceFiles(.{ .files = detour_cpp_sources, .flags = &engine_cpp_flags });
    const detour_crowd_cpp_sources = utils.collectSourceFiles(b, "third_party/recast/DetourCrowd/Source", ".cpp");
    module.addCSourceFiles(.{ .files = detour_crowd_cpp_sources, .flags = &engine_cpp_flags });

    if (os_tag == .macos) {
        module.addCSourceFiles(.{ .files = &macos_objcpp_sources, .flags = &macos_objcpp_flags });
        module.addCSourceFiles(.{ .files = &soloud_coreaudio_cpp_sources, .flags = &soloud_coreaudio_cpp_flags });
        module.linkFramework("AppKit", .{});
        module.linkFramework("Metal", .{});
        module.linkFramework("MetalPerformanceShaders", .{});
        module.linkFramework("QuartzCore", .{});
        module.linkFramework("CoreFoundation", .{});
        module.linkFramework("IOSurface", .{});
        module.linkFramework("CoreVideo", .{});
        module.linkFramework("CoreAudio", .{});
        module.linkFramework("AudioUnit", .{});
        module.linkFramework("AudioToolbox", .{});
    }
    if (os_tag == .windows) {
        module.addCSourceFiles(.{ .files = &windows_cpp_sources, .flags = &windows_platform_cpp_flags });
        module.linkSystemLibrary("comctl32", .{});
        module.linkSystemLibrary("dwmapi", .{});
        module.linkSystemLibrary("uxtheme", .{});
    }

    // Vulkan C bridge — all platforms (macOS uses MoltenVK)
    module.addCSourceFiles(.{ .files = &vulkan_c_sources, .flags = &vulkan_c_flags });
    module.addCSourceFiles(.{ .files = &vulkan_cpp_sources, .flags = &engine_cpp_flags });
    module.linkSystemLibrary("vulkan", .{});

    module.linkSystemLibrary("SDL3", .{});

    // C Translation modules (replacing @cImport)
    module.addImport("c_stb_image", c_translations.stb_image);
    module.addImport("c_stb_image_write", c_translations.stb_image_write);
    module.addImport("c_stb_truetype", c_translations.stb_truetype);
    module.addImport("c_svg_bridge", c_translations.svg_bridge);
    module.addImport("c_soloud", c_translations.soloud);
    module.addImport("c_recast", c_translations.recast);
    module.addImport("c_sdl3", c_translations.sdl3);
}

// ─── C Translation modules (replacing @cImport) ───────────────────────────

pub const CTranslations = struct {
    stb_image: *std.Build.Module,
    stb_image_write: *std.Build.Module,
    stb_truetype: *std.Build.Module,
    svg_bridge: *std.Build.Module,
    soloud: *std.Build.Module,
    recast: *std.Build.Module,
    sdl3: *std.Build.Module,
};

pub fn createCTranslations(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    sdl_prefix: []const u8,
) CTranslations {
    const sdl_include_path = b.pathJoin(&.{ sdl_prefix, "include" });

    // stb_image
    const tc_stb_image = b.addTranslateC(.{
        .root_source_file = b.path("src/c_headers/stb_image.h"),
        .target = target,
        .optimize = optimize,
    });
    tc_stb_image.addIncludePath(b.path("third_party/stb"));

    // stb_image_write
    const tc_stb_image_write = b.addTranslateC(.{
        .root_source_file = b.path("src/c_headers/stb_image_write.h"),
        .target = target,
        .optimize = optimize,
    });
    tc_stb_image_write.addIncludePath(b.path("third_party/stb"));

    // stb_truetype
    const tc_stb_truetype = b.addTranslateC(.{
        .root_source_file = b.path("src/c_headers/stb_truetype.h"),
        .target = target,
        .optimize = optimize,
    });
    tc_stb_truetype.addIncludePath(b.path("third_party/stb"));

    // svg_bridge
    const tc_svg_bridge = b.addTranslateC(.{
        .root_source_file = b.path("src/c_headers/svg_bridge.h"),
        .target = target,
        .optimize = optimize,
    });
    tc_svg_bridge.addIncludePath(b.path("src/engine/assets"));

    // soloud
    const tc_soloud = b.addTranslateC(.{
        .root_source_file = b.path("src/c_headers/soloud.h"),
        .target = target,
        .optimize = optimize,
    });
    tc_soloud.addIncludePath(b.path("third_party/soloud/include"));

    // recast
    const tc_recast = b.addTranslateC(.{
        .root_source_file = b.path("src/c_headers/recast.h"),
        .target = target,
        .optimize = optimize,
    });
    tc_recast.addIncludePath(b.path("src/engine/navigation"));
    tc_recast.addIncludePath(b.path("third_party/recast/Recast/Include"));
    tc_recast.addIncludePath(b.path("third_party/recast/Detour/Include"));
    tc_recast.addIncludePath(b.path("third_party/recast/DetourCrowd/Include"));

    // sdl3
    const tc_sdl3 = b.addTranslateC(.{
        .root_source_file = b.path("src/c_headers/sdl3.h"),
        .target = target,
        .optimize = optimize,
    });
    tc_sdl3.addIncludePath(.{ .cwd_relative = sdl_include_path });

    return .{
        .stb_image = tc_stb_image.createModule(),
        .stb_image_write = tc_stb_image_write.createModule(),
        .stb_truetype = tc_stb_truetype.createModule(),
        .svg_bridge = tc_svg_bridge.createModule(),
        .soloud = tc_soloud.createModule(),
        .recast = tc_recast.createModule(),
        .sdl3 = tc_sdl3.createModule(),
    };
}
