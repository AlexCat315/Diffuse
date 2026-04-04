const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const state_mod = @import("../../../core/state.zig");
const EditorState = state_mod.EditorState;
const history = @import("../../../actions/history.zig");
const content_browser = @import("../../../assets/browser.zig");
const camera = @import("../../../interaction/camera.zig");
const layout = @import("../../layout.zig");
const playback_session = @import("../../../core/playback_session.zig");

pub fn drawRenderSettingsWindow(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    state.ensureRenderOutputDefaults();

    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .render_settings, "render_settings_popup");
    var open = state.render_settings_open;
    _ = gui.beginWindowFlagsOpen(title, &open, gui.WindowFlags.no_docking);
    state.render_settings_open = open;
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("render_settings_popup");
    layout.beginSectionBody();
    defer layout.endSectionBody();

    gui.text(state.text(.camera));
    switch (drawButtonRow2(state.text(.editor_camera_mode), state.text(.scene_camera_mode), 112.0)) {
        .first => if (!state.editor_camera_active) {
            camera.toggleCameraMode(state, layer_context);
        },
        .second => if (state.editor_camera_active) {
            camera.toggleCameraMode(state, layer_context);
        },
        .third => {},
        .fourth => {},
        .none => {},
    }

    gui.separator();
    gui.text(state.text(.perspective_view));
    switch (drawButtonRow3(state.text(.perspective_view), state.text(.top_view), state.text(.side_view), 92.0)) {
        .first => camera.setViewPreset(state, layer_context, .perspective),
        .second => camera.setViewPreset(state, layer_context, .top),
        .third => camera.setViewPreset(state, layer_context, .side),
        .fourth => {},
        .none => {},
    }

    gui.separator();
    gui.text(state.text(.render_modes));
    switch (drawButtonRow4(
        state.text(.solid_view),
        state.text(.material_view),
        state.text(.rendered_view),
        state.text(.wireframe),
        72.0,
    )) {
        .first => applyViewportShadingMode(state, layer_context, .solid),
        .second => applyViewportShadingMode(state, layer_context, .material),
        .third => applyViewportShadingMode(state, layer_context, .rendered),
        .fourth => applyViewportShadingMode(state, layer_context, .wireframe),
        .none => {},
    }

    gui.separator();
    try drawEnvironmentSection(state, layer_context);

    gui.separator();
    gui.text("Path Tracer");

    // Quality preset combo
    drawPtQualityPresetCombo(state);

    var pt_samples: i32 = @intCast(state.viewport_path_trace_samples);
    if (gui.dragInt("##pt_samples", &pt_samples, 1.0, 1, 2048)) {
        state.viewport_path_trace_samples = @intCast(std.math.clamp(pt_samples, 1, 2048));
    }
    var pt_samples_buf: [32]u8 = undefined;
    const pt_samples_text = try std.fmt.bufPrint(&pt_samples_buf, "{d}", .{state.viewport_path_trace_samples});
    gui.labelText("Samples", pt_samples_text);

    var pt_bounces: i32 = @intCast(state.viewport_path_trace_bounces);
    if (gui.dragInt("##pt_bounces", &pt_bounces, 1.0, 1, 12)) {
        state.viewport_path_trace_bounces = @intCast(std.math.clamp(pt_bounces, 1, 12));
    }
    var pt_bounces_buf: [32]u8 = undefined;
    const pt_bounces_text = try std.fmt.bufPrint(&pt_bounces_buf, "{d}", .{state.viewport_path_trace_bounces});
    gui.labelText("Bounces", pt_bounces_text);

    var pt_scale = state.viewport_path_trace_resolution_scale;
    if (gui.dragFloat("##pt_resolution_scale", &pt_scale, 0.01, 0.25, 1.0)) {
        state.viewport_path_trace_resolution_scale = std.math.clamp(pt_scale, 0.25, 1.0);
    }
    var pt_scale_buf: [32]u8 = undefined;
    const pt_scale_text = try std.fmt.bufPrint(&pt_scale_buf, "{d:.2}x", .{state.viewport_path_trace_resolution_scale});
    gui.labelText("Resolution", pt_scale_text);

    gui.separator();
    try drawRenderOutputSection(state, layer_context);

    gui.separator();
    _ = gui.checkbox(state.text(.show_grid), &state.viewport_show_grid);
    _ = gui.checkbox(state.text(.show_bones), &state.viewport_show_bones);
    _ = gui.checkbox(state.text(.show_collision), &state.viewport_show_collision);

    gui.separator();
    gui.text(state.text(.coordinate_space));
    switch (drawButtonRow2(state.text(.local_space), state.text(.world_space), 112.0)) {
        .first => state.transform_space = .local,
        .second => state.transform_space = .world,
        .third => {},
        .fourth => {},
        .none => {},
    }

    gui.separator();
    const viewport_size = layer_context.renderer.sceneViewportSize();
    var viewport_buffer: [64]u8 = undefined;
    const viewport_text = try std.fmt.bufPrint(&viewport_buffer, "{d} x {d}", .{ viewport_size[0], viewport_size[1] });
    gui.labelText(state.text(.viewport_size), viewport_text);
}

fn drawEnvironmentSection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    gui.text("Environment");

    const current_environment = layer_context.world.resources.sceneEnvironmentAssetId();
    const preview_label = sceneEnvironmentPreviewLabel(&layer_context.world.resources);
    if (gui.beginCombo("HDR Sky##scene_environment", preview_label)) {
        defer gui.endCombo();

        if (gui.selectable("None", current_environment == null, false, 0.0, 0.0)) {
            try applySceneEnvironmentSelection(state, layer_context, null);
        }

        for (layer_context.world.resources.asset_registry.records.items) |record| {
            if (!isHdrTextureRecord(record)) continue;
            std.fs.cwd().access(record.source_path, .{}) catch continue;

            const selected = current_environment != null and std.mem.eql(u8, current_environment.?, record.id);
            if (gui.selectable(sceneEnvironmentRecordLabel(record), selected, false, 0.0, 0.0)) {
                try applySceneEnvironmentSelection(state, layer_context, record.id);
            }
        }
    }

    const selected_asset = content_browser.selectedAsset(state);
    const can_use_selected = if (selected_asset) |entry| isHdrTextureEntry(entry) else false;
    if (gui.buttonEx("Use Selected HDR", 0.0, 0.0) and can_use_selected) {
        try applySceneEnvironmentSelection(state, layer_context, selected_asset.?.id);
    }
    gui.sameLine();
    if (gui.buttonEx("Clear HDR", 0.0, 0.0) and current_environment != null) {
        try applySceneEnvironmentSelection(state, layer_context, null);
    }

    if (selected_asset) |entry| {
        gui.labelText("Browser Selection", if (isHdrTextureEntry(entry)) entry.name else "Select an .hdr asset in the browser");
    } else {
        gui.labelText("Browser Selection", "None");
    }
}

fn applySceneEnvironmentSelection(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    asset_id: ?[]const u8,
) !void {
    if (asset_id) |resolved_asset_id| {
        if (state.asset_registry) |*registry| {
            if (registry.recordById(resolved_asset_id) != null) {
                _ = try engine.assets.loadTextureAsset(
                    state.allocator orelse layer_context.world.allocator,
                    layer_context.world.assets(),
                    registry,
                    resolved_asset_id,
                );
            }
        }
    }

    const changed = try layer_context.world.resources.setSceneEnvironmentAssetId(asset_id);
    if (!changed) {
        return;
    }

    layer_context.renderer.invalidateEnvironmentState();
    try history.captureSnapshot(state, layer_context);
}

fn sceneEnvironmentPreviewLabel(resources: *const engine.assets.ResourceLibrary) []const u8 {
    const environment_asset_id = resources.sceneEnvironmentAssetId() orelse return "None";
    const record = resources.asset_registry.recordById(environment_asset_id) orelse return "Missing";
    return sceneEnvironmentRecordLabel(record);
}

fn sceneEnvironmentRecordLabel(record: anytype) []const u8 {
    if (record.metadata.display_name.len != 0) {
        return record.metadata.display_name;
    }
    return std.fs.path.basename(record.source_path);
}

fn isHdrTextureEntry(entry: *const state_mod.AssetEntry) bool {
    return entry.kind == .texture and std.mem.endsWith(u8, entry.path, ".hdr");
}

fn isHdrTextureRecord(record: anytype) bool {
    return record.type == .texture and std.mem.endsWith(u8, record.source_path, ".hdr");
}

pub fn resolveRenderOutputDimensions(
    state: *const EditorState,
    layer_context: *const engine.core.LayerContext,
) [2]u32 {
    return switch (state.render_output_resolution_preset) {
        .viewport => blk: {
            const renderer_size = layer_context.renderer.sceneViewportSize();
            if (renderer_size[0] > 0 and renderer_size[1] > 0) {
                break :blk renderer_size;
            }
            break :blk .{ 0, 0 };
        },
        .hd_1080 => .{ 1920, 1080 },
        .dci_2k => .{ 2048, 1080 },
        .uhd_4k => .{ 3840, 2160 },
        .custom => .{
            @max(state.render_output_width, 64),
            @max(state.render_output_height, 64),
        },
    };
}

pub fn queueRenderOutput(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    if (state.render_output_job_stage != .idle) {
        return;
    }

    state.ensureRenderOutputDefaults();

    const dims = resolveRenderOutputDimensions(state, layer_context);
    if (dims[0] == 0 or dims[1] == 0) {
        setRenderOutputStatusLiteral(state, .failure, "Viewport size is not ready yet.");
        return;
    }

    if (state.renderOutputPath().len == 0) {
        setRenderOutputStatusLiteral(state, .failure, "Output path is required.");
        return;
    }

    const total_frames: u32 = if (state.render_output_sequence_enabled)
        @max(state.render_output_sequence_frame_count, 1)
    else
        1;
    if (state.render_output_sequence_enabled and layer_context.playback_controller.state != .stopped) {
        setRenderOutputStatusLiteral(state, .failure, "Sequence export requires playback to be stopped.");
        return;
    }
    if (state.render_output_sequence_enabled and state.render_output_sequence_fps == 0) {
        setRenderOutputStatusLiteral(state, .failure, "Sequence FPS must be at least 1.");
        return;
    }

    state.render_output_restore_samples = state.viewport_path_trace_samples;
    state.render_output_restore_bounces = state.viewport_path_trace_bounces;
    state.render_output_restore_resolution_scale = state.viewport_path_trace_resolution_scale;
    state.render_output_job_is_sequence = state.render_output_sequence_enabled;
    state.render_output_job_total_frames = total_frames;
    state.render_output_job_frame_index = 0;
    state.render_output_job_started_playback = false;

    if (state.viewport_pipeline_mode == .path_trace) {
        state.viewport_path_trace_samples = std.math.clamp(state.render_output_samples, 1, 4096);
        state.viewport_path_trace_bounces = std.math.clamp(state.render_output_bounces, 1, 12);
        state.viewport_path_trace_resolution_scale = 1.0;
        layer_context.renderer.resetPathTraceState();
    }

    if (state.render_output_job_is_sequence and total_frames > 1) {
        try playback_session.play(state, layer_context);
        layer_context.playback_controller.setFixedDelta(1.0 / @as(f32, @floatFromInt(state.render_output_sequence_fps)));
        state.render_output_job_started_playback = true;
    }

    state.render_output_job_stage = .resize_and_render;
    if (state.render_output_job_is_sequence) {
        const frame_number = state.renderOutputFrameNumber(0);
        const out_path = try state.renderOutputResolvedPathAlloc(state.allocator orelse layer_context.world.allocator, frame_number);
        defer (state.allocator orelse layer_context.world.allocator).free(out_path);
        setRenderOutputStatusFmt(state, .queued, "Queued frame 1/{d} -> {s}", .{ total_frames, out_path });
    } else {
        const out_path = try state.renderOutputResolvedPathAlloc(state.allocator orelse layer_context.world.allocator, null);
        defer (state.allocator orelse layer_context.world.allocator).free(out_path);
        setRenderOutputStatusFmt(state, .queued, "{d} x {d} -> {s}", .{ dims[0], dims[1], out_path });
    }
}

fn drawRenderOutputSection(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    gui.text("Render Output");
    drawRenderOutputPresetCombo(state);

    if (state.render_output_resolution_preset == .custom) {
        var output_width: i32 = @intCast(state.render_output_width);
        if (gui.dragInt("##render_output_width", &output_width, 1.0, 64, 8192)) {
            state.render_output_width = @intCast(std.math.clamp(output_width, 64, 8192));
        }
        var output_width_buf: [32]u8 = undefined;
        const output_width_text = try std.fmt.bufPrint(&output_width_buf, "{d}", .{state.render_output_width});
        gui.labelText("Width", output_width_text);

        var output_height: i32 = @intCast(state.render_output_height);
        if (gui.dragInt("##render_output_height", &output_height, 1.0, 64, 8192)) {
            state.render_output_height = @intCast(std.math.clamp(output_height, 64, 8192));
        }
        var output_height_buf: [32]u8 = undefined;
        const output_height_text = try std.fmt.bufPrint(&output_height_buf, "{d}", .{state.render_output_height});
        gui.labelText("Height", output_height_text);
    }

    const dims = resolveRenderOutputDimensions(state, layer_context);
    var output_size_buf: [64]u8 = undefined;
    const output_size_text = try std.fmt.bufPrint(&output_size_buf, "{d} x {d}", .{ dims[0], dims[1] });
    gui.labelText("Output Size", output_size_text);
    drawRenderOutputFormatCombo(state);

    gui.text("Output Path");
    _ = gui.inputTextWithHint("##render_output_path", "renders_test_out/frame.png", state.render_output_path_buffer[0..]);

    gui.textWrapped(renderOutputPipelineNote(state));

    _ = gui.checkbox("Image Sequence", &state.render_output_sequence_enabled);
    if (state.render_output_sequence_enabled) {
        var start_frame: i32 = @intCast(state.render_output_sequence_start_frame);
        if (gui.dragInt("##render_output_sequence_start", &start_frame, 1.0, 0, 100000)) {
            state.render_output_sequence_start_frame = @intCast(std.math.clamp(start_frame, 0, 100000));
        }
        var start_frame_buf: [32]u8 = undefined;
        const start_frame_text = try std.fmt.bufPrint(&start_frame_buf, "{d}", .{state.render_output_sequence_start_frame});
        gui.labelText("Start Frame", start_frame_text);

        var frame_count: i32 = @intCast(state.render_output_sequence_frame_count);
        if (gui.dragInt("##render_output_sequence_count", &frame_count, 1.0, 1, 4096)) {
            state.render_output_sequence_frame_count = @intCast(std.math.clamp(frame_count, 1, 4096));
        }
        var frame_count_buf: [32]u8 = undefined;
        const frame_count_text = try std.fmt.bufPrint(&frame_count_buf, "{d}", .{state.render_output_sequence_frame_count});
        gui.labelText("Frame Count", frame_count_text);

        var fps: i32 = @intCast(state.render_output_sequence_fps);
        if (gui.dragInt("##render_output_sequence_fps", &fps, 1.0, 1, 240)) {
            state.render_output_sequence_fps = @intCast(std.math.clamp(fps, 1, 240));
        }
        var fps_buf: [32]u8 = undefined;
        const fps_text = try std.fmt.bufPrint(&fps_buf, "{d}", .{state.render_output_sequence_fps});
        gui.labelText("FPS", fps_text);
    }

    if (state.viewport_pipeline_mode == .path_trace) {
        var export_samples: i32 = @intCast(state.render_output_samples);
        if (gui.dragInt("##render_output_samples", &export_samples, 1.0, 1, 4096)) {
            state.render_output_samples = @intCast(std.math.clamp(export_samples, 1, 4096));
        }
        var export_samples_buf: [32]u8 = undefined;
        const export_samples_text = try std.fmt.bufPrint(&export_samples_buf, "{d}", .{state.render_output_samples});
        gui.labelText("Export Samples", export_samples_text);

        var export_bounces: i32 = @intCast(state.render_output_bounces);
        if (gui.dragInt("##render_output_bounces", &export_bounces, 1.0, 1, 12)) {
            state.render_output_bounces = @intCast(std.math.clamp(export_bounces, 1, 12));
        }
        var export_bounces_buf: [32]u8 = undefined;
        const export_bounces_text = try std.fmt.bufPrint(&export_bounces_buf, "{d}", .{state.render_output_bounces});
        gui.labelText("Export Bounces", export_bounces_text);

        if (state.render_output_format == .png) {
            _ = gui.checkbox("Denoise PathTrace Export", &state.render_output_path_trace_denoise);
            _ = gui.checkbox("Write Albedo/Normal AOV", &state.render_output_path_trace_write_aovs);
        } else {
            gui.textWrapped("OpenEXR exports write linear beauty only. Denoise and albedo/normal AOV sidecars remain PNG-only.");
        }
    } else {
        gui.textWrapped("Current pipeline is Raster, so export samples/bounces are ignored.");
    }

    gui.labelText("Status", renderOutputStatusLabel(state.render_output_status));
    const status_detail = state.renderOutputStatusText();
    if (status_detail.len > 0) {
        const detail_color = switch (state.render_output_status) {
            .failure => [4]f32{ 1.0, 0.42, 0.42, 1.0 },
            .success => [4]f32{ 0.50, 0.86, 0.58, 1.0 },
            else => [4]f32{ 0.73, 0.76, 0.82, 1.0 },
        };
        gui.textColored(detail_color, status_detail);
    }

    if (state.render_output_job_stage == .idle) {
        const button_label = if (state.render_output_sequence_enabled) "Render Sequence" else "Render Image";
        if (gui.buttonEx(button_label, 140.0, 0.0)) {
            try queueRenderOutput(state, layer_context);
        }
    } else {
        gui.textWrapped("Render output job is in progress. Settings are locked until the current export finishes.");
    }
}

const ButtonRowResult = enum {
    none,
    first,
    second,
    third,
    fourth,
};

fn drawButtonRow2(first: []const u8, second: []const u8, min_button_width: f32) ButtonRowResult {
    const columns = layout.responsiveButtonColumns(2, min_button_width);
    const width = layout.responsiveButtonWidth(columns);
    if (gui.buttonEx(first, width, 0.0)) {
        return .first;
    }
    layout.advanceResponsiveRow(1, columns);
    if (gui.buttonEx(second, width, 0.0)) {
        return .second;
    }
    return .none;
}

fn drawButtonRow3(first: []const u8, second: []const u8, third: []const u8, min_button_width: f32) ButtonRowResult {
    const columns = layout.responsiveButtonColumns(3, min_button_width);
    const width = layout.responsiveButtonWidth(columns);
    if (gui.buttonEx(first, width, 0.0)) {
        return .first;
    }
    layout.advanceResponsiveRow(1, columns);
    if (gui.buttonEx(second, width, 0.0)) {
        return .second;
    }
    layout.advanceResponsiveRow(2, columns);
    if (gui.buttonEx(third, width, 0.0)) {
        return .third;
    }
    return .none;
}

fn drawButtonRow4(first: []const u8, second: []const u8, third: []const u8, fourth: []const u8, min_button_width: f32) ButtonRowResult {
    const columns = layout.responsiveButtonColumns(4, min_button_width);
    const width = layout.responsiveButtonWidth(columns);
    if (gui.buttonEx(first, width, 0.0)) {
        return .first;
    }
    layout.advanceResponsiveRow(1, columns);
    if (gui.buttonEx(second, width, 0.0)) {
        return .second;
    }
    layout.advanceResponsiveRow(2, columns);
    if (gui.buttonEx(third, width, 0.0)) {
        return .third;
    }
    layout.advanceResponsiveRow(3, columns);
    if (gui.buttonEx(fourth, width, 0.0)) {
        return .fourth;
    }
    return .none;
}

fn applyViewportShadingMode(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    shading_mode: state_mod.ViewportShadingMode,
) void {
    if (state_mod.setViewportShadingMode(state, shading_mode)) {
        layer_context.renderer.resetPathTraceState();
    }
}

const PtQualityPreset = enum {
    preview,
    low,
    medium,
    high,
    ultra,
};

fn ptQualityPresetLabel(preset: PtQualityPreset) []const u8 {
    return switch (preset) {
        .preview => "Preview",
        .low => "Low",
        .medium => "Medium",
        .high => "High",
        .ultra => "Ultra",
    };
}

fn detectCurrentPtPreset(state: *const EditorState) ?PtQualityPreset {
    const s = state.viewport_path_trace_samples;
    const b = state.viewport_path_trace_bounces;
    const r = state.viewport_path_trace_resolution_scale;
    if (s == 1 and b == 1 and r == 0.5) return .preview;
    if (s == 4 and b == 2 and r == 0.75) return .low;
    if (s == 12 and b == 4 and r == 1.0) return .medium;
    if (s == 48 and b == 6 and r == 1.0) return .high;
    if (s == 256 and b == 10 and r == 1.0) return .ultra;
    return null;
}

fn applyPtPreset(state: *EditorState, preset: PtQualityPreset) void {
    switch (preset) {
        .preview => {
            state.viewport_path_trace_samples = 1;
            state.viewport_path_trace_bounces = 1;
            state.viewport_path_trace_resolution_scale = 0.5;
        },
        .low => {
            state.viewport_path_trace_samples = 4;
            state.viewport_path_trace_bounces = 2;
            state.viewport_path_trace_resolution_scale = 0.75;
        },
        .medium => {
            state.viewport_path_trace_samples = 12;
            state.viewport_path_trace_bounces = 4;
            state.viewport_path_trace_resolution_scale = 1.0;
        },
        .high => {
            state.viewport_path_trace_samples = 48;
            state.viewport_path_trace_bounces = 6;
            state.viewport_path_trace_resolution_scale = 1.0;
        },
        .ultra => {
            state.viewport_path_trace_samples = 256;
            state.viewport_path_trace_bounces = 10;
            state.viewport_path_trace_resolution_scale = 1.0;
        },
    }
}

fn drawPtQualityPresetCombo(state: *EditorState) void {
    const current = detectCurrentPtPreset(state);
    const preview_label = if (current) |p| ptQualityPresetLabel(p) else "Custom";
    if (!gui.beginCombo("Quality##pt_quality", preview_label)) {
        return;
    }
    defer gui.endCombo();

    const presets = [_]PtQualityPreset{ .preview, .low, .medium, .high, .ultra };
    for (presets) |preset| {
        const selected = if (current) |c| c == preset else false;
        if (gui.selectable(ptQualityPresetLabel(preset), selected, false, 0.0, 0.0)) {
            applyPtPreset(state, preset);
        }
    }
}

fn drawRenderOutputPresetCombo(state: *EditorState) void {
    const preview_label = renderOutputPresetLabel(state.render_output_resolution_preset);
    if (!gui.beginCombo("Resolution Preset##render_output_preset", preview_label)) {
        return;
    }
    defer gui.endCombo();

    const presets = [_]state_mod.RenderOutputResolutionPreset{ .viewport, .hd_1080, .dci_2k, .uhd_4k, .custom };
    for (presets) |preset| {
        const selected = state.render_output_resolution_preset == preset;
        if (gui.selectable(renderOutputPresetLabel(preset), selected, false, 0.0, 0.0)) {
            state.render_output_resolution_preset = preset;
            applyRenderOutputPreset(state, preset);
        }
    }
}

fn drawRenderOutputFormatCombo(state: *EditorState) void {
    const preview_label = renderOutputFormatLabel(state.render_output_format);
    if (!gui.beginCombo("Format##render_output_format", preview_label)) {
        return;
    }
    defer gui.endCombo();

    const formats = [_]state_mod.RenderOutputFormat{ .png, .exr };
    for (formats) |format| {
        const selected = state.render_output_format == format;
        if (gui.selectable(renderOutputFormatLabel(format), selected, false, 0.0, 0.0)) {
            state.render_output_format = format;
        }
    }
}

fn renderOutputPresetLabel(preset: state_mod.RenderOutputResolutionPreset) []const u8 {
    return switch (preset) {
        .viewport => "Viewport",
        .hd_1080 => "1080p",
        .dci_2k => "2K DCI",
        .uhd_4k => "4K UHD",
        .custom => "Custom",
    };
}

fn applyRenderOutputPreset(state: *EditorState, preset: state_mod.RenderOutputResolutionPreset) void {
    switch (preset) {
        .viewport => {},
        .hd_1080 => {
            state.render_output_width = 1920;
            state.render_output_height = 1080;
        },
        .dci_2k => {
            state.render_output_width = 2048;
            state.render_output_height = 1080;
        },
        .uhd_4k => {
            state.render_output_width = 3840;
            state.render_output_height = 2160;
        },
        .custom => {},
    }
}

fn renderOutputFormatLabel(format: state_mod.RenderOutputFormat) []const u8 {
    return switch (format) {
        .png => "PNG",
        .exr => "OpenEXR",
    };
}

fn renderOutputPipelineNote(state: *const EditorState) []const u8 {
    if (state.render_output_sequence_enabled) {
        return switch (state.viewport_pipeline_mode) {
            .raster => "Sequence export drives playback with a fixed timestep so animation, scripts, physics, and VFX advance deterministically per frame before each raster write.",
            .path_trace => if (state.render_output_format == .png and
                (state.render_output_path_trace_denoise or state.render_output_path_trace_write_aovs))
                "Sequence export drives playback with a fixed timestep. Each frame switches PathTrace to the output samples/bounces, and PNG writes can emit albedo/normal AOV sidecars plus AOV-guided denoise."
            else if (state.render_output_format == .exr)
                "Sequence export drives playback with a fixed timestep. OpenEXR writes linear PathTrace beauty per frame."
            else
                "Sequence export drives playback with a fixed timestep. Each frame switches PathTrace to the output samples/bounces and full-resolution tracing before write.",
        };
    }
    return switch (state.viewport_pipeline_mode) {
        .raster => "Exports use the current Raster viewport result at the selected output resolution.",
        .path_trace => if (state.render_output_format == .png and
            (state.render_output_path_trace_denoise or state.render_output_path_trace_write_aovs))
            "Exports switch PathTrace to the output samples/bounces and full-resolution tracing, then can emit albedo/normal AOV sidecars and run AOV-guided denoise before PNG write."
        else if (state.render_output_format == .exr)
            "Exports switch PathTrace to the output samples/bounces and write linear beauty to OpenEXR."
        else
            "Exports temporarily switch PathTrace to the output samples/bounces and full-resolution tracing.",
    };
}

fn renderOutputStatusLabel(status: state_mod.RenderOutputStatus) []const u8 {
    return switch (status) {
        .idle => "Ready",
        .queued => "Queued",
        .rendering => "Rendering",
        .writing => "Writing",
        .success => "Done",
        .failure => "Failed",
    };
}

fn setRenderOutputStatusLiteral(state: *EditorState, status: state_mod.RenderOutputStatus, text: []const u8) void {
    state.render_output_status = status;
    @memset(state.render_output_status_buffer[0..], 0);
    const copy_len = @min(text.len, state.render_output_status_buffer.len - 1);
    @memcpy(state.render_output_status_buffer[0..copy_len], text[0..copy_len]);
}

fn setRenderOutputStatusFmt(
    state: *EditorState,
    status: state_mod.RenderOutputStatus,
    comptime fmt: []const u8,
    args: anytype,
) void {
    state.render_output_status = status;
    @memset(state.render_output_status_buffer[0..], 0);
    _ = std.fmt.bufPrint(&state.render_output_status_buffer, fmt, args) catch {};
}

test "render output preset dimensions" {
    var state = EditorState{};
    applyRenderOutputPreset(&state, .hd_1080);
    try std.testing.expectEqual(@as(u32, 1920), state.render_output_width);
    try std.testing.expectEqual(@as(u32, 1080), state.render_output_height);

    applyRenderOutputPreset(&state, .dci_2k);
    try std.testing.expectEqual(@as(u32, 2048), state.render_output_width);
    try std.testing.expectEqual(@as(u32, 1080), state.render_output_height);

    applyRenderOutputPreset(&state, .uhd_4k);
    try std.testing.expectEqual(@as(u32, 3840), state.render_output_width);
    try std.testing.expectEqual(@as(u32, 2160), state.render_output_height);
}
