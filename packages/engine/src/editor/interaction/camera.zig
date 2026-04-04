const std = @import("std");
const engine = @import("guava");
const mat4 = engine.math.mat4;
const vec3 = engine.math.vec3;
const quat = engine.math.quat;
const state_mod = @import("../core/state.zig");
const EditorState = state_mod.EditorState;
const utils = @import("../common/utils.zig");
const viewport_log = std.log.scoped(.viewport_input);

pub const ViewPreset = state_mod.ViewportViewPreset;

pub fn handleCameraControls(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const input = layer_context.input;
    // Use wantsTextInput() — wantsCaptureKeyboard() is almost always
    // true when NavEnableKeyboard is enabled, blocking camera controls.
    const can_capture_viewport = state.viewport_has_image and
        state.viewport_hovered and
        state.viewport_focused and
        !state.viewport_overlay_hovered;

    // DCC ergonomics:
    // Alt+LMB orbit, MMB pan, Alt+RMB dolly, RMB freelook+WASDQE move.
    const orbit_active = input.modifiers.alt and input.isMouseDown(.left);
    const pan_active = input.isMouseDown(.middle);
    const dolly_active = input.modifiers.alt and input.isMouseDown(.right);
    const freelook_active = !input.modifiers.alt and input.isMouseDown(.right);
    const is_camera_drag_input = orbit_active or pan_active or dolly_active or freelook_active;

    if (state.view_cube_transition_active and is_camera_drag_input) {
        state.view_cube_transition_active = false;
    }
    updateViewCubeTransition(state, layer_context);

    const mouse_pressed = input.wasMousePressed(.right) or input.wasMousePressed(.middle) or
        (input.modifiers.alt and input.wasMousePressed(.left));
    if (mouse_pressed) {
        viewport_log.info(
            "camera press capture={} hovered={} focused={} overlay_hovered={} has_image={} ui_lock={} alt={} l={} r={} m={}",
            .{
                can_capture_viewport,
                state.viewport_hovered,
                state.viewport_focused,
                state.viewport_overlay_hovered,
                state.viewport_has_image,
                state.manipulation_started_from_ui,
                input.modifiers.alt,
                input.wasMousePressed(.left),
                input.wasMousePressed(.right),
                input.wasMousePressed(.middle),
            },
        );
    }
    if (mouse_pressed and can_capture_viewport) {
        state.camera_drag_active = true;
        viewport_log.info("camera drag activated", .{});
    } else if (mouse_pressed and !can_capture_viewport) {
        viewport_log.warn(
            "camera drag blocked capture={} hovered={} focused={} overlay_hovered={} manipulation_mode={s}",
            .{
                can_capture_viewport,
                state.viewport_hovered,
                state.viewport_focused,
                state.viewport_overlay_hovered,
                @tagName(state.manipulation_mode),
            },
        );
    }
    const prev_drag_active = state.camera_drag_active;
    if (!is_camera_drag_input) {
        state.camera_drag_active = false;
    }
    // 拖拽状态转变时切换相对鼠标模式：
    // 开始拖拽→锁定光标，鼠标增量不受屏幕边缘限制，摄像机可连续旋转/平移任意距离。
    if (state.camera_drag_active != prev_drag_active) {
        layer_context.window.setRelativeMouseMode(state.camera_drag_active);
    }

    const camera_id = controlledCameraEntity(state, layer_context) orelse return;
    const camera = layer_context.world.getEntity(camera_id) orelse return;
    var camera_transform_changed = false;

    if (state.camera_drag_active) {
        if (orbit_active) {
            state.yaw -= input.mouse_delta[0] * state.orbit_sensitivity;
            state.pitch = utils.clampPitch(state.pitch - input.mouse_delta[1] * state.orbit_sensitivity);
            if (@abs(input.mouse_delta[0]) > 0.0001 or @abs(input.mouse_delta[1]) > 0.0001) {
                state.viewport_view_preset = .custom;
                if (camera.camera) |camera_component| {
                    var next_camera = camera_component;
                    next_camera.projection = .{ .perspective = .{} };
                    camera.camera = next_camera;
                }
            }
            const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
            camera.local_transform.rotation = quat.fromEuler(.{ state.pitch, state.yaw, 0.0 });
            camera.local_transform.translation = vec3.sub(state.focus_pivot, vec3.scale(forward, state.orbit_distance));
            camera_transform_changed = true;
        }

        if (pan_active) {
            const right = vec3.rightFromYaw(state.yaw);
            const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
            const up = vec3.normalize(vec3.cross(right, forward));
            const pan_factors = panSpeedFactors(state.viewport_extent);
            const pan = vec3.add(
                vec3.scale(right, -input.mouse_delta[0] * pan_factors[0] * state.orbit_distance * state.pan_sensitivity),
                vec3.scale(up, input.mouse_delta[1] * pan_factors[1] * state.orbit_distance * state.pan_sensitivity),
            );
            camera.local_transform.translation = vec3.add(camera.local_transform.translation, pan);
            state.focus_pivot = vec3.add(state.focus_pivot, pan);
            camera_transform_changed = true;
        }

        if (dolly_active) {
            const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
            const dolly_step = -input.mouse_delta[1] * state.wheel_speed * 0.01 * zoomSpeed(state.orbit_distance);
            camera.local_transform.translation = vec3.add(camera.local_transform.translation, vec3.scale(forward, dolly_step));
            state.orbit_distance = utils.clampDistance(vec3.length(vec3.sub(state.focus_pivot, camera.local_transform.translation)));
            camera_transform_changed = true;
        }

        if (freelook_active) {
            state.yaw -= input.mouse_delta[0] * state.look_sensitivity;
            state.pitch = utils.clampPitch(state.pitch - input.mouse_delta[1] * state.look_sensitivity);
            const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
            const right = vec3.rightFromYaw(state.yaw);
            const up = vec3.normalize(vec3.cross(right, forward));

            var move_direction = [3]f32{ 0.0, 0.0, 0.0 };
            if (input.isKeyDown(.w)) move_direction = vec3.add(move_direction, forward);
            if (input.isKeyDown(.s)) move_direction = vec3.sub(move_direction, forward);
            if (input.isKeyDown(.d)) move_direction = vec3.add(move_direction, right);
            if (input.isKeyDown(.a)) move_direction = vec3.sub(move_direction, right);
            if (input.isKeyDown(.e)) move_direction = vec3.add(move_direction, up);
            if (input.isKeyDown(.q)) move_direction = vec3.sub(move_direction, up);

            if (vec3.length(move_direction) > 0.0001) {
                const normalized_move = vec3.normalize(move_direction);
                const speed_multiplier: f32 = if (input.modifiers.shift) state.camera_boost_multiplier else 1.0;
                const movement_step = moveSpeed(state, layer_context.delta_seconds) * speed_multiplier;
                const translation_delta = vec3.scale(normalized_move, movement_step);
                camera.local_transform.translation = vec3.add(camera.local_transform.translation, translation_delta);
                state.focus_pivot = vec3.add(state.focus_pivot, translation_delta);
            }

            camera.local_transform.rotation = quat.fromEuler(.{ state.pitch, state.yaw, 0.0 });
            state.viewport_view_preset = .custom;
            camera_transform_changed = true;
        }
    }

    // Always process wheel zoom/pan on hovered+focused viewport.
    if (can_capture_viewport) {
        if (@abs(input.mouse_wheel[1]) > 0.001) {
            const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
            const zoom_ratio = wheelZoomRatio(input.mouse_wheel[1], state.wheel_speed);

            if (camera.camera) |camera_component| {
                switch (camera_component.projection) {
                    .perspective => {
                        const next_distance = utils.clampDistance(state.orbit_distance * zoom_ratio);
                        state.orbit_distance = next_distance;
                        camera.local_transform.translation = vec3.sub(state.focus_pivot, vec3.scale(forward, next_distance));
                    },
                    .orthographic => |projection| {
                        const next_size = clampOrthographicSize(projection.size * zoom_ratio);
                        const size_ratio = next_size / @max(projection.size, 0.0001);
                        const next_distance = utils.clampDistance(state.orbit_distance * size_ratio);
                        state.orbit_distance = next_distance;
                        camera.local_transform.translation = vec3.sub(state.focus_pivot, vec3.scale(forward, next_distance));

                        var next_camera = camera_component;
                        next_camera.projection.orthographic.size = next_size;
                        camera.camera = next_camera;
                    },
                }
            } else {
                const next_distance = utils.clampDistance(state.orbit_distance * zoom_ratio);
                state.orbit_distance = next_distance;
                camera.local_transform.translation = vec3.sub(state.focus_pivot, vec3.scale(forward, next_distance));
            }
            camera_transform_changed = true;
        }

        if (@abs(input.mouse_wheel[0]) > 0.001) {
            const right = vec3.rightFromYaw(state.yaw);
            const pan_step = input.mouse_wheel[0] * state.wheel_speed * wheelPanDistance(camera.camera, state.viewport_extent, state.orbit_distance);
            const pan = vec3.scale(right, pan_step);
            camera.local_transform.translation = vec3.add(camera.local_transform.translation, pan);
            state.focus_pivot = vec3.add(state.focus_pivot, pan);
            camera_transform_changed = true;
        }
    }
    camera.local_transform.rotation = quat.fromEuler(.{ state.pitch, state.yaw, 0.0 });
    if (camera_transform_changed) {
        layer_context.world.markDirty(camera_id);
    }
}

pub fn toggleCameraMode(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    if (state.manipulation_mode != .none) {
        return;
    }
    if (state.editor_camera_active) {
        _ = activateSceneCamera(state, layer_context, null);
        return;
    }

    _ = activateEditorCamera(state, layer_context);
}

pub fn activateEditorCamera(state: *EditorState, layer_context: *engine.core.LayerContext) bool {
    const editor_camera_id = state.editor_camera orelse return false;
    if (!layer_context.world.hasEntity(editor_camera_id)) return false;
    _ = layer_context.world.setPrimaryCamera(editor_camera_id);
    state.editor_camera_active = true;
    syncOrbitStateFromEntity(state, layer_context, editor_camera_id);
    return true;
}

pub fn activateSceneCamera(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    preferred_camera_id: ?engine.scene.EntityId,
) bool {
    const scene_camera_id = resolveSceneCameraEntity(state, layer_context, preferred_camera_id) orelse return false;
    _ = layer_context.world.setPrimaryCamera(scene_camera_id);
    state.scene_camera = scene_camera_id;
    state.editor_camera_active = false;
    syncOrbitStateFromEntity(state, layer_context, scene_camera_id);
    return true;
}

pub fn lookThroughCamera(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    camera_id: engine.scene.EntityId,
) bool {
    return activateSceneCamera(state, layer_context, camera_id);
}

pub fn focusSelection(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    const selected = layer_context.renderer.selectedEntity() orelse return;
    const camera_id = controlledCameraEntity(state, layer_context) orelse return;
    const camera = layer_context.world.getEntity(camera_id) orelse return;
    const entity_transform = layer_context.world.worldTransform(selected) orelse return;
    const camera_component = camera.camera orelse return;

    const focus_radius = selectionFocusRadius(layer_context, selected);
    state.focus_pivot = selectionFocusPivot(layer_context, selected, entity_transform.translation);

    const viewport_size = layer_context.renderer.sceneViewportSize();
    const viewport_aspect = if (viewport_size[0] > 0 and viewport_size[1] > 0)
        @as(f32, @floatFromInt(viewport_size[0])) / @as(f32, @floatFromInt(viewport_size[1]))
    else
        1.0;

    switch (camera_component.projection) {
        .perspective => |projection| {
            state.orbit_distance = focusDistanceForPerspective(focus_radius, projection.fov_y_radians, viewport_aspect, projection.near_clip);
        },
        .orthographic => |projection| {
            const next_distance = utils.clampDistance(@max(focus_radius * 2.5, 2.0));
            state.orbit_distance = next_distance;
            camera.camera = .{
                .projection = .{
                    .orthographic = .{
                        .size = focusOrthoSize(focus_radius),
                        .near_clip = projection.near_clip,
                        .far_clip = projection.far_clip,
                    },
                },
                .is_primary = camera_component.is_primary,
            };
        },
    }

    const forward = vec3.forwardFromAngles(state.yaw, state.pitch);
    state.orbit_distance = utils.clampDistance(state.orbit_distance);
    camera.local_transform.translation = vec3.sub(state.focus_pivot, vec3.scale(forward, state.orbit_distance));
    layer_context.world.markDirty(camera_id);
}

pub fn createEditorCamera(state: *EditorState, layer_context: *engine.core.LayerContext) !void {
    const transform = editorCameraTransform(state);
    state.editor_camera = try layer_context.world.createEntity(.{
        .name = "EditorCamera",
        .camera = .{
            .is_primary = true,
        },
        .local_transform = transform,
        .editor_only = true,
    });
    if (state.editor_camera_active) {
        _ = layer_context.world.setPrimaryCamera(state.editor_camera.?);
    }
}

pub fn setViewPreset(state: *EditorState, layer_context: *engine.core.LayerContext, preset: ViewPreset) void {
    switch (preset) {
        .perspective => requestViewOrientation(state, layer_context, vec3.normalize(.{ -0.45, -0.32, -0.84 }), false, .perspective),
        .top => requestViewOrientation(state, layer_context, .{ 0.0, -1.0, 0.0 }, true, .top),
        .side => requestViewOrientation(state, layer_context, .{ -1.0, 0.0, 0.0 }, true, .side),
        .custom => {},
    }
}

pub fn lookAlongWorldAxis(state: *EditorState, layer_context: *engine.core.LayerContext, axis: [3]f32) void {
    requestViewOrientation(state, layer_context, vec3.normalize(axis), true, viewPresetForAxis(axis));
}

pub fn orbitFromViewCubeDrag(state: *EditorState, layer_context: *engine.core.LayerContext, drag_delta: [2]f32) void {
    const camera_id = state.editor_camera orelse return;
    const camera_entity = layer_context.world.getEntity(camera_id) orelse return;

    state.view_cube_transition_active = false;
    state.yaw -= drag_delta[0] * state.orbit_sensitivity;
    state.pitch = utils.clampPitch(state.pitch - drag_delta[1] * state.orbit_sensitivity);
    state.viewport_view_preset = .custom;

    if (camera_entity.camera) |camera_component| {
        var next_camera = camera_component;
        next_camera.projection = .{ .perspective = .{} };
        camera_entity.camera = next_camera;
    }

    camera_entity.local_transform = editorCameraTransform(state);
    layer_context.world.markDirty(camera_id);
    _ = layer_context.world.setPrimaryCamera(camera_id);
    state.editor_camera_active = true;
}

pub fn editorCameraTransform(state: *const EditorState) engine.scene.Transform {
    return .{
        .translation = vec3.sub(state.focus_pivot, vec3.scale(vec3.forwardFromAngles(state.yaw, state.pitch), state.orbit_distance)),
        .rotation = quat.fromEuler(.{ state.pitch, state.yaw, 0.0 }),
    };
}

fn controlledCameraEntity(state: *EditorState, layer_context: *engine.core.LayerContext) ?engine.scene.EntityId {
    if (state.editor_camera_active) {
        return state.editor_camera;
    }
    return resolveSceneCameraEntity(state, layer_context, layer_context.world.primaryCameraEntity());
}

pub fn activeCameraTransform(state: *const EditorState, layer_context: *engine.core.LayerContext) engine.scene.Transform {
    const active_camera_id = if (state.editor_camera_active) state.editor_camera else layer_context.world.primaryCameraEntity();
    if (active_camera_id) |camera_id| {
        if (layer_context.world.worldTransform(camera_id)) |camera_transform| {
            return camera_transform;
        }
    }
    return .{
        .translation = .{ 0.0, 2.0, 6.0 },
    };
}

pub fn activeCameraComponent(state: *const EditorState, layer_context: *engine.core.LayerContext) engine.scene.Camera {
    const active_camera_id = if (state.editor_camera_active) state.editor_camera else layer_context.world.primaryCameraEntity();
    if (active_camera_id) |camera_id| {
        if (layer_context.world.getEntityConst(camera_id)) |entity| {
            if (entity.camera) |camera_component| {
                return camera_component;
            }
        }
    }
    return .{};
}

pub fn activeCameraRayFromViewportPixel(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    pixel: [2]u32,
    viewport_size: [2]u32,
) ?engine.scene.Ray {
    if (viewport_size[0] == 0 or viewport_size[1] == 0) {
        return null;
    }

    const camera_transform = activeCameraTransform(state, layer_context);
    const camera_component = activeCameraComponent(state, layer_context);
    const ndc_x = ((@as(f32, @floatFromInt(pixel[0])) + 0.5) / @as(f32, @floatFromInt(viewport_size[0]))) * 2.0 - 1.0;
    const ndc_y = 1.0 - ((@as(f32, @floatFromInt(pixel[1])) + 0.5) / @as(f32, @floatFromInt(viewport_size[1]))) * 2.0;
    const aspect = @as(f32, @floatFromInt(viewport_size[0])) / @as(f32, @floatFromInt(viewport_size[1]));

    return switch (camera_component.projection) {
        .perspective => |projection| blk: {
            const tan_half_fov = @tan(projection.fov_y_radians * 0.5);
            const local_direction = normalize(.{
                ndc_x * tan_half_fov * aspect,
                ndc_y * tan_half_fov,
                -1.0,
            });
            break :blk .{
                .origin = camera_transform.translation,
                .direction = normalize(quat.rotateVec3(camera_transform.rotation, local_direction)),
            };
        },
        .orthographic => |projection| blk: {
            const half_height = projection.size * 0.5;
            const half_width = half_height * aspect;
            const local_origin = .{
                ndc_x * half_width,
                ndc_y * half_height,
                0.0,
            };
            break :blk .{
                .origin = vec3.add(camera_transform.translation, quat.rotateVec3(camera_transform.rotation, local_origin)),
                .direction = normalize(quat.rotateVec3(camera_transform.rotation, .{ 0.0, 0.0, -1.0 })),
            };
        },
    };
}

pub fn activeCameraViewMatrix(state: *const EditorState, layer_context: *engine.core.LayerContext) [16]f32 {
    return mat4.viewMatrix(activeCameraTransform(state, layer_context));
}

pub fn activeCameraIsOrthographic(state: *const EditorState, layer_context: *engine.core.LayerContext) bool {
    const active_camera_id = if (state.editor_camera_active) state.editor_camera else layer_context.world.primaryCameraEntity();
    if (active_camera_id) |camera_id| {
        if (layer_context.world.getEntityConst(camera_id)) |entity| {
            if (entity.camera) |camera_component| {
                return switch (camera_component.projection) {
                    .orthographic => true,
                    else => false,
                };
            }
        }
    }
    return false;
}

pub fn moveSpeed(state: *const EditorState, delta_seconds: f32) f32 {
    return state.move_speed * @max(delta_seconds, 0.001);
}

fn applyEditorViewDirection(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    forward: [3]f32,
    orthographic: bool,
) void {
    const camera_id = state.editor_camera orelse return;
    const camera_entity = layer_context.world.getEntity(camera_id) orelse return;

    state.pitch = utils.clampPitch(std.math.asin(std.math.clamp(forward[1], -1.0, 1.0)));
    state.yaw = std.math.atan2(-forward[0], -forward[2]);
    camera_entity.local_transform = editorCameraTransform(state);
    layer_context.world.markDirty(camera_id);
    if (camera_entity.camera) |camera_component| {
        var next_camera = camera_component;
        next_camera.projection = if (orthographic)
            .{ .orthographic = .{ .size = @max(state.orbit_distance * 1.1, 2.0), .near_clip = -1000.0, .far_clip = 1000.0 } }
        else
            .{ .perspective = .{} };
        camera_entity.camera = next_camera;
    }
    _ = layer_context.world.setPrimaryCamera(camera_id);
    state.editor_camera_active = true;
}

fn syncOrbitStateFromEntity(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    camera_id: engine.scene.EntityId,
) void {
    const camera_transform = layer_context.world.worldTransform(camera_id) orelse return;
    const forward = normalize(quat.rotateVec3(camera_transform.rotation, .{ 0.0, 0.0, -1.0 }));
    state.pitch = utils.clampPitch(std.math.asin(std.math.clamp(forward[1], -1.0, 1.0)));
    state.yaw = std.math.atan2(-forward[0], -forward[2]);

    var orbit_distance = if (state.orbit_distance > 0.01) state.orbit_distance else 5.0;
    if (layer_context.world.getEntityConst(camera_id)) |entity| {
        if (entity.camera) |camera_component| {
            orbit_distance = switch (camera_component.projection) {
                .orthographic => |projection| @max(projection.size * 0.9, 2.0),
                .perspective => @max(orbit_distance, 4.0),
            };
        }
    }

    state.orbit_distance = utils.clampDistance(orbit_distance);
    state.focus_pivot = vec3.add(camera_transform.translation, vec3.scale(forward, state.orbit_distance));
    state.viewport_view_preset = .custom;
}

fn resolveSceneCameraEntity(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    preferred_camera_id: ?engine.scene.EntityId,
) ?engine.scene.EntityId {
    if (preferred_camera_id) |camera_id| {
        if (isValidSceneCameraEntity(state, layer_context, camera_id)) {
            return camera_id;
        }
    }
    if (state.scene_camera) |camera_id| {
        if (isValidSceneCameraEntity(state, layer_context, camera_id)) {
            return camera_id;
        }
    }
    if (layer_context.world.primaryCameraEntity()) |camera_id| {
        if (isValidSceneCameraEntity(state, layer_context, camera_id)) {
            return camera_id;
        }
    }
    for (layer_context.world.entities.items) |entity| {
        if (entity.camera == null) continue;
        if (state.editor_camera != null and entity.id == state.editor_camera.?) continue;
        return entity.id;
    }
    return null;
}

fn isValidSceneCameraEntity(
    state: *const EditorState,
    layer_context: *engine.core.LayerContext,
    camera_id: engine.scene.EntityId,
) bool {
    if (!layer_context.world.hasEntity(camera_id)) return false;
    if (state.editor_camera != null and camera_id == state.editor_camera.?) return false;
    const entity = layer_context.world.getEntityConst(camera_id) orelse return false;
    return entity.camera != null;
}

fn requestViewOrientation(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    forward: [3]f32,
    orthographic: bool,
    preset: ViewPreset,
) void {
    const camera_id = state.editor_camera orelse return;
    if (!layer_context.world.hasEntity(camera_id)) {
        return;
    }

    state.view_cube_transition_start_yaw = state.yaw;
    state.view_cube_transition_start_pitch = state.pitch;
    state.view_cube_transition_target_pitch = utils.clampPitch(std.math.asin(std.math.clamp(forward[1], -1.0, 1.0)));
    state.view_cube_transition_target_yaw = std.math.atan2(-forward[0], -forward[2]);
    state.view_cube_transition_elapsed = 0.0;
    state.view_cube_transition_target_orthographic = orthographic;
    state.view_cube_transition_active = true;
    state.viewport_view_preset = preset;

    _ = layer_context.world.setPrimaryCamera(camera_id);
    state.editor_camera_active = true;
}

fn viewPresetForAxis(axis: [3]f32) ViewPreset {
    if (@abs(axis[1]) >= 0.99) {
        return .top;
    }
    if (@abs(axis[0]) >= 0.99) {
        return .side;
    }
    return .custom;
}

fn updateViewCubeTransition(state: *EditorState, layer_context: *engine.core.LayerContext) void {
    if (!state.view_cube_transition_active) {
        return;
    }

    const camera_id = state.editor_camera orelse {
        state.view_cube_transition_active = false;
        return;
    };
    const camera_entity = layer_context.world.getEntity(camera_id) orelse {
        state.view_cube_transition_active = false;
        return;
    };

    state.view_cube_transition_elapsed += @max(layer_context.delta_seconds, 0.0);
    const t = std.math.clamp(
        state.view_cube_transition_elapsed / @max(state.view_cube_transition_duration, 0.0001),
        0.0,
        1.0,
    );
    const smooth_t = t * t * (3.0 - 2.0 * t);
    state.yaw = state.view_cube_transition_start_yaw + shortestAngleDelta(state.view_cube_transition_start_yaw, state.view_cube_transition_target_yaw) * smooth_t;
    state.pitch = state.view_cube_transition_start_pitch + (state.view_cube_transition_target_pitch - state.view_cube_transition_start_pitch) * smooth_t;

    camera_entity.local_transform = editorCameraTransform(state);
    layer_context.world.markDirty(camera_id);
    if (camera_entity.camera) |camera_component| {
        var next_camera = camera_component;
        next_camera.projection = if (state.view_cube_transition_target_orthographic)
            .{ .orthographic = .{ .size = @max(state.orbit_distance * 1.1, 2.0), .near_clip = -1000.0, .far_clip = 1000.0 } }
        else
            .{ .perspective = .{} };
        camera_entity.camera = next_camera;
    }

    if (t >= 0.999) {
        state.view_cube_transition_active = false;
        state.yaw = state.view_cube_transition_target_yaw;
        state.pitch = state.view_cube_transition_target_pitch;
        camera_entity.local_transform = editorCameraTransform(state);
        layer_context.world.markDirty(camera_id);
    }
}

fn shortestAngleDelta(from: f32, to: f32) f32 {
    var delta = to - from;
    while (delta > std.math.pi) {
        delta -= std.math.tau;
    }
    while (delta < -std.math.pi) {
        delta += std.math.tau;
    }
    return delta;
}

fn selectionFocusPivot(
    layer_context: *engine.core.LayerContext,
    entity_id: engine.scene.EntityId,
    fallback: [3]f32,
) [3]f32 {
    const bounds = layer_context.world.worldBounds(entity_id) orelse return fallback;
    if (!bounds.isValid()) {
        return fallback;
    }
    return .{
        (bounds.min[0] + bounds.max[0]) * 0.5,
        (bounds.min[1] + bounds.max[1]) * 0.5,
        (bounds.min[2] + bounds.max[2]) * 0.5,
    };
}

fn selectionFocusRadius(layer_context: *engine.core.LayerContext, entity_id: engine.scene.EntityId) f32 {
    const bounds = layer_context.world.worldBounds(entity_id) orelse return 0.75;
    if (!bounds.isValid()) {
        return 0.75;
    }

    const extent = vec3.sub(bounds.max, bounds.min);
    const radius = vec3.length(extent) * 0.5;
    return @max(radius, 0.75);
}

fn focusDistanceForPerspective(radius: f32, vertical_fov_radians: f32, aspect: f32, near_clip: f32) f32 {
    const padded_radius = @max(radius, 0.01) * 1.25;
    const half_vertical_fov = @max(vertical_fov_radians * 0.5, 0.001);
    const half_horizontal_fov = @max(std.math.atan(std.math.tan(half_vertical_fov) * @max(aspect, 0.1)), 0.001);
    const limiting_half_fov = @min(half_vertical_fov, half_horizontal_fov);
    const distance = padded_radius / @max(std.math.tan(limiting_half_fov), 0.001);
    return utils.clampDistance(@max(distance, near_clip + padded_radius));
}

fn focusOrthoSize(radius: f32) f32 {
    return @max(radius * 2.5, 2.0);
}

fn normalize(vector: [3]f32) [3]f32 {
    const len = vec3.length(vector);
    if (len <= 0.0001) {
        return .{ 0.0, 0.0, -1.0 };
    }
    return .{
        vector[0] / len,
        vector[1] / len,
        vector[2] / len,
    };
}

fn panSpeedFactors(viewport_extent: [2]f32) [2]f32 {
    const width_k = @min(viewport_extent[0] / 1000.0, 2.4);
    const height_k = @min(viewport_extent[1] / 1000.0, 2.4);

    const x_factor = 0.0366 * (width_k * width_k) - 0.1778 * width_k + 0.3021;
    const y_factor = 0.0366 * (height_k * height_k) - 0.1778 * height_k + 0.3021;
    return .{ x_factor, y_factor };
}

fn zoomSpeed(distance: f32) f32 {
    const scaled = @max(distance * 0.2, 0.0);
    return @min(scaled * scaled, 100.0);
}

fn wheelZoomRatio(wheel_delta: f32, wheel_speed: f32) f32 {
    const scaled_delta = std.math.clamp(wheel_delta * wheel_speed, -4.0, 4.0);
    return @exp(-scaled_delta * 0.16);
}

fn clampOrthographicSize(size: f32) f32 {
    return std.math.clamp(size, 0.25, 500.0);
}

fn wheelPanDistance(camera_component: ?engine.scene.Camera, viewport_extent: [2]f32, orbit_distance: f32) f32 {
    const aspect = viewportAspect(viewport_extent);
    const visible_width = if (camera_component) |camera|
        switch (camera.projection) {
            .perspective => |projection| 2.0 * @tan(projection.fov_y_radians * 0.5) * @max(orbit_distance, 0.01) * aspect,
            .orthographic => |projection| @max(projection.size * aspect, 0.01),
        }
    else
        2.0 * @tan(1.0471976 * 0.5) * @max(orbit_distance, 0.01) * aspect;

    return std.math.clamp(visible_width * 0.08, 0.02, 8.0);
}

fn viewportAspect(viewport_extent: [2]f32) f32 {
    return @max(viewport_extent[0], 1.0) / @max(viewport_extent[1], 1.0);
}

test "focus distance grows with bounding radius" {
    const small = focusDistanceForPerspective(1.0, 1.0471976, 16.0 / 9.0, 0.1);
    const large = focusDistanceForPerspective(4.0, 1.0471976, 16.0 / 9.0, 0.1);

    try std.testing.expect(large > small);
}

test "orthographic focus size keeps a sensible minimum" {
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), focusOrthoSize(0.1), 0.0001);
    try std.testing.expect(focusOrthoSize(2.0) > 2.0);
}

test "wheel zoom ratio shrinks when scrolling in and grows when scrolling out" {
    const zoom_in_ratio = wheelZoomRatio(1.0, 1.2);
    const zoom_out_ratio = wheelZoomRatio(-1.0, 1.2);

    try std.testing.expect(zoom_in_ratio < 1.0);
    try std.testing.expect(zoom_out_ratio > 1.0);
}

test "wheel pan distance grows with visible width" {
    const near_distance = wheelPanDistance(.{ .projection = .{ .perspective = .{} } }, .{ 1600.0, 900.0 }, 3.0);
    const far_distance = wheelPanDistance(.{ .projection = .{ .perspective = .{} } }, .{ 1600.0, 900.0 }, 12.0);

    try std.testing.expect(far_distance > near_distance);
}
