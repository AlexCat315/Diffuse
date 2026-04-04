const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const layout = @import("../../layout.zig");
const props = @import("../../properties.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

pub const PhysicsVisualizationSettings = struct {
    show_collision_shapes: bool = true,
    show_rigidbodies: bool = true,
    show_triggers: bool = true,
    show_constraints: bool = false,
    show_velocity_vectors: bool = false,
    show_sleep_state: bool = false,
    show_aabbs: bool = false,
    wireframe_only: bool = true,
    opacity: f32 = 0.8,
    velocity_scale: f32 = 1.0,
    color_static: [4]f32 = .{ 0.0, 0.8, 0.0, 0.8 },
    color_dynamic: [4]f32 = .{ 0.0, 0.4, 1.0, 0.8 },
    color_kinematic: [4]f32 = .{ 1.0, 0.5, 0.0, 0.8 },
    color_trigger: [4]f32 = .{ 1.0, 1.0, 0.0, 0.5 },
    color_sleeping: [4]f32 = .{ 0.5, 0.5, 0.5, 0.5 },
    color_constraint: [4]f32 = .{ 1.0, 0.0, 1.0, 0.8 },
};

pub const PhysicsDebugDrawMode = enum {
    off,
    selection_only,
    all,
};

pub fn drawPhysicsVisualizationWindow(state: *EditorState, settings: *PhysicsVisualizationSettings, mode: *PhysicsDebugDrawMode) !void {
    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .physics_visualization, "physics_viz_panel");
    _ = gui.beginWindow(title);
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("physics_viz_panel");

    if (props.beginPropertyGrid("physics_viz_settings")) {
        defer props.endPropertyGrid();

        if (props.combo("Draw Mode", modeName(mode.*))) {
            defer gui.endCombo();
            const modes = [_]PhysicsDebugDrawMode{ .off, .selection_only, .all };
            for (modes) |m| {
                const is_selected = mode.* == m;
                if (gui.selectable(modeName(m), is_selected, false, 0, 0)) {
                    mode.* = m;
                }
                if (is_selected) {
                    gui.setItemDefaultFocus();
                }
            }
        }

        if (mode.* != .off) {
            _ = props.float("Opacity", &settings.opacity, 0.01, 0.1, 1.0);
            _ = props.boolean("Wireframe", &settings.wireframe_only);

            gui.separator();
            gui.text("Show:");
            gui.separator();

            _ = props.boolean("Collision Shapes", &settings.show_collision_shapes);
            _ = props.boolean("Rigidbodies", &settings.show_rigidbodies);
            _ = props.boolean("Triggers", &settings.show_triggers);
            _ = props.boolean("Constraints", &settings.show_constraints);
            _ = props.boolean("Velocity Vectors", &settings.show_velocity_vectors);

            if (settings.show_velocity_vectors) {
                _ = props.float("Velocity Scale", &settings.velocity_scale, 0.1, 0.1, 10.0);
            }

            _ = props.boolean("Sleep State", &settings.show_sleep_state);
            _ = props.boolean("AABBs", &settings.show_aabbs);

            gui.separator();
            gui.text("Colors:");
            gui.separator();

            _ = props.color4("Static", &settings.color_static, .{});
            _ = props.color4("Dynamic", &settings.color_dynamic, .{});
            _ = props.color4("Kinematic", &settings.color_kinematic, .{});
            _ = props.color4("Trigger", &settings.color_trigger, .{});
            _ = props.color4("Sleeping", &settings.color_sleeping, .{});
            _ = props.color4("Constraint", &settings.color_constraint, .{});
        }
    }
}

fn modeName(mode: PhysicsDebugDrawMode) []const u8 {
    return switch (mode) {
        .off => "Off",
        .selection_only => "Selection Only",
        .all => "All",
    };
}
