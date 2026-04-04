///! handlers/physics_viz.zig — physics debug visualization settings.
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

const DrawMode = enum { off, selection_only, all };

// Static settings (no EditorState in RPC context)
var draw_mode: DrawMode = .off;
var opacity: f32 = 0.8;
var velocity_scale: f32 = 1.0;
var wireframe_only: bool = true;
var show_collision_shapes: bool = true;
var show_rigidbodies: bool = true;
var show_triggers: bool = true;
var show_constraints: bool = false;
var show_velocity_vectors: bool = false;
var show_sleep_state: bool = false;
var show_aabbs: bool = false;
var color_static: [4]f32 = .{ 0.0, 0.8, 0.0, 0.8 };
var color_dynamic: [4]f32 = .{ 0.0, 0.4, 1.0, 0.8 };
var color_kinematic: [4]f32 = .{ 1.0, 0.5, 0.0, 0.8 };
var color_trigger: [4]f32 = .{ 1.0, 1.0, 0.0, 0.5 };
var color_sleeping: [4]f32 = .{ 0.5, 0.5, 0.5, 0.5 };
var color_constraint: [4]f32 = .{ 1.0, 0.0, 1.0, 0.8 };

pub fn getSettings(ctx: *Ctx) !void {
    try ctx.reply(.{
        .drawMode = @tagName(draw_mode),
        .opacity = opacity,
        .velocityScale = velocity_scale,
        .wireframeOnly = wireframe_only,
        .showCollisionShapes = show_collision_shapes,
        .showRigidbodies = show_rigidbodies,
        .showTriggers = show_triggers,
        .showConstraints = show_constraints,
        .showVelocityVectors = show_velocity_vectors,
        .showSleepState = show_sleep_state,
        .showAabbs = show_aabbs,
        .colorStatic = &color_static,
        .colorDynamic = &color_dynamic,
        .colorKinematic = &color_kinematic,
        .colorTrigger = &color_trigger,
        .colorSleeping = &color_sleeping,
        .colorConstraint = &color_constraint,
    });
}

pub fn setDrawMode(ctx: *Ctx) !void {
    const mode_str = try ctx.param([]const u8, "mode");
    if (strEql(mode_str, "off")) {
        draw_mode = .off;
    } else if (strEql(mode_str, "selection_only")) {
        draw_mode = .selection_only;
    } else if (strEql(mode_str, "all")) {
        draw_mode = .all;
    } else return error.InvalidArguments;
    try ctx.reply(.{});
}

pub fn setToggle(ctx: *Ctx) !void {
    const key = try ctx.param([]const u8, "key");
    const val = try ctx.param(bool, "value");
    if (strEql(key, "wireframeOnly")) {
        wireframe_only = val;
    } else if (strEql(key, "showCollisionShapes")) {
        show_collision_shapes = val;
    } else if (strEql(key, "showRigidbodies")) {
        show_rigidbodies = val;
    } else if (strEql(key, "showTriggers")) {
        show_triggers = val;
    } else if (strEql(key, "showConstraints")) {
        show_constraints = val;
    } else if (strEql(key, "showVelocityVectors")) {
        show_velocity_vectors = val;
    } else if (strEql(key, "showSleepState")) {
        show_sleep_state = val;
    } else if (strEql(key, "showAabbs")) {
        show_aabbs = val;
    } else return error.InvalidArguments;
    try ctx.reply(.{});
}

pub fn setFloat(ctx: *Ctx) !void {
    const key = try ctx.param([]const u8, "key");
    const val = try ctx.param(f32, "value");
    if (strEql(key, "opacity")) {
        opacity = @max(0.0, @min(1.0, val));
    } else if (strEql(key, "velocityScale")) {
        velocity_scale = @max(0.1, @min(10.0, val));
    } else return error.InvalidArguments;
    try ctx.reply(.{});
}

pub fn setColor(ctx: *Ctx) !void {
    const key = try ctx.param([]const u8, "key");
    const r = try ctx.param(f32, "r");
    const g = try ctx.param(f32, "g");
    const b = try ctx.param(f32, "b");
    const a = try ctx.param(f32, "a");
    const c = [4]f32{ r, g, b, a };
    if (strEql(key, "static")) {
        color_static = c;
    } else if (strEql(key, "dynamic")) {
        color_dynamic = c;
    } else if (strEql(key, "kinematic")) {
        color_kinematic = c;
    } else if (strEql(key, "trigger")) {
        color_trigger = c;
    } else if (strEql(key, "sleeping")) {
        color_sleeping = c;
    } else if (strEql(key, "constraint")) {
        color_constraint = c;
    } else return error.InvalidArguments;
    try ctx.reply(.{});
}

fn strEql(a: []const u8, b: []const u8) bool {
    return @import("std").mem.eql(u8, a, b);
}
