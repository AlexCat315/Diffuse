///! handlers/physics_viz.zig — physics debug visualization settings.
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

pub fn getSettings(ctx: *Ctx) !void {
    const pv = &ctx.settings.physics_viz;
    try ctx.reply(.{
        .drawMode = @tagName(pv.draw_mode),
        .opacity = pv.opacity,
        .velocityScale = pv.velocity_scale,
        .wireframeOnly = pv.wireframe_only,
        .showCollisionShapes = pv.show_collision_shapes,
        .showRigidbodies = pv.show_rigidbodies,
        .showTriggers = pv.show_triggers,
        .showConstraints = pv.show_constraints,
        .showVelocityVectors = pv.show_velocity_vectors,
        .showSleepState = pv.show_sleep_state,
        .showAabbs = pv.show_aabbs,
        .colorStatic = &pv.color_static,
        .colorDynamic = &pv.color_dynamic,
        .colorKinematic = &pv.color_kinematic,
        .colorTrigger = &pv.color_trigger,
        .colorSleeping = &pv.color_sleeping,
        .colorConstraint = &pv.color_constraint,
    });
}

pub fn setDrawMode(ctx: *Ctx) !void {
    const mode_str = try ctx.param([]const u8, "mode");
    const pv = &ctx.settings.physics_viz;
    if (strEql(mode_str, "off")) {
        pv.draw_mode = .off;
    } else if (strEql(mode_str, "selection_only")) {
        pv.draw_mode = .selection_only;
    } else if (strEql(mode_str, "all")) {
        pv.draw_mode = .all;
    } else return error.InvalidArguments;
    ctx.layer.renderer.needs_redraw = true;
    try ctx.reply(.{});
}

pub fn setToggle(ctx: *Ctx) !void {
    const key = try ctx.param([]const u8, "key");
    const val = try ctx.param(bool, "value");
    const pv = &ctx.settings.physics_viz;
    if (strEql(key, "wireframeOnly")) {
        pv.wireframe_only = val;
    } else if (strEql(key, "showCollisionShapes")) {
        pv.show_collision_shapes = val;
    } else if (strEql(key, "showRigidbodies")) {
        pv.show_rigidbodies = val;
    } else if (strEql(key, "showTriggers")) {
        pv.show_triggers = val;
    } else if (strEql(key, "showConstraints")) {
        pv.show_constraints = val;
    } else if (strEql(key, "showVelocityVectors")) {
        pv.show_velocity_vectors = val;
    } else if (strEql(key, "showSleepState")) {
        pv.show_sleep_state = val;
    } else if (strEql(key, "showAabbs")) {
        pv.show_aabbs = val;
    } else return error.InvalidArguments;
    ctx.layer.renderer.needs_redraw = true;
    try ctx.reply(.{});
}

pub fn setFloat(ctx: *Ctx) !void {
    const key = try ctx.param([]const u8, "key");
    const val = try ctx.param(f32, "value");
    const pv = &ctx.settings.physics_viz;
    if (strEql(key, "opacity")) {
        pv.opacity = @max(0.0, @min(1.0, val));
    } else if (strEql(key, "velocityScale")) {
        pv.velocity_scale = @max(0.1, @min(10.0, val));
    } else return error.InvalidArguments;
    ctx.layer.renderer.needs_redraw = true;
    try ctx.reply(.{});
}

pub fn setColor(ctx: *Ctx) !void {
    const key = try ctx.param([]const u8, "key");
    const r = try ctx.param(f32, "r");
    const g = try ctx.param(f32, "g");
    const b = try ctx.param(f32, "b");
    const a = try ctx.param(f32, "a");
    const c = [4]f32{ r, g, b, a };
    const pv = &ctx.settings.physics_viz;
    if (strEql(key, "static")) {
        pv.color_static = c;
    } else if (strEql(key, "dynamic")) {
        pv.color_dynamic = c;
    } else if (strEql(key, "kinematic")) {
        pv.color_kinematic = c;
    } else if (strEql(key, "trigger")) {
        pv.color_trigger = c;
    } else if (strEql(key, "sleeping")) {
        pv.color_sleeping = c;
    } else if (strEql(key, "constraint")) {
        pv.color_constraint = c;
    } else return error.InvalidArguments;
    ctx.layer.renderer.needs_redraw = true;
    try ctx.reply(.{});
}

fn strEql(a: []const u8, b: []const u8) bool {
    return @import("std").mem.eql(u8, a, b);
}
