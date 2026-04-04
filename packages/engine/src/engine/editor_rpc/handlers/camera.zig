///! handlers/camera.zig — camera bookmark management.
///!
///! In editor-server mode, the camera is a world entity (MainCamera).
///! Bookmarks save/restore the camera entity's transform (translation + rotation).
const std = @import("std");
const ctx_mod = @import("../ctx.zig");
const Ctx = ctx_mod.Ctx;

// ── Bookmark storage (process-lifetime, shared across RPC calls) ────

const Bookmark = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    translation: [3]f32 = .{ 0, 0, 0 },
    rotation: [4]f32 = .{ 0, 0, 0, 1 }, // quaternion xyzw
    fov: f32 = 1.0471976, // ~60 degrees in radians

    fn getName(self: *const Bookmark) []const u8 {
        return self.name[0..self.name_len];
    }
};

const max_bookmarks = 64;
var bookmark_buf: [max_bookmarks]Bookmark = undefined;
var bookmark_len: usize = 0;

// ── RPC handlers ────────────────────────────────────────────────

pub fn listBookmarks(ctx: *Ctx) !void {
    const Info = struct {
        index: u64,
        name: []const u8,
        position: struct { x: f32, y: f32, z: f32 },
        rotation: struct { x: f32, y: f32, z: f32, w: f32 },
        fov: f32,
    };

    var list = std.ArrayList(Info).empty;
    defer list.deinit(ctx.allocator);

    for (bookmark_buf[0..bookmark_len], 0..) |*b, i| {
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
    if (bookmark_len >= max_bookmarks) return error.OutOfMemory;
    const name = (try ctx.paramOpt([]const u8, "name")) orelse "Bookmark";

    // Get current camera transform from the world
    const world = ctx.layer.world;
    const camera_id = world.primaryCameraEntity() orelse return error.NotAvailable;
    const camera_entity = world.getEntityConst(camera_id) orelse return error.NotAvailable;
    const transform = if (world.worldTransformConst(camera_id)) |wt| wt else camera_entity.local_transform;

    const fov: f32 = if (camera_entity.camera) |cam| switch (cam.projection) {
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

    bookmark_buf[bookmark_len] = b;
    bookmark_len += 1;
    try ctx.reply(.{ .index = @as(u64, @intCast(bookmark_len - 1)) });
}

pub fn removeBookmark(ctx: *Ctx) !void {
    const idx_raw = try ctx.param(u64, "index");
    const idx: usize = @intCast(idx_raw);
    if (idx >= bookmark_len) return error.InvalidArguments;
    // Shift elements down
    if (idx + 1 < bookmark_len) {
        std.mem.copyForwards(Bookmark, bookmark_buf[idx .. bookmark_len - 1], bookmark_buf[idx + 1 .. bookmark_len]);
    }
    bookmark_len -= 1;
    try ctx.reply(.{});
}

pub fn applyBookmark(ctx: *Ctx) !void {
    const idx_raw = try ctx.param(u64, "index");
    const idx: usize = @intCast(idx_raw);
    if (idx >= bookmark_len) return error.InvalidArguments;
    const b = &bookmark_buf[idx];

    const world = ctx.layer.world;
    const camera_id = world.primaryCameraEntity() orelse return error.NotAvailable;
    var camera_entity = world.getEntity(camera_id) orelse return error.NotAvailable;

    camera_entity.local_transform.translation = b.translation;
    camera_entity.local_transform.rotation = b.rotation;

    try ctx.reply(.{});
}

pub fn renameBookmark(ctx: *Ctx) !void {
    const idx_raw = try ctx.param(u64, "index");
    const name = try ctx.param([]const u8, "name");
    const idx: usize = @intCast(idx_raw);
    if (idx >= bookmark_len) return error.InvalidArguments;
    var b = &bookmark_buf[idx];
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
/// axis: [3]f32 direction vector; the camera moves to focus_distance along -axis.
pub fn lookAlongAxis(ctx: *Ctx) !void {
    const ax = try ctx.param(f64, "axisX");
    const ay = try ctx.param(f64, "axisY");
    const az = try ctx.param(f64, "axisZ");

    const world = ctx.layer.world;
    const camera_id = world.primaryCameraEntity() orelse return error.NotAvailable;
    var camera_entity = world.getEntity(camera_id) orelse return error.NotAvailable;

    // Get current camera position to compute focus distance
    const cur = camera_entity.local_transform.translation;
    // Focus target: assume we're orbiting around a point `distance` units ahead
    const distance_f64: f64 = (try ctx.paramOpt(f64, "distance")) orelse blk: {
        // Default: keep current distance from origin projected onto look direction
        const d = @sqrt(cur[0] * cur[0] + cur[1] * cur[1] + cur[2] * cur[2]);
        break :blk if (d > 0.5) @as(f64, d) else 3.0;
    };
    const dist_f: f32 = @floatCast(distance_f64);

    // Target point (focus pivot) — optionally provided, otherwise (0,0,0)
    const tx: f32 = @floatCast((try ctx.paramOpt(f64, "targetX")) orelse 0);
    const ty: f32 = @floatCast((try ctx.paramOpt(f64, "targetY")) orelse 0);
    const tz: f32 = @floatCast((try ctx.paramOpt(f64, "targetZ")) orelse 0);

    // Camera position = target - axis * distance
    const axis: [3]f32 = .{
        @floatCast(ax),
        @floatCast(ay),
        @floatCast(az),
    };
    const len = @sqrt(axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2]);
    const norm: [3]f32 = if (len > 0.001) .{ axis[0] / len, axis[1] / len, axis[2] / len } else .{ 0, 0, -1 };

    camera_entity.local_transform.translation = .{
        tx - norm[0] * dist_f,
        ty - norm[1] * dist_f,
        tz - norm[2] * dist_f,
    };

    // Compute rotation quaternion: look from camera toward target
    // forward = norm (the direction the camera should face)
    camera_entity.local_transform.rotation = quatFromForward(norm);

    try ctx.reply(.{});
}

/// Orbit camera around its focus target.
/// deltaYaw/deltaPitch in radians.
pub fn orbit(ctx: *Ctx) !void {
    const deltaYaw: f32 = @floatCast(try ctx.param(f64, "deltaYaw"));
    const deltaPitch: f32 = @floatCast(try ctx.param(f64, "deltaPitch"));

    const world = ctx.layer.world;
    const camera_id = world.primaryCameraEntity() orelse return error.NotAvailable;
    var camera_entity = world.getEntity(camera_id) orelse return error.NotAvailable;

    const pos = camera_entity.local_transform.translation;
    const rot = camera_entity.local_transform.rotation;

    // Extract current yaw/pitch from quaternion
    var yaw = std.math.atan2(2.0 * (rot[3] * rot[1] + rot[0] * rot[2]), 1.0 - 2.0 * (rot[1] * rot[1] + rot[2] * rot[2]));
    var pitch = std.math.asin(std.math.clamp(2.0 * (rot[3] * rot[0] - rot[2] * rot[1]), -1.0, 1.0));

    // Compute focus pivot (point `distance` units ahead of camera)
    const fwd = forwardFromQuat(rot);
    const dist = @sqrt(pos[0] * pos[0] + pos[1] * pos[1] + pos[2] * pos[2]);
    const orbit_dist = if (dist > 0.5) dist else @as(f32, 3.0);
    const pivot: [3]f32 = .{
        pos[0] + fwd[0] * orbit_dist,
        pos[1] + fwd[1] * orbit_dist,
        pos[2] + fwd[2] * orbit_dist,
    };

    // Apply rotation deltas
    yaw += deltaYaw;
    pitch = std.math.clamp(pitch + deltaPitch, -std.math.pi / 2.0 + 0.01, std.math.pi / 2.0 - 0.01);

    // Recompute camera position from pivot
    const new_rot = quatFromEulerYP(yaw, pitch);
    const new_fwd = forwardFromQuat(new_rot);
    camera_entity.local_transform.translation = .{
        pivot[0] - new_fwd[0] * orbit_dist,
        pivot[1] - new_fwd[1] * orbit_dist,
        pivot[2] - new_fwd[2] * orbit_dist,
    };
    camera_entity.local_transform.rotation = new_rot;

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
