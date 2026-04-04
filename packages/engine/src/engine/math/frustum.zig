const std = @import("std");
const vec3 = @import("vec3.zig");
const aabb = @import("aabb.zig");

pub const Plane = struct {
    normal: [3]f32,
    distance: f32,

    pub fn init(normal: [3]f32, distance: f32) Plane {
        const len = vec3.length(normal);
        return .{
            .normal = vec3.scale(normal, 1.0 / len),
            .distance = distance / len,
        };
    }

    pub fn fromPoints(p1: [3]f32, p2: [3]f32, p3: [3]f32) Plane {
        const v1 = vec3.sub(p2, p1);
        const v2 = vec3.sub(p3, p1);
        const normal = vec3.normalize(vec3.cross(v1, v2));
        return .{
            .normal = normal,
            .distance = vec3.dot(normal, p1),
        };
    }

    pub fn getSignedDistance(self: Plane, point: [3]f32) f32 {
        return vec3.dot(self.normal, point) - self.distance;
    }
};

pub const Frustum = struct {
    planes: [6]Plane,

    pub fn fromViewProjection(vp: [16]f32) Frustum {
        var frustum: Frustum = undefined;

        // Left Plane
        frustum.planes[0] = Plane.init(
            .{ vp[3] + vp[0], vp[7] + vp[4], vp[11] + vp[8] },
            -(vp[15] + vp[12]),
        );
        // Right Plane
        frustum.planes[1] = Plane.init(
            .{ vp[3] - vp[0], vp[7] - vp[4], vp[11] - vp[8] },
            -(vp[15] - vp[12]),
        );
        // Bottom Plane
        frustum.planes[2] = Plane.init(
            .{ vp[3] + vp[1], vp[7] + vp[5], vp[11] + vp[9] },
            -(vp[15] + vp[13]),
        );
        // Top Plane
        frustum.planes[3] = Plane.init(
            .{ vp[3] - vp[1], vp[7] - vp[5], vp[11] - vp[9] },
            -(vp[15] - vp[13]),
        );
        // Near Plane
        frustum.planes[4] = Plane.init(
            .{ vp[3] + vp[2], vp[7] + vp[6], vp[11] + vp[10] },
            -(vp[15] + vp[14]),
        );
        // Far Plane
        frustum.planes[5] = Plane.init(
            .{ vp[3] - vp[2], vp[7] - vp[6], vp[11] - vp[10] },
            -(vp[15] - vp[14]),
        );

        return frustum;
    }

    pub fn intersectsAABB(self: Frustum, box: aabb.AABB) bool {
        if (!box.isValid()) return false;

        for (self.planes) |plane| {
            // Find the positive vertex (farthest along the normal)
            var p = box.min;
            if (plane.normal[0] >= 0) p[0] = box.max[0];
            if (plane.normal[1] >= 0) p[1] = box.max[1];
            if (plane.normal[2] >= 0) p[2] = box.max[2];

            // If the positive vertex is behind the plane, the entire box is outside
            if (plane.getSignedDistance(p) < 0) {
                return false;
            }
        }
        return true;
    }
};
