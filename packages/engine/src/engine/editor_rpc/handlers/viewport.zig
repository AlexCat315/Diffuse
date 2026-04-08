///! handlers/viewport.zig — viewport & gizmo control + native window embedding.
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const sdl = @import("../../platform/sdl.zig").c;

pub fn setGizmoMode(ctx: *Ctx) !void {
    const mode_str = try ctx.param([]const u8, "mode");
    const gizmo_pass = @import("../../render/passes/gizmo_pass.zig");
    const mode: gizmo_pass.EditorGizmoMode = if (std.mem.eql(u8, mode_str, "translate"))
        .translate
    else if (std.mem.eql(u8, mode_str, "rotate"))
        .rotate
    else if (std.mem.eql(u8, mode_str, "scale"))
        .scale
    else
        .idle;
    ctx.layer.renderer.pending_gizmo_mode = mode;
    // Also update space if provided
    if (try ctx.paramOpt([]const u8, "space")) |space_str| {
        ctx.layer.renderer.pending_gizmo_space = if (std.mem.eql(u8, space_str, "world"))
            .world
        else
            .local;
    }
    try ctx.reply(.{});
}

/// Reposition and resize the engine's SDL window to the given screen rect.
/// Called by Electron when the viewport area changes position or size.
pub fn setRect(ctx: *Ctx) !void {
    const x = try ctx.param(i64, "x");
    const y = try ctx.param(i64, "y");
    const width = try ctx.param(i64, "width");
    const height = try ctx.param(i64, "height");

    std.log.info("viewport.setRect: x={d} y={d} w={d} h={d}", .{ x, y, width, height });

    const win = ctx.layer.window;

    if (win.handle) |h| {
        // Make window borderless for clean embedding (idempotent)
        _ = sdl.SDL_SetWindowBordered(h, false);

        // Reposition
        try win.setPosition(@intCast(x), @intCast(y));

        // Resize
        if (!sdl.SDL_SetWindowSize(h, @intCast(width), @intCast(height))) {
            std.log.err("viewport.setRect: SDL_SetWindowSize failed", .{});
            return error.SdlWindowOperationFailed;
        }
        try win.refreshSizes();
    } else {
        // Headless: no SDL window, update dimensions directly from RPC params
        win.logical_width = @intCast(width);
        win.logical_height = @intCast(height);
        win.drawable_width = @intCast(width);
        win.drawable_height = @intCast(height);
    }

    // Use the physical (drawable) pixel size for the render target, not the
    // logical (CSS) size, so Retina/HiDPI displays get full-resolution
    // rendering.
    const w: u32 = if (win.drawable_width > 0) win.drawable_width else @intCast(width);
    const h: u32 = if (win.drawable_height > 0) win.drawable_height else @intCast(height);
    try ctx.layer.renderer.setSceneViewportSize(w, h);

    try ctx.reply(.{});
}

/// Return information about the engine's native window for embedding.
pub fn getWindowInfo(ctx: *Ctx) !void {
    const win = ctx.layer.window;
    const pos = try win.position();

    // Get platform-specific native window handle
    const native_handle: u64 = blk: {
        if (win.nativeCocoaWindow()) |ptr| break :blk @intFromPtr(ptr);
        if (win.nativeWin32Hwnd()) |ptr| break :blk @intFromPtr(ptr);
        break :blk 0;
    };

    const platform: []const u8 = blk: {
        if (win.nativeCocoaWindow() != null) break :blk "macos";
        if (win.nativeWin32Hwnd() != null) break :blk "windows";
        break :blk "unknown";
    };

    try ctx.reply(.{
        .x = pos[0],
        .y = pos[1],
        .width = win.logical_width,
        .height = win.logical_height,
        .drawableWidth = win.drawable_width,
        .drawableHeight = win.drawable_height,
        .nativeHandle = native_handle,
        .platform = platform,
    });
}

/// Attach the engine's SDL window as a child of an external native window.
/// On macOS, parentHandle should be the integer value of an NSView* pointer.
pub fn attachToParent(ctx: *Ctx) !void {
    const handle_value = try ctx.param(u64, "parentHandle");
    if (handle_value == 0) return error.InvalidArguments;

    const parent_ptr: *anyopaque = @ptrFromInt(handle_value);
    const win = ctx.layer.window;

    if (!win.attachToParent(parent_ptr)) {
        std.log.err("viewport.attachToParent: native attach failed", .{});
        return error.NativeWindowOperationFailed;
    }

    try ctx.reply(.{});
}

/// Detach the engine's SDL window from its parent.
pub fn detachFromParent(ctx: *Ctx) !void {
    const win = ctx.layer.window;
    _ = win.detachFromParent();
    try ctx.reply(.{});
}

/// Return the shared surface handle for the viewport's color texture.
/// - macOS: surfaceId is an IOSurface ID for IOSurfaceLookup()
/// - Linux: shmName is a POSIX shared memory path ("/guava-vp-...")
pub fn getSurfaceId(ctx: *Ctx) !void {
    const sv = &ctx.layer.renderer.scene_viewport;
    const shm_slice = std.mem.sliceTo(&sv.shm_name, 0);
    // Prefer staging surface (never written by GPU, always safe to read).
    const surface_id = if (sv.staging_iosurface_id != 0)
        sv.staging_iosurface_id
    else
        sv.iosurface_id;
    try ctx.reply(.{
        .surfaceId = surface_id,
        .shmName = if (shm_slice.len > 0) shm_slice else null,
        .width = sv.width,
        .height = sv.height,
    });
}

// ── Render settings ──────────────────────────────────────────────

const render_types = @import("../../render/types.zig");
const ViewportState = render_types.EditorViewportState;

/// Compute high-level shading mode from render_mode + pipeline_mode.
fn shadingModeName(state: *const ViewportState) []const u8 {
    if (state.pipeline_mode == .path_trace) return "rendered";
    return switch (state.render_mode) {
        .textured => "material",
        .wireframe => "wireframe",
        .unlit => "solid",
    };
}

/// Return current viewport render settings.
pub fn getRenderSettings(ctx: *Ctx) !void {
    const state = &ctx.layer.renderer.editor_viewport_state;
    try ctx.reply(.{
        .shadingMode = shadingModeName(state),
        .showGrid = state.show_grid,
        .showBones = state.show_bones,
        .showCollision = state.show_collision,
        .bloomEnabled = state.bloom_enabled,
        .bloomThreshold = state.bloom_threshold,
        .bloomIntensity = state.bloom_intensity,
        .exposureEnabled = state.exposure_enabled,
        .exposure = state.exposure,
        .ssaoEnabled = state.ssao_enabled,
        .ssaoRadius = state.ssao_radius,
        .ssaoIntensity = state.ssao_intensity,
        .ssaoBias = state.ssao_bias,
        .ssaoPower = state.ssao_power,
        .fxaaEnabled = state.fxaa_enabled,
        .taaEnabled = state.taa_enabled,
        .taaBlendFactor = state.taa_blend_factor,
        .taaMotionBlurScale = state.taa_motion_blur_scale,
        .taaFeedbackMin = state.taa_feedback_min,
        .taaFeedbackMax = state.taa_feedback_max,
        .contactShadowsEnabled = state.contact_shadows_enabled,
        .contactShadowsDistance = state.contact_shadows_distance,
        .contactShadowsThickness = state.contact_shadows_thickness,
        .contactShadowsIntensity = state.contact_shadows_intensity,
        .contactShadowsBias = state.contact_shadows_bias,
        .contactShadowsSteps = state.contact_shadows_steps,
        .ssrEnabled = state.ssr_enabled,
        .ssrIntensity = state.ssr_intensity,
        .ssrRayStep = state.ssr_ray_step,
        .ssrMaxDistance = state.ssr_ray_max_distance,
        .ssrThickness = state.ssr_ray_thickness,
        .ssrFadeDistance = state.ssr_fade_distance,
        .ssrEdgeFade = state.ssr_edge_fade,
        .ssrRoughnessBlur = state.ssr_roughness_blur_strength,
        .ssgiEnabled = state.ssgi_enabled,
        .ssgiRadius = state.ssgi_radius,
        .ssgiIntensity = state.ssgi_intensity,
        .ssgiBias = state.ssgi_bias,
        .ssgiRayCount = state.ssgi_ray_count,
        .ssgiStepCount = state.ssgi_step_count,
        .colorGradingEnabled = state.color_grading_enabled,
        .colorGradingSaturation = state.color_grading_saturation,
        .colorGradingContrast = state.color_grading_contrast,
        .colorGradingGamma = state.color_grading_gamma,
        .dofEnabled = state.dof_enabled,
        .dofFocusDistance = state.dof_focus_distance,
        .dofFocusRange = state.dof_focus_range,
        .dofBlurRadius = state.dof_blur_radius,
        .dofBokehRadius = state.dof_bokeh_radius,
        .dofNearBlur = state.dof_near_blur,
        .dofFarBlur = state.dof_far_blur,
        .dofQuality = state.dof_quality,
        .lutEnabled = state.lut_enabled,
        .lutIntensity = state.lut_intensity,
        .lutPreset = @tagName(state.lut_preset),
        .volumetricFogEnabled = state.volumetric_fog_enabled,
        .volumetricFogDensity = state.volumetric_fog_density,
        .volumetricFogHeightFalloff = state.volumetric_fog_height_falloff,
        .volumetricFogMaxDistance = state.volumetric_fog_max_distance,
        .rtShadowsEnabled = state.rt_shadows_enabled,
        .rtShadowSamples = state.rt_shadow_samples,
        .rtShadowStrength = state.rt_shadow_strength,
        .rtShadowSoftness = state.rt_shadow_softness,
        .rtShadowResolutionScale = state.rt_shadow_resolution_scale,
    });
}

/// Apply partial viewport render settings (only provided fields are updated).
pub fn setRenderSettings(ctx: *Ctx) !void {
    var state = ctx.layer.renderer.editor_viewport_state;

    // High-level shading mode shortcut
    if (try ctx.paramOpt([]const u8, "shadingMode")) |mode| {
        if (std.mem.eql(u8, mode, "solid")) {
            state.pipeline_mode = .raster;
            state.render_mode = .unlit;
        } else if (std.mem.eql(u8, mode, "material")) {
            state.pipeline_mode = .raster;
            state.render_mode = .textured;
        } else if (std.mem.eql(u8, mode, "rendered")) {
            state.pipeline_mode = .path_trace;
            state.render_mode = .textured;
        } else if (std.mem.eql(u8, mode, "wireframe")) {
            state.pipeline_mode = .raster;
            state.render_mode = .wireframe;
        }
    }

    // Visibility toggles
    if (try ctx.paramOpt(bool, "showGrid")) |v| state.show_grid = v;
    if (try ctx.paramOpt(bool, "showBones")) |v| state.show_bones = v;
    if (try ctx.paramOpt(bool, "showCollision")) |v| state.show_collision = v;

    // Bloom
    if (try ctx.paramOpt(bool, "bloomEnabled")) |v| state.bloom_enabled = v;
    if (try ctx.paramOpt(f64, "bloomThreshold")) |v| state.bloom_threshold = @floatCast(v);
    if (try ctx.paramOpt(f64, "bloomIntensity")) |v| state.bloom_intensity = @floatCast(v);

    // Exposure
    if (try ctx.paramOpt(bool, "exposureEnabled")) |v| state.exposure_enabled = v;
    if (try ctx.paramOpt(f64, "exposure")) |v| state.exposure = @floatCast(v);

    // SSAO
    if (try ctx.paramOpt(bool, "ssaoEnabled")) |v| state.ssao_enabled = v;
    if (try ctx.paramOpt(f64, "ssaoRadius")) |v| state.ssao_radius = @floatCast(v);
    if (try ctx.paramOpt(f64, "ssaoIntensity")) |v| state.ssao_intensity = @floatCast(v);
    if (try ctx.paramOpt(f64, "ssaoBias")) |v| state.ssao_bias = @floatCast(v);
    if (try ctx.paramOpt(f64, "ssaoPower")) |v| state.ssao_power = @floatCast(v);

    // Anti-aliasing
    if (try ctx.paramOpt(bool, "fxaaEnabled")) |v| state.fxaa_enabled = v;
    if (try ctx.paramOpt(bool, "taaEnabled")) |v| state.taa_enabled = v;
    if (try ctx.paramOpt(f64, "taaBlendFactor")) |v| state.taa_blend_factor = @floatCast(v);
    if (try ctx.paramOpt(f64, "taaMotionBlurScale")) |v| state.taa_motion_blur_scale = @floatCast(v);
    if (try ctx.paramOpt(f64, "taaFeedbackMin")) |v| state.taa_feedback_min = @floatCast(v);
    if (try ctx.paramOpt(f64, "taaFeedbackMax")) |v| state.taa_feedback_max = @floatCast(v);

    // Contact Shadows
    if (try ctx.paramOpt(bool, "contactShadowsEnabled")) |v| state.contact_shadows_enabled = v;
    if (try ctx.paramOpt(f64, "contactShadowsDistance")) |v| state.contact_shadows_distance = @floatCast(v);
    if (try ctx.paramOpt(f64, "contactShadowsThickness")) |v| state.contact_shadows_thickness = @floatCast(v);
    if (try ctx.paramOpt(f64, "contactShadowsIntensity")) |v| state.contact_shadows_intensity = @floatCast(v);
    if (try ctx.paramOpt(f64, "contactShadowsBias")) |v| state.contact_shadows_bias = @floatCast(v);
    if (try ctx.paramOpt(u64, "contactShadowsSteps")) |v| state.contact_shadows_steps = @intCast(v);

    // SSR
    if (try ctx.paramOpt(bool, "ssrEnabled")) |v| state.ssr_enabled = v;
    if (try ctx.paramOpt(f64, "ssrIntensity")) |v| state.ssr_intensity = @floatCast(v);
    if (try ctx.paramOpt(f64, "ssrRayStep")) |v| state.ssr_ray_step = @floatCast(v);
    if (try ctx.paramOpt(f64, "ssrMaxDistance")) |v| state.ssr_ray_max_distance = @floatCast(v);
    if (try ctx.paramOpt(f64, "ssrThickness")) |v| state.ssr_ray_thickness = @floatCast(v);
    if (try ctx.paramOpt(f64, "ssrFadeDistance")) |v| state.ssr_fade_distance = @floatCast(v);
    if (try ctx.paramOpt(f64, "ssrEdgeFade")) |v| state.ssr_edge_fade = @floatCast(v);
    if (try ctx.paramOpt(f64, "ssrRoughnessBlur")) |v| state.ssr_roughness_blur_strength = @floatCast(v);

    // SSGI
    if (try ctx.paramOpt(bool, "ssgiEnabled")) |v| state.ssgi_enabled = v;
    if (try ctx.paramOpt(f64, "ssgiRadius")) |v| state.ssgi_radius = @floatCast(v);
    if (try ctx.paramOpt(f64, "ssgiIntensity")) |v| state.ssgi_intensity = @floatCast(v);
    if (try ctx.paramOpt(f64, "ssgiBias")) |v| state.ssgi_bias = @floatCast(v);
    if (try ctx.paramOpt(u64, "ssgiRayCount")) |v| state.ssgi_ray_count = @intCast(v);
    if (try ctx.paramOpt(u64, "ssgiStepCount")) |v| state.ssgi_step_count = @intCast(v);

    // Color Grading
    if (try ctx.paramOpt(bool, "colorGradingEnabled")) |v| state.color_grading_enabled = v;
    if (try ctx.paramOpt(f64, "colorGradingSaturation")) |v| state.color_grading_saturation = @floatCast(v);
    if (try ctx.paramOpt(f64, "colorGradingContrast")) |v| state.color_grading_contrast = @floatCast(v);
    if (try ctx.paramOpt(f64, "colorGradingGamma")) |v| state.color_grading_gamma = @floatCast(v);

    // DOF
    if (try ctx.paramOpt(bool, "dofEnabled")) |v| state.dof_enabled = v;
    if (try ctx.paramOpt(f64, "dofFocusDistance")) |v| state.dof_focus_distance = @floatCast(v);
    if (try ctx.paramOpt(f64, "dofFocusRange")) |v| state.dof_focus_range = @floatCast(v);
    if (try ctx.paramOpt(f64, "dofBlurRadius")) |v| state.dof_blur_radius = @floatCast(v);
    if (try ctx.paramOpt(f64, "dofBokehRadius")) |v| state.dof_bokeh_radius = @floatCast(v);
    if (try ctx.paramOpt(f64, "dofNearBlur")) |v| state.dof_near_blur = @floatCast(v);
    if (try ctx.paramOpt(f64, "dofFarBlur")) |v| state.dof_far_blur = @floatCast(v);
    if (try ctx.paramOpt(u64, "dofQuality")) |v| state.dof_quality = @intCast(v);

    // LUT
    if (try ctx.paramOpt(bool, "lutEnabled")) |v| state.lut_enabled = v;
    if (try ctx.paramOpt(f64, "lutIntensity")) |v| state.lut_intensity = @floatCast(v);
    if (try ctx.paramOpt([]const u8, "lutPreset")) |v| {
        if (std.mem.eql(u8, v, "neutral")) state.lut_preset = .neutral else if (std.mem.eql(u8, v, "warm")) state.lut_preset = .warm else if (std.mem.eql(u8, v, "cool")) state.lut_preset = .cool else if (std.mem.eql(u8, v, "filmic")) state.lut_preset = .filmic;
    }

    // Volumetric Fog
    if (try ctx.paramOpt(bool, "volumetricFogEnabled")) |v| state.volumetric_fog_enabled = v;
    if (try ctx.paramOpt(f64, "volumetricFogDensity")) |v| state.volumetric_fog_density = @floatCast(v);
    if (try ctx.paramOpt(f64, "volumetricFogHeightFalloff")) |v| state.volumetric_fog_height_falloff = @floatCast(v);
    if (try ctx.paramOpt(f64, "volumetricFogMaxDistance")) |v| state.volumetric_fog_max_distance = @floatCast(v);

    // RT Shadows
    if (try ctx.paramOpt(bool, "rtShadowsEnabled")) |v| state.rt_shadows_enabled = v;
    if (try ctx.paramOpt(u64, "rtShadowSamples")) |v| state.rt_shadow_samples = @intCast(v);
    if (try ctx.paramOpt(f64, "rtShadowStrength")) |v| state.rt_shadow_strength = @floatCast(v);
    if (try ctx.paramOpt(f64, "rtShadowSoftness")) |v| state.rt_shadow_softness = @floatCast(v);
    if (try ctx.paramOpt(f64, "rtShadowResolutionScale")) |v| state.rt_shadow_resolution_scale = @floatCast(v);

    ctx.layer.renderer.setEditorViewportState(state);
    try ctx.reply(.{});
}

// ── Input forwarding ─────────────────────────────────────────────

const input_mod = @import("../../core/input.zig");

fn mapKey(name: []const u8) ?input_mod.Key {
    const map = .{
        .{ "w", .w },           .{ "a", .a },                 .{ "s", .s },
        .{ "d", .d },           .{ "b", .b },                 .{ "i", .i },
        .{ "m", .m },           .{ "q", .q },                 .{ "e", .e },
        .{ "f", .f },           .{ "g", .g },                 .{ "r", .r },
        .{ "t", .t },           .{ "n", .n },                 .{ "l", .l },
        .{ "o", .o },           .{ "p", .p },                 .{ "x", .x },
        .{ "y", .y },           .{ "z", .z },                 .{ "tab", .tab },
        .{ "delete", .delete }, .{ "backspace", .backspace }, .{ "1", .one },
        .{ "2", .two },         .{ "3", .three },             .{ "shift", .shift },
        .{ "ctrl", .ctrl },     .{ "alt", .alt },             .{ "space", .space },
        .{ "escape", .escape }, .{ "period", .period },       .{ "up", .up },
        .{ "down", .down },     .{ "left", .left },           .{ "right", .right },
        .{ "f1", .f1 },         .{ "f2", .f2 },               .{ "f3", .f3 },
        .{ "f4", .f4 },         .{ "f5", .f5 },               .{ "f6", .f6 },
        .{ "f7", .f7 },         .{ "f8", .f8 },               .{ "f9", .f9 },
        .{ "f10", .f10 },       .{ "f11", .f11 },             .{ "f12", .f12 },
    };
    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

fn mapMouseButton(name: []const u8) ?input_mod.MouseButton {
    if (std.mem.eql(u8, name, "left")) return .left;
    if (std.mem.eql(u8, name, "right")) return .right;
    if (std.mem.eql(u8, name, "middle")) return .middle;
    return null;
}

/// Forward a mouse/keyboard event from Electron to the engine input system.
/// Params:
///   type: "mousemove" | "mousedown" | "mouseup" | "wheel" | "keydown" | "keyup"
///   x, y: f64          — mouse position (viewport-relative, physical pixels)
///   button: string      — "left" | "right" | "middle" (for mouse button events)
///   clicks: u64         — click count (for double-click detection)
///   deltaX, deltaY: f64 — wheel delta
///   key: string         — key name (for keyboard events)
///   shift, ctrl, alt: bool — modifier state
/// Set the engine frame rate limit.
/// Params:
///   fps: u64 — target FPS (0 = unlimited/VSync, 30/60/120 etc.)
pub fn setFrameRate(ctx: *Ctx) !void {
    const fps = try ctx.param(u64, "fps");
    const delay: u32 = if (fps == 0) 0 else @intCast(@max(1, 1000 / fps));
    ctx.layer.renderer.pending_frame_delay_ms = delay;
    try ctx.reply(.{});
}

/// Get the current frame rate limit.
pub fn getFrameRate(ctx: *Ctx) !void {
    const delay = ctx.layer.renderer.current_frame_delay_ms;
    const fps: u64 = if (delay == 0) 0 else 1000 / @as(u64, delay);
    try ctx.reply(.{ .fps = fps, .frameDelayMs = delay });
}

pub fn sendInput(ctx: *Ctx) !void {
    const input = ctx.layer.input;
    const event_type = try ctx.param([]const u8, "type");

    // Update modifiers
    if (try ctx.paramOpt(bool, "shift")) |v| input.modifiers.shift = v;
    if (try ctx.paramOpt(bool, "ctrl")) |v| input.modifiers.ctrl = v;
    if (try ctx.paramOpt(bool, "alt")) |v| input.modifiers.alt = v;

    if (std.mem.eql(u8, event_type, "mousemove")) {
        const x: f32 = @floatCast(try ctx.param(f64, "x"));
        const y: f32 = @floatCast(try ctx.param(f64, "y"));
        const dx: f32 = @floatCast((try ctx.paramOpt(f64, "deltaX")) orelse 0);
        const dy: f32 = @floatCast((try ctx.paramOpt(f64, "deltaY")) orelse 0);
        input.addMouseDelta(x, y, dx, dy);
    } else if (std.mem.eql(u8, event_type, "mousedown")) {
        const x: f32 = @floatCast(try ctx.param(f64, "x"));
        const y: f32 = @floatCast(try ctx.param(f64, "y"));
        input.updateMousePosition(x, y);
        if (try ctx.paramOpt([]const u8, "button")) |btn| {
            if (mapMouseButton(btn)) |mb| {
                const clicks: u8 = @intCast((try ctx.paramOpt(u64, "clicks")) orelse 1);
                input.setMouseButton(mb, true, clicks);
            }
        }
    } else if (std.mem.eql(u8, event_type, "mouseup")) {
        const x: f32 = @floatCast(try ctx.param(f64, "x"));
        const y: f32 = @floatCast(try ctx.param(f64, "y"));
        input.updateMousePosition(x, y);
        if (try ctx.paramOpt([]const u8, "button")) |btn| {
            if (mapMouseButton(btn)) |mb| {
                input.setMouseButton(mb, false, 0);
            }
        }
    } else if (std.mem.eql(u8, event_type, "wheel")) {
        const wx: f32 = @floatCast((try ctx.paramOpt(f64, "deltaX")) orelse 0);
        const wy: f32 = @floatCast((try ctx.paramOpt(f64, "deltaY")) orelse 0);
        input.addMouseWheel(wx, wy);
    } else if (std.mem.eql(u8, event_type, "keydown")) {
        if (try ctx.paramOpt([]const u8, "key")) |key_name| {
            if (mapKey(key_name)) |key| {
                input.setKey(key, true);
            }
        }
    } else if (std.mem.eql(u8, event_type, "keyup")) {
        if (try ctx.paramOpt([]const u8, "key")) |key_name| {
            if (mapKey(key_name)) |key| {
                input.setKey(key, false);
            }
        }
    }

    try ctx.reply(.{});
}

/// Request entity picking at a given viewport pixel coordinate.
/// Uses the GPU ID pass texture for async readback — the result will be
/// reflected in selection state and pushed via "on:selection.changed".
///
/// Params:
///   x, y: u32                — pixel coordinates in physical (drawable) pixels
///   mode: "replace"|"toggle" — selection mode (default: "replace")
pub fn pick(ctx: *Ctx) !void {
    const selection_mod = @import("../../render/selection_history.zig");

    const x: u32 = @intCast(try ctx.param(u64, "x"));
    const y: u32 = @intCast(try ctx.param(u64, "y"));

    const mode_str = (try ctx.paramOpt([]const u8, "mode")) orelse "replace";
    const mode: selection_mod.SelectionUpdateMode = if (std.mem.eql(u8, mode_str, "toggle"))
        .toggle
    else
        .replace;

    try ctx.layer.renderer.pending_selection_readbacks.append(ctx.layer.renderer.allocator, .{
        .pixel_x = x,
        .pixel_y = y,
        .mode = mode,
    });

    try ctx.reply(.{});
}

/// Select all entities whose world-space position projects inside a
/// screen-space rectangle.
///
/// Params:
///   x1, y1, x2, y2: u32     — rectangle corners in physical (drawable) pixels
///   mode: "replace"|"toggle" — selection mode (default: "replace")
pub fn boxSelect(ctx: *Ctx) !void {
    const x1: u32 = @intCast(try ctx.param(u64, "x1"));
    const y1: u32 = @intCast(try ctx.param(u64, "y1"));
    const x2: u32 = @intCast(try ctx.param(u64, "x2"));
    const y2: u32 = @intCast(try ctx.param(u64, "y2"));

    // Normalise so min <= max
    const min_x: f32 = @floatFromInt(@min(x1, x2));
    const min_y: f32 = @floatFromInt(@min(y1, y2));
    const max_x: f32 = @floatFromInt(@max(x1, x2));
    const max_y: f32 = @floatFromInt(@max(y1, y2));

    const mode_str = (try ctx.paramOpt([]const u8, "mode")) orelse "replace";

    const renderer = ctx.layer.renderer;
    const vp = renderer.prev_view_projection;
    const sv = &renderer.scene_viewport;
    const vp_w: f32 = @floatFromInt(sv.width);
    const vp_h: f32 = @floatFromInt(sv.height);

    if (vp_w == 0 or vp_h == 0) {
        try ctx.reply(.{ .selectedIds = &[_]u64{} });
        return;
    }

    const world = ctx.layer.world;
    var hits = std.ArrayList(u64).empty;
    defer hits.deinit(ctx.allocator);

    for (world.entities.items) |entity| {
        // Skip editor-only entities (editor camera, grid helper, etc.)
        if (entity.editor_only) continue;
        // Skip folders
        if (entity.is_folder) continue;

        const pos = entity.world_transform_cache.translation;

        // Multiply world position by view-projection matrix (column-major)
        const clip_x = vp[0] * pos[0] + vp[4] * pos[1] + vp[8] * pos[2] + vp[12];
        const clip_y = vp[1] * pos[0] + vp[5] * pos[1] + vp[9] * pos[2] + vp[13];
        const clip_w = vp[3] * pos[0] + vp[7] * pos[1] + vp[11] * pos[2] + vp[15];

        // Behind camera — skip
        if (clip_w <= 0.0) continue;

        // NDC → pixel
        const ndc_x = clip_x / clip_w;
        const ndc_y = clip_y / clip_w;
        const screen_x = (ndc_x + 1.0) * 0.5 * vp_w;
        const screen_y = (1.0 - ndc_y) * 0.5 * vp_h;

        if (screen_x >= min_x and screen_x <= max_x and
            screen_y >= min_y and screen_y <= max_y)
        {
            try hits.append(ctx.allocator, entity.id);
        }
    }

    // Apply selection
    if (std.mem.eql(u8, mode_str, "toggle")) {
        for (hits.items) |hit_id| {
            _ = try renderer.selection_history.applyPick(hit_id, .toggle);
        }
    } else {
        _ = try renderer.selection_history.replaceSelection(hits.items);
    }

    try ctx.reply(.{ .selectedIds = hits.items });
}

pub fn screenshot(ctx: *Ctx) !void {
    const screenshot_tool = @import("../../mcp/screenshot_tool.zig");
    const data_uri = try screenshot_tool.screenshotAsDataUriAlloc(ctx.allocator, ctx.layer);
    defer ctx.allocator.free(data_uri);
    // Transfer ownership to ctx result
    const owned = try ctx.allocator.dupe(u8, data_uri);
    _ = owned;
    try ctx.reply(.{ .dataUri = data_uri });
}
