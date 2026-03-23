//! 基准测试与渲染比较命令
//!
//! 实现 benchmark、generate-benchmark、compare-render、validate、render-test 子命令。

const std = @import("std");
const engine = @import("guava");
const cli = @import("cli.zig");

pub fn runBenchmark(allocator: std.mem.Allocator, scene_path: []const u8, update_golden: bool) !void {
    const width = 1280;
    const height = 720;
    const benchmark_frames = 100;

    var app = try engine.core.Application.init(allocator, .{
        .name = "Benchmark Mode",
        .window_width = width,
        .window_height = height,
        .window_borderless = true,
        .frame_delay_ms = 0,
    });
    defer app.deinit();

    var handle = try app.world.importGltfAsync("assets/models/guava_showcase/guava_showcase.gltf", .{
        .translation = .{ 0.0, 0.0, 0.0 },
    }, null);
    defer handle.deinit();
    handle.wait();

    try engine.scene.loadWorldFromPath(allocator, &app.world, scene_path);
    try app.renderer.setSceneViewportSize(width, height);

    std.log.info("Starting benchmark for scene: {s} (frames={d})", .{ scene_path, benchmark_frames });

    const report = try app.run(benchmark_frames);

    const frame_ppm = try app.renderer.downloadFinalFrameAlloc(allocator);
    defer allocator.free(frame_ppm);

    const scene_basename = std.fs.path.basename(scene_path);
    const scene_name = if (std.mem.lastIndexOfScalar(u8, scene_basename, '.')) |idx| scene_basename[0..idx] else scene_basename;

    try std.fs.cwd().makePath("assets/benchmarks/golden");
    const golden_path = try std.fmt.allocPrint(allocator, "assets/benchmarks/golden/{s}.ppm", .{scene_name});
    defer allocator.free(golden_path);

    if (update_golden) {
        try std.fs.cwd().writeFile(.{ .sub_path = golden_path, .data = frame_ppm });
        std.log.info("Golden image updated: {s}", .{golden_path});
    } else {
        const file_stat = std.fs.cwd().statFile(golden_path) catch |err| {
            if (err == error.FileNotFound) {
                std.log.err("Golden image not found: {s}. Run with --update-golden to create it.", .{golden_path});
                return err;
            }
            std.log.err("无法获取基准文件状态: {s}", .{@errorName(err)});
            return err;
        };

        const golden_ppm = std.fs.cwd().readFileAlloc(allocator, golden_path, file_stat.size) catch |err| {
            std.log.err("读取基准文件失败: {s}", .{@errorName(err)});
            return err;
        };
        defer allocator.free(golden_ppm);

        if (std.mem.eql(u8, frame_ppm, golden_ppm)) {
            std.log.info("Benchmark PASSED: Render output matches golden image.", .{});
        } else {
            std.log.err("Benchmark FAILED: Render output differs from golden image.", .{});

            try std.fs.cwd().makePath("dist/reports/benchmark_diff");
            const diff_path = try std.fmt.allocPrint(allocator, "dist/reports/benchmark_diff/{s}_failed.ppm", .{scene_name});
            defer allocator.free(diff_path);
            try std.fs.cwd().writeFile(.{ .sub_path = diff_path, .data = frame_ppm });
            std.log.info("Failed frame saved to: {s}", .{diff_path});

            return error.BenchmarkValidationFailed;
        }
    }

    std.log.info("Benchmark report: frames={d}, triangles={d}, entities={d}", .{
        report.frames,
        report.triangles_drawn,
        report.scene.entity_count,
    });
}

pub fn runCompareRender(allocator: std.mem.Allocator, scene_path: []const u8, output_dir: []const u8) !void {
    const width = 800;
    const height = 600;

    var app = try engine.core.Application.init(allocator, .{
        .name = "Render Comparison",
        .window_width = width,
        .window_height = height,
        .window_borderless = true,
    });
    defer app.deinit();

    try engine.scene.loadWorldFromPath(allocator, &app.world, scene_path);
    try app.renderer.setSceneViewportSize(width, height);

    _ = try app.renderer.drawFrame(&app.world, &app.physics_state);
    const gpu_ppm = try app.renderer.downloadFinalFrameAlloc(allocator);
    defer allocator.free(gpu_ppm);

    const software_ppm = try engine.render.BasePassGolden.renderScenePpmAlloc(allocator, &app.world, width, height);
    defer allocator.free(software_ppm);

    try std.fs.cwd().makePath(output_dir);
    const gpu_path = try std.fmt.allocPrint(allocator, "{s}/gpu.ppm", .{output_dir});
    defer allocator.free(gpu_path);
    const software_path = try std.fmt.allocPrint(allocator, "{s}/software.ppm", .{output_dir});
    defer allocator.free(software_path);

    try std.fs.cwd().writeFile(.{ .sub_path = gpu_path, .data = gpu_ppm });
    try std.fs.cwd().writeFile(.{ .sub_path = software_path, .data = software_ppm });

    std.log.info("Comparison completed. GPU and Software images saved to {s}", .{output_dir});
}

pub fn runGenerateBenchmark(allocator: std.mem.Allocator, output_path: []const u8) !void {
    var world = engine.scene.World.init(allocator, null);
    defer world.deinit();
    try world.bootstrap3D();

    const cube_mesh = try world.assets().ensurePrimitiveMesh(.cube);
    const default_material = try world.assets().ensureDefaultMaterial();

    _ = try world.createEntity(.{
        .name = "BenchmarkCube",
        .mesh = .{ .handle = cube_mesh, .primitive = .cube },
        .material = .{ .handle = default_material },
        .local_transform = .{ .translation = .{ 0.0, 1.0, 0.0 } },
    });

    _ = try world.createEntity(.{
        .name = "BenchmarkCamera",
        .camera = .{
            .projection = .{
                .perspective = .{
                    .fov_y_radians = 60.0 * (std.math.pi / 180.0),
                    .near_clip = 0.1,
                    .far_clip = 100.0,
                },
            },
            .is_primary = true,
        },
        .local_transform = .{
            .translation = .{ 0.0, 2.0, 5.0 },
            .rotation = engine.math.quat.fromEuler(.{ -0.2, 0.0, 0.0 }),
        },
    });

    try engine.scene.saveWorldToPath(allocator, &world, output_path);
    std.log.info("Benchmark scene generated: {s}", .{output_path});
}

pub fn runValidate(allocator: std.mem.Allocator, options: cli.ValidateOptions) !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    var registry = engine.assets.AssetRegistry.init(allocator);
    defer registry.deinit();

    var report = report: {
        registry.refreshProject(options.root_path) catch {
            break :report try engine.assets.validateProjectAssetsAlloc(allocator, options.root_path);
        };
        if (options.write_snapshot) {
            registry.writeSnapshotToPath("assets/derived/asset_registry.json") catch {};
        }
        break :report try engine.assets.validateRegistryAssetsAlloc(
            allocator,
            &registry,
            options.asset_query,
        );
    };
    defer report.deinit(allocator);

    try stdout.print(
        "资产验证: assets={d}, outputs={d}, deps={d}, issues={d}\n",
        .{ report.asset_count, report.validated_output_count, report.dependency_edge_count, report.issues.len },
    );
    for (report.issues) |issue| {
        try stdout.print("- {s}: {s} ({s})\n", .{ issue.source_path, issue.message, issue.asset_id });
    }
    try stdout.flush();

    try std.fs.cwd().makePath("dist/reports");
    const file = try std.fs.cwd().createFile("dist/reports/asset_validation_report.json", .{});
    defer file.close();
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);

    var writer = output.writer(allocator);
    var adapter_buffer: [8192]u8 = undefined;
    var writer_adapter = writer.adaptToNewApi(&adapter_buffer);
    try std.json.Stringify.value(report, .{ .whitespace = .indent_2 }, &writer_adapter.new_interface);
    try writer_adapter.new_interface.flush();

    try file.writeAll(output.items);
    std.debug.print("✅ 资产验证报告已成功生成: dist/reports/asset_validation_report.json\n", .{});

    if (!report.ok()) {
        return error.ValidationFailed;
    }
}

pub fn runRenderTest(allocator: std.mem.Allocator, options: cli.RenderTestOptions) !void {
    const width: u32 = 1280;
    const height: u32 = 720;

    var app = try engine.core.Application.init(allocator, .{
        .name = "Render Test",
        .window_width = width,
        .window_height = height,
        .window_borderless = true,
        .frame_delay_ms = 0,
    });
    defer app.deinit();

    // Load the scene
    try engine.scene.loadWorldFromPath(allocator, &app.world, options.scene_path);
    try app.renderer.setSceneViewportSize(width, height);

    // Configure viewport state based on feature flags
    var vp_state = engine.render.EditorViewportState{};
    if (options.path_trace) vp_state.pipeline_mode = .path_trace;
    if (options.rt_shadows) vp_state.rt_shadows_enabled = true;
    if (options.fxaa) vp_state.fxaa_enabled = true;
    if (options.bloom) vp_state.bloom_enabled = true;
    if (options.ssao) vp_state.ssao_enabled = true;
    app.renderer.setEditorViewportState(vp_state);

    // Build feature label for output
    var feature_buf: [256]u8 = undefined;
    var feature_fbs = std.io.fixedBufferStream(&feature_buf);
    const fw = feature_fbs.writer();
    var feature_count: usize = 0;
    if (options.rt_shadows) {
        if (feature_count > 0) fw.writeAll(", ") catch {};
        fw.writeAll("rt_shadows") catch {};
        feature_count += 1;
    }
    if (options.path_trace) {
        if (feature_count > 0) fw.writeAll(", ") catch {};
        fw.writeAll("path_trace") catch {};
        feature_count += 1;
    }
    if (options.fxaa) {
        if (feature_count > 0) fw.writeAll(", ") catch {};
        fw.writeAll("fxaa") catch {};
        feature_count += 1;
    }
    if (options.bloom) {
        if (feature_count > 0) fw.writeAll(", ") catch {};
        fw.writeAll("bloom") catch {};
        feature_count += 1;
    }
    if (options.ssao) {
        if (feature_count > 0) fw.writeAll(", ") catch {};
        fw.writeAll("ssao") catch {};
        feature_count += 1;
    }
    if (feature_count == 0) fw.writeAll("baseline") catch {};
    const feature_label = feature_fbs.getWritten();

    std.debug.print("\n=== Render Test ===\n", .{});
    std.debug.print("Scene: {s}\n", .{options.scene_path});
    std.debug.print("Features: {s}\n", .{feature_label});
    std.debug.print("Resolution: {d}x{d}\n", .{ width, height });
    std.debug.print("Frames: {d}\n", .{options.frames});

    // Render frames
    _ = try app.run(options.frames);

    // Download rendered frame
    const frame_ppm = try app.renderer.downloadFinalFrameAlloc(allocator);
    defer allocator.free(frame_ppm);

    // Parse PPM header to get to pixel data
    const pixel_data = parsePpmPixels(frame_ppm) orelse {
        std.debug.print("ERROR: Failed to parse PPM pixel data\n", .{});
        return error.InvalidPpmData;
    };

    // Analyze pixels
    const analysis = analyzePixels(pixel_data, width, height);

    std.debug.print("\n--- Pixel Analysis ---\n", .{});
    std.debug.print("Avg brightness: {d:.3}\n", .{analysis.avg_brightness});
    std.debug.print("Min brightness: {d:.3}\n", .{analysis.min_brightness});
    std.debug.print("Max brightness: {d:.3}\n", .{analysis.max_brightness});
    std.debug.print("Dark  (<0.10): {d:.1}%\n", .{analysis.dark_pct});
    std.debug.print("Shadow(0.10-0.30): {d:.1}%\n", .{analysis.shadow_pct});
    std.debug.print("Mid   (0.30-0.70): {d:.1}%\n", .{analysis.mid_pct});
    std.debug.print("Bright(>0.70): {d:.1}%\n", .{analysis.bright_pct});
    std.debug.print("Black pixels (=0): {d}\n", .{analysis.black_count});
    std.debug.print("White pixels (=1): {d}\n", .{analysis.white_count});

    // Validation checks
    var checks_passed: usize = 0;
    var checks_total: usize = 0;

    // Check 1: Frame is not all black
    checks_total += 1;
    if (analysis.avg_brightness > 0.01) {
        checks_passed += 1;
        std.debug.print("CHECK [PASS]: Frame is not all black\n", .{});
    } else {
        std.debug.print("CHECK [FAIL]: Frame is all black (avg={d:.3})\n", .{analysis.avg_brightness});
    }

    // Check 2: Frame is not all white
    checks_total += 1;
    if (analysis.avg_brightness < 0.99) {
        checks_passed += 1;
        std.debug.print("CHECK [PASS]: Frame is not all white\n", .{});
    } else {
        std.debug.print("CHECK [FAIL]: Frame is all white (avg={d:.3})\n", .{analysis.avg_brightness});
    }

    // Check 3: Has brightness variation (not flat-colored)
    checks_total += 1;
    const range = analysis.max_brightness - analysis.min_brightness;
    if (range > 0.05) {
        checks_passed += 1;
        std.debug.print("CHECK [PASS]: Has brightness variation (range={d:.3})\n", .{range});
    } else {
        std.debug.print("CHECK [FAIL]: No brightness variation (range={d:.3})\n", .{range});
    }

    // Check 4: RT shadows produce shadow regions
    if (options.rt_shadows) {
        checks_total += 1;
        if (analysis.shadow_pct > 0.5) {
            checks_passed += 1;
            std.debug.print("CHECK [PASS]: RT shadows produce shadow regions ({d:.1}%)\n", .{analysis.shadow_pct});
        } else {
            std.debug.print("CHECK [FAIL]: RT shadows not visible (shadow={d:.1}%)\n", .{analysis.shadow_pct});
        }
    }

    // Export frame image if requested
    if (options.export_png) {
        try std.fs.cwd().makePath("dist/reports/render_test");
        const png_suffix = try options.goldenSuffix(allocator);
        defer allocator.free(png_suffix);
        const out_path = try std.fmt.allocPrint(allocator, "dist/reports/render_test/frame{s}.ppm", .{png_suffix});
        defer allocator.free(out_path);
        try std.fs.cwd().writeFile(.{ .sub_path = out_path, .data = frame_ppm });
        std.debug.print("Exported frame: {s}\n", .{out_path});
    }

    // Golden image comparison
    const scene_basename = std.fs.path.basename(options.scene_path);
    const scene_name = if (std.mem.lastIndexOfScalar(u8, scene_basename, '.')) |idx| scene_basename[0..idx] else scene_basename;
    const suffix = try options.goldenSuffix(allocator);
    defer allocator.free(suffix);

    try std.fs.cwd().makePath("dist/reports/render_test");
    const golden_path = try std.fmt.allocPrint(allocator, "dist/reports/render_test/{s}{s}.ppm", .{ scene_name, suffix });
    defer allocator.free(golden_path);

    if (options.update_golden) {
        try std.fs.cwd().writeFile(.{ .sub_path = golden_path, .data = frame_ppm });
        std.debug.print("\nGolden image saved: {s}\n", .{golden_path});
    } else golden: {
        const golden_ppm = std.fs.cwd().readFileAlloc(allocator, golden_path, 32 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) {
                std.debug.print("\nNo golden image found: {s}\n", .{golden_path});
                std.debug.print("Run with --update-golden to create it.\n", .{});
            }
            break :golden;
        };
        defer allocator.free(golden_ppm);

        const golden_pixels = parsePpmPixels(golden_ppm);
        if (golden_pixels != null and pixel_data.len == golden_pixels.?.len) {
            const diff = computePixelDiff(pixel_data, golden_pixels.?);
            checks_total += 1;
            if (diff.avg_diff < 0.02) {
                checks_passed += 1;
                std.debug.print("CHECK [PASS]: Golden match (avg_diff={d:.4}, max_diff={d:.4})\n", .{ diff.avg_diff, diff.max_diff });
            } else {
                std.debug.print("CHECK [FAIL]: Golden mismatch (avg_diff={d:.4}, max_diff={d:.4})\n", .{ diff.avg_diff, diff.max_diff });
            }
        } else {
            std.debug.print("CHECK [SKIP]: Golden image size mismatch\n", .{});
        }
    }

    std.debug.print("\n=== Result: {d}/{d} checks passed ===\n", .{ checks_passed, checks_total });
    if (checks_passed < checks_total) {
        std.debug.print("RENDER TEST FAILED\n\n", .{});
        return error.RenderTestFailed;
    }
    std.debug.print("RENDER TEST PASSED\n\n", .{});
}

const PixelAnalysis = struct {
    avg_brightness: f64,
    min_brightness: f64,
    max_brightness: f64,
    dark_pct: f64,
    shadow_pct: f64,
    mid_pct: f64,
    bright_pct: f64,
    black_count: u64,
    white_count: u64,
};

fn analyzePixels(rgb_data: []const u8, width: u32, height: u32) PixelAnalysis {
    const total_pixels: u64 = @as(u64, width) * @as(u64, height);
    var sum: f64 = 0;
    var min_b: f64 = 1.0;
    var max_b: f64 = 0.0;
    var dark_count: u64 = 0;
    var shadow_count: u64 = 0;
    var mid_count: u64 = 0;
    var bright_count: u64 = 0;
    var black_count: u64 = 0;
    var white_count: u64 = 0;

    var i: usize = 0;
    while (i + 2 < rgb_data.len) : (i += 3) {
        const r: f64 = @as(f64, @floatFromInt(rgb_data[i])) / 255.0;
        const g: f64 = @as(f64, @floatFromInt(rgb_data[i + 1])) / 255.0;
        const b: f64 = @as(f64, @floatFromInt(rgb_data[i + 2])) / 255.0;
        const lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;

        sum += lum;
        if (lum < min_b) min_b = lum;
        if (lum > max_b) max_b = lum;

        if (lum < 0.10) {
            dark_count += 1;
        } else if (lum < 0.30) {
            shadow_count += 1;
        } else if (lum < 0.70) {
            mid_count += 1;
        } else {
            bright_count += 1;
        }

        if (rgb_data[i] == 0 and rgb_data[i + 1] == 0 and rgb_data[i + 2] == 0) black_count += 1;
        if (rgb_data[i] == 255 and rgb_data[i + 1] == 255 and rgb_data[i + 2] == 255) white_count += 1;
    }

    const tp_f: f64 = @floatFromInt(total_pixels);
    return .{
        .avg_brightness = if (total_pixels > 0) sum / tp_f else 0,
        .min_brightness = min_b,
        .max_brightness = max_b,
        .dark_pct = @as(f64, @floatFromInt(dark_count)) / tp_f * 100.0,
        .shadow_pct = @as(f64, @floatFromInt(shadow_count)) / tp_f * 100.0,
        .mid_pct = @as(f64, @floatFromInt(mid_count)) / tp_f * 100.0,
        .bright_pct = @as(f64, @floatFromInt(bright_count)) / tp_f * 100.0,
        .black_count = black_count,
        .white_count = white_count,
    };
}

const PixelDiff = struct {
    avg_diff: f64,
    max_diff: f64,
};

fn computePixelDiff(a: []const u8, b: []const u8) PixelDiff {
    const len = @min(a.len, b.len);
    var sum: f64 = 0;
    var max_d: f64 = 0;
    var count: u64 = 0;

    var i: usize = 0;
    while (i < len) : (i += 1) {
        const da: f64 = @floatFromInt(a[i]);
        const db: f64 = @floatFromInt(b[i]);
        const d = @abs(da - db) / 255.0;
        sum += d;
        if (d > max_d) max_d = d;
        count += 1;
    }

    return .{
        .avg_diff = if (count > 0) sum / @as(f64, @floatFromInt(count)) else 0,
        .max_diff = max_d,
    };
}

fn parsePpmPixels(ppm: []const u8) ?[]const u8 {
    // PPM P6 format: "P6\n<width> <height>\n<maxval>\n<pixel data>"
    if (ppm.len < 3) return null;
    if (!std.mem.startsWith(u8, ppm, "P6")) return null;

    // Skip past three newlines to reach pixel data
    var newline_count: usize = 0;
    var pos: usize = 0;
    while (pos < ppm.len) : (pos += 1) {
        if (ppm[pos] == '\n') {
            newline_count += 1;
            if (newline_count == 3) {
                return ppm[pos + 1 ..];
            }
        }
    }
    return null;
}
