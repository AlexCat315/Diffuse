///! handlers/camera.zig — camera bookmark management.
///!
///! In editor-server mode, the camera is a world entity (MainCamera).
///! Bookmarks save/restore the camera entity's transform (translation + rotation).
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;
const EditorSettings = @import("../settings.zig").EditorSettings;
const Bookmark = EditorSettings.Bookmark;

// ── RPC handlers ────────────────────────────────────────────────

pub fn listBookmarks(ctx: *Ctx) !void {
    const cam = &ctx.settings.camera;
    const Info = struct {
        index: u64,
        name: []const u8,
        position: struct { x: f32, y: f32, z: f32 },
        rotation: struct { x: f32, y: f32, z: f32, w: f32 },
        fov: f32,
    };

    var list = std.ArrayList(Info).empty;
    defer list.deinit(ctx.allocator);

    for (cam.bookmark_buf[0..cam.bookmark_len], 0..) |*b, i| {
        try list.append(ctx.allocator, .{
            .index = @intCast(i),
            .name = b.getName(),
            .position = .{ .x = b.translation[0], .y = b.translation[1], .z = b.translation[2] },
            .rotation = .{ .x = b.rotation[0], .y = b.rotation[1], .z = b.rotation[2], .w = b.rotation[3] },
            .fov = b.fov,
        });
    }

    try ctx.reply(.{ .bookmarks = list.items });
}

pub fn addBookmark(ctx: *Ctx) !void {
    const cam = &ctx.settings.camera;
    if (cam.bookmark_len >= EditorSettings.CameraState.max_bookmarks) return error.OutOfMemory;
    const name = (try ctx.paramOpt([]const u8, "name")) orelse "Bookmark";

    // Get current camera transform from the world
    const world = ctx.layer.world;
    const camera_id = world.primaryCameraEntity() orelse return error.NotAvailable;
    const camera_entity = world.getEntityConst(camera_id) orelse return error.NotAvailable;
    const transform = if (world.worldTransformConst(camera_id)) |wt| wt else camera_entity.local_transform;

    const fov: f32 = if (camera_entity.camera) |c| switch (c.projection) {
        .perspective => |p| p.fov_y_radians,
        else => 1.0471976,
    } else 1.0471976;

    var b = Bookmark{
        .translation = transform.translation,
        .rotation = transform.rotation,
        .fov = fov,
    };
    b.name_len = @min(name.len, 63);
    @memcpy(b.name[0..b.name_len], name[0..b.name_len]);

    cam.bookmark_buf[cam.bookmark_len] = b;
    cam.bookmark_len += 1;
    try ctx.reply(.{ .index = @as(u64, @intCast(cam.bookmark_len - 1)) });
}

pub fn removeBookmark(ctx: *Ctx) !void {
    const cam = &ctx.settings.camera;
    const idx_raw = try ctx.param(u64, "index");
    const idx: usize = @intCast(idx_raw);
    if (idx >= cam.bookmark_len) return error.InvalidArguments;
    // Shift elements down
    if (idx + 1 < cam.bookmark_len) {
        std.mem.copyForwards(Bookmark, cam.bookmark_buf[idx .. cam.bookmark_len - 1], cam.bookmark_buf[idx + 1 .. cam.bookmark_len]);
    }
    cam.bookmark_len -= 1;
    try ctx.reply(.{});
}

pub fn applyBookmark(ctx: *Ctx) !void {
    const cam = &ctx.settings.camera;
    const idx_raw = try ctx.param(u64, "index");
    const idx: usize = @intCast(idx_raw);
    if (idx >= cam.bookmark_len) return error.InvalidArguments;
    const b = &cam.bookmark_buf[idx];

    const world = ctx.layer.world;
    const camera_id = world.primaryCameraEntity() orelse return error.NotAvailable;
    var camera_entity = world.getEntity(camera_id) orelse return error.NotAvailable;

    camera_entity.local_transform.translation = b.translation;
    camera_entity.local_transform.rotation = b.rotation;

    try ctx.reply(.{});
}

pub fn renameBookmark(ctx: *Ctx) !void {
    const cam = &ctx.settings.camera;
    const idx_raw = try ctx.param(u64, "index");
    const name = try ctx.param([]const u8, "name");
    const idx: usize = @intCast(idx_raw);
    if (idx >= cam.bookmark_len) return error.InvalidArguments;
    var b = &cam.bookmark_buf[idx];
    b.name_len = @min(name.len, 63);
    @memset(&b.name, 0);
    @memcpy(b.name[0..b.name_len], name[0..b.name_len]);
    try ctx.reply(.{});
}

/// Return the current camera transform (position + rotation quaternion).
pub fn getState(ctx: *Ctx) !void {
    const world = ctx.layer.world;
    const camera_id = world.primaryCameraEntity() orelse return error.NotAvailable;
    const camera_entity = world.getEntityConst(camera_id) orelse return error.NotAvailable;
    const transform = if (world.worldTransformConst(camera_id)) |wt| wt else camera_entity.local_transform;

    try ctx.reply(.{
        .position = .{ .x = transform.translation[0], .y = transform.translation[1], .z = transform.translation[2] },
        .rotation = .{ .x = transform.rotation[0], .y = transform.rotation[1], .z = transform.rotation[2], .w = transform.rotation[3] },
    });
}

/// Set camera to look along a world axis (for ViewCube face clicks).
/// Uses the pending mechanism so EditorState.yaw/pitch/pivot stay in sync.
pub fn lookAlongAxis(ctx: *Ctx) !void {
    const ax: f32 = @floatCast(try ctx.param(f64, "axisX"));
    const ay: f32 = @floatCast(try ctx.param(f64, "axisY"));
    const az: f32 = @floatCast(try ctx.param(f64, "axisZ"));
    const len = @sqrt(ax * ax + ay * ay + az * az);
    ctx.layer.renderer.pending_camera_look_axis = if (len > 0.001) .{ ax / len, ay / len, az / len } else .{ 0, 0, -1 };
    try ctx.reply(.{});
}

/// Orbit camera around its focus target.
/// Uses the pending mechanism so EditorState.yaw/pitch stay in sync.
pub fn orbit(ctx: *Ctx) !void {
    const deltaYaw: f32 = @floatCast(try ctx.param(f64, "deltaYaw"));
    const deltaPitch: f32 = @floatCast(try ctx.param(f64, "deltaPitch"));
    const renderer = ctx.layer.renderer;
    if (renderer.pending_camera_orbit) |prev| {
        // Accumulate multiple orbit deltas within the same frame
        renderer.pending_camera_orbit = .{ prev[0] + deltaYaw, prev[1] + deltaPitch };
    } else {
        renderer.pending_camera_orbit = .{ deltaYaw, deltaPitch };
    }
    try ctx.reply(.{});
}

// ── Math helpers ──────────────────────────────────────────────

fn quatFromForward(fwd: [3]f32) [4]f32 {
    // Camera looks along -Z in its local space.
    // So to look along `fwd`, we need to rotate default -Z to `fwd`.
    const default_fwd: [3]f32 = .{ 0, 0, -1 };
    return quatFromTo(default_fwd, fwd);
}

fn quatFromTo(from: [3]f32, to: [3]f32) [4]f32 {
    const dot = from[0] * to[0] + from[1] * to[1] + from[2] * to[2];
    if (dot > 0.9999) return .{ 0, 0, 0, 1 };
    if (dot < -0.9999) {
        // 180 degree rotation — pick an arbitrary perpendicular axis
        var axis: [3]f32 = cross(.{ 1, 0, 0 }, from);
        var l = @sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
        if (l < 0.001) {
            axis = cross(.{ 0, 1, 0 }, from);
            l = @sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
        }
        return .{ axis[0] / l, axis[1] / l, axis[2] / l, 0 };
    }
    const c = cross(from, to);
    const w = 1.0 + dot;
    const len = @sqrt(c[0] * c[0] + c[1] * c[1] + c[2] * c[2] + w * w);
    return .{ c[0] / len, c[1] / len, c[2] / len, w / len };
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn forwardFromQuat(q: [4]f32) [3]f32 {
    // Rotate default forward (0,0,-1) by quaternion
    // Simplified from full quat * vec3 rotation
    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    return .{
        -(2.0 * (x * z + w * y)),
        -(2.0 * (y * z - w * x)),
        -(1.0 - 2.0 * (x * x + y * y)),
    };
}

fn quatFromEulerYP(yaw: f32, pitch: f32) [4]f32 {
    const cy = @cos(yaw * 0.5);
    const sy = @sin(yaw * 0.5);
    const cp = @cos(pitch * 0.5);
    const sp = @sin(pitch * 0.5);
    // Order: Y (yaw) then X (pitch), no roll
    return .{
        cy * sp, // x
        sy * cp, // y
        -sy * sp, // z
        cy * cp, // w
    };
}
