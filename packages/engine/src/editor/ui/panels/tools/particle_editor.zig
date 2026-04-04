const std = @import("std");
const engine = @import("guava");
const gui = @import("../../gui.zig");
const floating_window_blocker = @import("../../floating_window_blocker.zig");
const layout = @import("../../layout.zig");
const EditorState = @import("../../../core/state.zig").EditorState;

const Vfx = engine.scene.Vfx;
const VfxKind = engine.scene.VfxKind;

pub const ParticleEditorState = struct {
    selected_vfx_entity: ?engine.scene.EntityId = null,
    preview_vfx: ?Vfx = null,
    is_previewing: bool = false,
    preset_name_buffer: [64]u8 = [_]u8{0} ** 64,
    show_emission_curve: bool = false,
    show_color_gradient: bool = false,
    show_size_curve: bool = false,
    curve_preview_t: f32 = 0.0,
    emission_curve_start: f32 = 1.0,
    emission_curve_mid: f32 = 1.0,
    emission_curve_end: f32 = 1.0,
    size_curve_start: f32 = 1.0,
    size_curve_mid: f32 = 1.0,
    size_curve_end: f32 = 1.0,
    color_gradient_start: [3]f32 = .{ 1.0, 1.0, 1.0 },
    color_gradient_end: [3]f32 = .{ 1.0, 1.0, 1.0 },
    simulation_speed: f32 = 1.0,
    auto_reset: bool = true,
    reset_timer: f32 = 0.0,

    pub fn deinit(self: *@This()) void {
        self.* = undefined;
    }
};

pub fn drawParticleEditorWindow(
    state: *EditorState,
    layer_context: *engine.core.LayerContext,
    editor_state: *ParticleEditorState,
) !void {
    _ = layer_context;

    var title_buffer: [80]u8 = undefined;
    const title = try state.windowLabel(&title_buffer, .particle_editor, "particle_editor_panel");
    _ = gui.beginWindow(title);
    defer gui.endWindow();
    floating_window_blocker.registerCurrentWindow("particle_editor_panel");

    drawParticleToolbar(editor_state);

    gui.separator();

    if (editor_state.preview_vfx) |*vfx| {
        drawParticlePreview(editor_state);
        gui.separator();
        drawParticleParameters(vfx);
        gui.separator();
        drawParticleCurves(vfx, editor_state);
    } else {
        gui.text("Select a VFX entity or create a new particle system");
        if (gui.button("Create Particle System")) {
            editor_state.preview_vfx = engine.scene.defaultVfx(.fountain);
        }
    }
}

fn drawParticleToolbar(editor_state: *ParticleEditorState) void {
    if (gui.button("New")) {
        editor_state.preview_vfx = engine.scene.defaultVfx(.fountain);
    }
    gui.sameLine();

    if (editor_state.preview_vfx != null) {
        if (gui.button("Reset")) {
            editor_state.reset_timer = 0.0;
        }
        gui.sameLine();

        if (gui.button(if (editor_state.is_previewing) "Pause" else "Play")) {
            editor_state.is_previewing = !editor_state.is_previewing;
        }
        gui.sameLine();

        gui.text("Speed:");
        gui.sameLine();
        _ = gui.dragFloat("##sim_speed", &editor_state.simulation_speed, 0.1, 0.1, 5.0);
    }

    gui.sameLine();
    gui.text("Preset:");
    gui.sameLine();
    if (gui.beginCombo("##preset", "Select...")) {
        defer gui.endCombo();

        const presets = [_]struct { name: []const u8, kind: VfxKind }{
            .{ .name = "Fountain", .kind = .fountain },
            .{ .name = "Orbit", .kind = .orbit },
        };

        for (presets) |preset| {
            if (gui.selectable(preset.name, false, false, 0.0, 0.0)) {
                editor_state.preview_vfx = engine.scene.defaultVfx(preset.kind);
            }
        }
    }
}

fn drawParticlePreview(editor_state: *ParticleEditorState) void {
    const preview_size = gui.contentRegionAvail();
    const preview_height = @min(preview_size[1] * 0.4, 200);

    if (gui.beginChild("particle_preview", -1.0, preview_height, true)) {
        gui.text("Particle Preview");
        gui.separator();

        if (editor_state.is_previewing) {
            editor_state.reset_timer += 0.016 * editor_state.simulation_speed;
            if (editor_state.reset_timer > 5.0 and editor_state.auto_reset) {
                editor_state.reset_timer = 0.0;
            }
        }

        if (editor_state.preview_vfx) |vfx| {
            var info_buf: [256]u8 = undefined;
            const info = std.fmt.bufPrint(&info_buf, "Particles: {} | Rate: {d:.1}/s | Lifetime: {d:.2}s", .{
                vfx.max_particles,
                vfx.emission_rate,
                vfx.particle_lifetime,
            }) catch "";
            gui.text(info);
        }
    }
    gui.endChild();
}

fn drawParticleParameters(vfx: *Vfx) void {
    if (layout.beginInspectorPropertyTable("particle_params", 0.34)) {
        defer layout.endInspectorPropertyTable();

        layout.drawInspectorPropertyRow("Kind", null);
        if (gui.beginCombo("##kind", @tagName(vfx.kind))) {
            defer gui.endCombo();
            inline for (.{
                .fountain,
                .orbit,
            }) |kind| {
                const is_selected = vfx.kind == kind;
                if (gui.selectable(@tagName(kind), is_selected, false, 0, 0)) {
                    vfx.* = engine.scene.defaultVfx(kind);
                }
                if (is_selected) {
                    gui.setItemDefaultFocus();
                }
            }
        }

        layout.drawInspectorPropertyRow("Looping", null);
        _ = gui.checkbox("##looping", &vfx.looping);

        layout.drawInspectorPropertyRow("Emission Rate", null);
        _ = gui.dragFloat("##emission_rate", &vfx.emission_rate, 1.0, 1.0, 200.0);

        layout.drawInspectorPropertyRow("Particle Lifetime", null);
        _ = gui.dragFloat("##lifetime", &vfx.particle_lifetime, 0.1, 0.1, 10.0);

        layout.drawInspectorPropertyRow("Speed", null);
        _ = gui.dragFloat("##speed", &vfx.speed, 0.1, 0.1, 20.0);

        layout.drawInspectorPropertyRow("Max Particles", null);
        var max_particles_i32: i32 = @intCast(vfx.max_particles);
        if (gui.dragInt("##max_particles", &max_particles_i32, 1.0, 1, 1000)) {
            vfx.max_particles = @intCast(std.math.clamp(max_particles_i32, 1, 1000));
        }

        layout.drawInspectorPropertyRow("Radius", null);
        _ = gui.dragFloat("##radius", &vfx.radius, 0.05, 0.0, 5.0);

        layout.drawInspectorPropertyRow("Spread", null);
        _ = gui.dragFloat("##spread", &vfx.spread, 0.05, 0.0, 3.14159);

        layout.drawInspectorPropertyRow("Size", null);
        _ = gui.dragFloat("##size", &vfx.size, 0.01, 0.01, 2.0);

        layout.drawInspectorPropertyRow("Color", null);
        _ = gui.colorEdit3("##color", &vfx.color, .{});
    }
}

fn drawParticleCurves(vfx: *Vfx, editor_state: *ParticleEditorState) void {
    gui.text("Advanced Curves");
    gui.separator();

    _ = gui.dragFloat("Preview Lifetime T", &editor_state.curve_preview_t, 0.01, 0.0, 1.0);

    if (gui.collapsingHeader("Emission Curve", false)) {
        editor_state.show_emission_curve = true;
        _ = gui.dragFloat("Start##emission", &editor_state.emission_curve_start, 0.01, 0.0, 5.0);
        _ = gui.dragFloat("Mid##emission", &editor_state.emission_curve_mid, 0.01, 0.0, 5.0);
        _ = gui.dragFloat("End##emission", &editor_state.emission_curve_end, 0.01, 0.0, 5.0);

        const t = editor_state.curve_preview_t;
        const sampled_multiplier = if (t < 0.5)
            std.math.lerp(editor_state.emission_curve_start, editor_state.emission_curve_mid, t * 2.0)
        else
            std.math.lerp(editor_state.emission_curve_mid, editor_state.emission_curve_end, (t - 0.5) * 2.0);
        var info_buf: [128]u8 = undefined;
        const info = std.fmt.bufPrint(&info_buf, "Sampled Rate: {d:.2}/s", .{vfx.emission_rate * sampled_multiplier}) catch "";
        gui.text(info);
    }

    if (gui.collapsingHeader("Color Gradient", false)) {
        editor_state.show_color_gradient = true;
        _ = gui.colorEdit3("Start Color", &editor_state.color_gradient_start, .{});
        _ = gui.colorEdit3("End Color", &editor_state.color_gradient_end, .{});

        const t = editor_state.curve_preview_t;
        var sampled = [3]f32{
            std.math.lerp(editor_state.color_gradient_start[0], editor_state.color_gradient_end[0], t),
            std.math.lerp(editor_state.color_gradient_start[1], editor_state.color_gradient_end[1], t),
            std.math.lerp(editor_state.color_gradient_start[2], editor_state.color_gradient_end[2], t),
        };
        _ = gui.colorEdit3("Sampled##color_preview", &sampled, .{});
        if (gui.button("Apply Sampled To Base Color")) {
            vfx.color = sampled;
        }
    }

    if (gui.collapsingHeader("Size Curve", false)) {
        editor_state.show_size_curve = true;
        _ = gui.dragFloat("Start##size", &editor_state.size_curve_start, 0.01, 0.01, 5.0);
        _ = gui.dragFloat("Mid##size", &editor_state.size_curve_mid, 0.01, 0.01, 5.0);
        _ = gui.dragFloat("End##size", &editor_state.size_curve_end, 0.01, 0.01, 5.0);

        const t = editor_state.curve_preview_t;
        const sampled_multiplier = if (t < 0.5)
            std.math.lerp(editor_state.size_curve_start, editor_state.size_curve_mid, t * 2.0)
        else
            std.math.lerp(editor_state.size_curve_mid, editor_state.size_curve_end, (t - 0.5) * 2.0);
        var size_buf: [128]u8 = undefined;
        const sampled_size = @max(vfx.size * sampled_multiplier, 0.01);
        const size_text = std.fmt.bufPrint(&size_buf, "Sampled Size: {d:.3}", .{sampled_size}) catch "";
        gui.text(size_text);
        if (gui.button("Apply Sampled To Base Size")) {
            vfx.size = sampled_size;
        }
    }
}
