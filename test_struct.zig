const std = @import("std");

const JoltBodyDesc = extern struct {
    entity_id: u64,
    motion_type: u32,
    flags: u32,
    mass: f32,
    gravity_scale: f32,
    linear_damping: f32,
    max_linear_speed: f32,
    position: [3]f32,
    rotation: [4]f32,
    linear_velocity: [3]f32,
    box_half_extents: [3]f32,
    box_center: [3]f32,
    sphere_radius: f32,
    sphere_center: [3]f32,
    mesh_half_extents: [3]f32,
    mesh_center: [3]f32,
    layer_id: u32,
    layer_group: u32,
};

pub fn main() !void {
    std.debug.print("Size: {d}\n", .{@sizeOf(JoltBodyDesc)});
    std.debug.print("Offset of linear_velocity: {d}\n", .{@offsetOf(JoltBodyDesc, "linear_velocity")});
    std.debug.print("Offset of position: {d}\n", .{@offsetOf(JoltBodyDesc, "position")});
}
