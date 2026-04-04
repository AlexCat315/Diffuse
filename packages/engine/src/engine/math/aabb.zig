const std = @import("std");
const vec3 = @import("vec3.zig");
const quat = @import("quat.zig");
const components = @import("../scene/components.zig");

pub const AABB = struct {
    min: [3]f32 = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) },
    max: [3]f32 = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) },

    pub const RayIntersection = struct {
        enter_distance: f32,
        exit_distance: f32,
    };

    pub fn empty() AABB {
        return .{};
    }

    pub fn expand(self: *AABB, point: [3]f32) void {
        self.min[0] = @min(self.min[0], point[0]);
        self.min[1] = @min(self.min[1], point[1]);
        self.min[2] = @min(self.min[2], point[2]);

        self.max[0] = @max(self.max[0], point[0]);
        self.max[1] = @max(self.max[1], point[1]);
        self.max[2] = @max(self.max[2], point[2]);
    }

    pub fn expandAABB(self: *AABB, other: AABB) void {
        self.min[0] = @min(self.min[0], other.min[0]);
        self.min[1] = @min(self.min[1], other.min[1]);
        self.min[2] = @min(self.min[2], other.min[2]);

        self.max[0] = @max(self.max[0], other.max[0]);
        self.max[1] = @max(self.max[1], other.max[1]);
        self.max[2] = @max(self.max[2], other.max[2]);
    }

    pub fn isValid(self: AABB) bool {
        return self.min[0] <= self.max[0] and self.min[1] <= self.max[1] and self.min[2] <= self.max[2];
    }

    pub fn intersects(self: AABB, other: AABB) bool {
        return self.min[0] <= other.max[0] and self.max[0] >= other.min[0] and
            self.min[1] <= other.max[1] and self.max[1] >= other.min[1] and
            self.min[2] <= other.max[2] and self.max[2] >= other.min[2];
    }

    pub fn centroid(self: AABB) [3]f32 {
        return .{
            (self.min[0] + self.max[0]) * 0.5,
            (self.min[1] + self.max[1]) * 0.5,
            (self.min[2] + self.max[2]) * 0.5,
        };
    }

    pub fn extent(self: AABB) [3]f32 {
        return .{
            self.max[0] - self.min[0],
            self.max[1] - self.min[1],
            self.max[2] - self.min[2],
        };
    }

    pub fn rayIntersection(self: AABB, origin: [3]f32, direction: [3]f32, max_distance: f32) ?RayIntersection {
        if (!self.isValid()) {
            return null;
        }

        const epsilon: f32 = 0.000001;
        var t_min: f32 = 0.0;
        var t_max: f32 = max_distance;

        var axis: usize = 0;
        while (axis < 3) : (axis += 1) {
            const axis_direction = direction[axis];
            if (@abs(axis_direction) <= epsilon) {
                if (origin[axis] < self.min[axis] or origin[axis] > self.max[axis]) {
                    return null;
                }
                continue;
            }

            const inverse_direction = 1.0 / axis_direction;
            var t1 = (self.min[axis] - origin[axis]) * inverse_direction;
            var t2 = (self.max[axis] - origin[axis]) * inverse_direction;
            if (t1 > t2) {
                std.mem.swap(f32, &t1, &t2);
            }

            t_min = @max(t_min, t1);
            t_max = @min(t_max, t2);
            if (t_max < t_min) {
                return null;
            }
        }

        return .{
            .enter_distance = t_min,
            .exit_distance = t_max,
        };
    }

    pub fn transformed(self: AABB, transform: components.Transform) AABB {
        if (!self.isValid()) return self;

        // Extract 8 corners
        const corners = [_][3]f32{
            .{ self.min[0], self.min[1], self.min[2] },
            .{ self.max[0], self.min[1], self.min[2] },
            .{ self.min[0], self.max[1], self.min[2] },
            .{ self.max[0], self.max[1], self.min[2] },
            .{ self.min[0], self.min[1], self.max[2] },
            .{ self.max[0], self.min[1], self.max[2] },
            .{ self.min[0], self.max[1], self.max[2] },
            .{ self.max[0], self.max[1], self.max[2] },
        };

        var result = AABB.empty();
        for (corners) |corner| {
            const scaled = vec3.mul(corner, transform.scale);
            const rotated = quat.rotateVec3(transform.rotation, scaled);
            const translated = vec3.add(rotated, transform.translation);
            result.expand(translated);
        }

        return result;
    }
};
