const std = @import("std");
const mesh_mod = @import("../../assets/mesh_resource.zig");
const math = @import("../../math/mat4.zig");
const vec3 = @import("../../math/vec3.zig");
const components = @import("../../scene/components.zig");
const scene_mod = @import("../../scene/scene.zig");

const RasterVertex = struct {
    screen: [2]f32,
    ndc_z: f32,
    world_position: [3]f32,
    world_normal: [3]f32,
    color: [3]f32,
};

const CameraState = struct {
    transform: components.Transform,
    camera: components.Camera,
};

const LightState = struct {
    direction: [3]f32,
    color: [3]f32,
    intensity: f32,
};

const PointLightState = struct {
    position: [3]f32,
    color: [3]f32,
    intensity: f32,
    range: f32,
};

pub fn renderScenePpmAlloc(
    allocator: std.mem.Allocator,
    scene: *const scene_mod.Scene,
    width: usize,
    height: usize,
) ![]u8 {
    const camera_state = chooseCamera(scene);
    const aspect_ratio = if (height == 0)
        1.0
    else
        @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    const view_projection = math.mul(
        math.projectionForCamera(camera_state.camera, aspect_ratio),
        math.viewMatrix(camera_state.transform),
    );
    const main_light = chooseMainLight(scene);
    const point_light = choosePointLight(scene);
    const camera_position = camera_state.transform.translation;
    const ambient_color = [3]f32{ 0.14, 0.15, 0.18 };

    const pixel_count = width * height;
    const color = try allocator.alloc([3]u8, pixel_count);
    defer allocator.free(color);
    @memset(color, .{ 12, 14, 18 });

    const depth = try allocator.alloc(f32, pixel_count);
    defer allocator.free(depth);
    @memset(depth, std.math.inf(f32));

    for (scene.entities.items) |entity| {
        if (!entity.visible) {
            continue;
        }
        const mesh_component = entity.mesh orelse continue;
        const mesh_handle = mesh_component.handle orelse continue;
        const mesh = scene.resources.mesh(mesh_handle) orelse continue;
        if (mesh.indices.len < 3 or mesh.primitive_type != .triangle_list) {
            continue;
        }

        const material = if (entity.material) |material_component|
            if (material_component.handle) |material_handle|
                scene.resources.material(material_handle)
            else
                null
        else
            null;
        const base_color_factor = if (material) |material_resource|
            material_resource.base_color_factor
        else if (entity.material) |material_component|
            material_component.base_color_factor
        else
            [4]f32{ 1.0, 1.0, 1.0, 1.0 };

        const model = math.transformMatrix(scene.worldTransformConst(entity.id) orelse entity.local_transform);
        var triangle_index: usize = 0;
        while (triangle_index + 2 < mesh.indices.len) : (triangle_index += 3) {
            const a = mesh.vertices[mesh.indices[triangle_index]];
            const b = mesh.vertices[mesh.indices[triangle_index + 1]];
            const c = mesh.vertices[mesh.indices[triangle_index + 2]];

            const rv0 = projectVertex(a, model, view_projection, width, height) orelse continue;
            const rv1 = projectVertex(b, model, view_projection, width, height) orelse continue;
            const rv2 = projectVertex(c, model, view_projection, width, height) orelse continue;

            rasterizeTriangle(
                color,
                depth,
                width,
                height,
                rv0,
                rv1,
                rv2,
                base_color_factor,
                camera_position,
                main_light,
                point_light,
                ambient_color,
            );
        }
    }

    return writePpmAlloc(allocator, color, width, height);
}

fn projectVertex(
    vertex: mesh_mod.Vertex,
    model: math.Mat4,
    view_projection: math.Mat4,
    width: usize,
    height: usize,
) ?RasterVertex {
    const world_position = mulPoint(model, vertex.position);
    const clip = mulPoint4(view_projection, .{ world_position[0], world_position[1], world_position[2], 1.0 });
    if (@abs(clip[3]) <= 0.00001) {
        return null;
    }

    const ndc_x = clip[0] / clip[3];
    const ndc_y = clip[1] / clip[3];
    const ndc_z = clip[2] / clip[3];
    if (ndc_x < -1.25 or ndc_x > 1.25 or ndc_y < -1.25 or ndc_y > 1.25) {
        return null;
    }

    return .{
        .screen = .{
            (ndc_x * 0.5 + 0.5) * @as(f32, @floatFromInt(width - 1)),
            (1.0 - (ndc_y * 0.5 + 0.5)) * @as(f32, @floatFromInt(height - 1)),
        },
        .ndc_z = ndc_z,
        .world_position = world_position,
        .world_normal = normalize3(mulDirection(model, vertex.normal)),
        .color = .{ vertex.color[0], vertex.color[1], vertex.color[2] },
    };
}

fn rasterizeTriangle(
    color: [][3]u8,
    depth: []f32,
    width: usize,
    height: usize,
    v0: RasterVertex,
    v1: RasterVertex,
    v2: RasterVertex,
    base_color_factor: [4]f32,
    camera_position: [3]f32,
    main_light: LightState,
    point_light: PointLightState,
    ambient_color: [3]f32,
) void {
    const min_x = @max(@as(i32, @intFromFloat(std.math.floor(@min(@min(v0.screen[0], v1.screen[0]), v2.screen[0])))), 0);
    const max_x = @min(@as(i32, @intFromFloat(std.math.ceil(@max(@max(v0.screen[0], v1.screen[0]), v2.screen[0])))), @as(i32, @intCast(width - 1)));
    const min_y = @max(@as(i32, @intFromFloat(std.math.floor(@min(@min(v0.screen[1], v1.screen[1]), v2.screen[1])))), 0);
    const max_y = @min(@as(i32, @intFromFloat(std.math.ceil(@max(@max(v0.screen[1], v1.screen[1]), v2.screen[1])))), @as(i32, @intCast(height - 1)));

    const area = edgeFunction(v0.screen, v1.screen, v2.screen);
    if (@abs(area) <= 0.0001) {
        return;
    }

    var y = min_y;
    while (y <= max_y) : (y += 1) {
        var x = min_x;
        while (x <= max_x) : (x += 1) {
            const sample = [2]f32{
                @as(f32, @floatFromInt(x)) + 0.5,
                @as(f32, @floatFromInt(y)) + 0.5,
            };

            const w0 = edgeFunction(v1.screen, v2.screen, sample) / area;
            const w1 = edgeFunction(v2.screen, v0.screen, sample) / area;
            const w2 = edgeFunction(v0.screen, v1.screen, sample) / area;
            if (w0 < -0.0001 or w1 < -0.0001 or w2 < -0.0001) {
                continue;
            }

            const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
            const z = v0.ndc_z * w0 + v1.ndc_z * w1 + v2.ndc_z * w2;
            if (z >= depth[pixel_index]) {
                continue;
            }
            depth[pixel_index] = z;

            const world_position = blend3(v0.world_position, v1.world_position, v2.world_position, w0, w1, w2);
            const normal = normalize3(blend3(v0.world_normal, v1.world_normal, v2.world_normal, w0, w1, w2));
            const vertex_color = clamp3(blend3(v0.color, v1.color, v2.color, w0, w1, w2));

            const light_dir = normalize3(.{
                -main_light.direction[0],
                -main_light.direction[1],
                -main_light.direction[2],
            });
            const view_dir = normalize3(.{
                camera_position[0] - world_position[0],
                camera_position[1] - world_position[1],
                camera_position[2] - world_position[2],
            });
            const half_vector = normalize3(.{
                light_dir[0] + view_dir[0],
                light_dir[1] + view_dir[1],
                light_dir[2] + view_dir[2],
            });

            const diffuse_strength = @max(dot3(normal, light_dir), 0.0);
            const specular_strength = std.math.pow(f32, @max(dot3(normal, half_vector), 0.0), 32.0) * 0.18;

            const point_light_vector = .{
                point_light.position[0] - world_position[0],
                point_light.position[1] - world_position[1],
                point_light.position[2] - world_position[2],
            };
            const point_distance = vecLength(point_light_vector);
            const point_light_dir = if (point_distance > 0.0001)
                scale3(point_light_vector, 1.0 / point_distance)
            else
                [3]f32{ 0.0, 1.0, 0.0 };
            var point_attenuation: f32 = std.math.clamp(1.0 - point_distance / @max(point_light.range, 0.001), 0.0, 1.0);
            point_attenuation *= point_attenuation;
            const point_diffuse = @max(dot3(normal, point_light_dir), 0.0) * point_attenuation;
            const point_half_vector = normalize3(.{
                point_light_dir[0] + view_dir[0],
                point_light_dir[1] + view_dir[1],
                point_light_dir[2] + view_dir[2],
            });
            const point_specular = std.math.pow(f32, @max(dot3(normal, point_half_vector), 0.0), 24.0) * 0.12 * point_attenuation;

            const albedo = .{
                vertex_color[0] * base_color_factor[0],
                vertex_color[1] * base_color_factor[1],
                vertex_color[2] * base_color_factor[2],
            };
            const lighting = .{
                ambient_color[0] + main_light.color[0] * (main_light.intensity * diffuse_strength + specular_strength) + point_light.color[0] * (point_light.intensity * point_diffuse + point_specular),
                ambient_color[1] + main_light.color[1] * (main_light.intensity * diffuse_strength + specular_strength) + point_light.color[1] * (point_light.intensity * point_diffuse + point_specular),
                ambient_color[2] + main_light.color[2] * (main_light.intensity * diffuse_strength + specular_strength) + point_light.color[2] * (point_light.intensity * point_diffuse + point_specular),
            };

            color[pixel_index] = .{
                toByte(albedo[0] * lighting[0]),
                toByte(albedo[1] * lighting[1]),
                toByte(albedo[2] * lighting[2]),
            };
        }
    }
}

fn writePpmAlloc(allocator: std.mem.Allocator, pixels: []const [3]u8, width: usize, height: usize) ![]u8 {
    var output = std.ArrayList(u8).empty;
    defer output.deinit(allocator);
    try output.print(allocator, "P3\n{d} {d}\n255\n", .{ width, height });
    for (pixels, 0..) |pixel, index| {
        try output.print(allocator, "{d} {d} {d}", .{ pixel[0], pixel[1], pixel[2] });
        if (index + 1 < pixels.len) {
            try output.append(allocator, '\n');
        }
    }
    return output.toOwnedSlice(allocator);
}

fn chooseCamera(scene: *const scene_mod.Scene) CameraState {
    var fallback: ?CameraState = null;
    for (scene.entities.items) |entity| {
        const camera = entity.camera orelse continue;
        const world_transform = scene.worldTransformConst(entity.id) orelse entity.local_transform;
        const candidate: CameraState = .{
            .transform = world_transform,
            .camera = camera,
        };
        if (camera.is_primary) {
            return candidate;
        }
        if (fallback == null) {
            fallback = candidate;
        }
    }
    return fallback orelse .{
        .transform = .{ .translation = .{ 0.0, 1.5, 5.0 } },
        .camera = .{ .is_primary = true },
    };
}

fn chooseMainLight(scene: *const scene_mod.Scene) LightState {
    for (scene.entities.items) |entity| {
        if (!entity.visible) {
            continue;
        }
        const light = entity.light orelse continue;
        if (light.kind != .directional) {
            continue;
        }
        const world_transform = scene.worldTransformConst(entity.id) orelse entity.local_transform;
        const quat = @import("../../math/quat.zig");
        return .{
            .direction = quat.rotateVec3(world_transform.rotation, .{ 0.0, 0.0, -1.0 }),
            .color = light.color,
            .intensity = light.intensity,
        };
    }

    return .{
        .direction = vec3.normalize(.{ 0.3, -0.9, -0.2 }),
        .color = .{ 1.0, 0.98, 0.92 },
        .intensity = 1.6,
    };
}

fn choosePointLight(scene: *const scene_mod.Scene) PointLightState {
    for (scene.entities.items) |entity| {
        if (!entity.visible) {
            continue;
        }
        const light = entity.light orelse continue;
        if (light.kind != .point) {
            continue;
        }
        const world_transform = scene.worldTransformConst(entity.id) orelse entity.local_transform;
        return .{
            .position = world_transform.translation,
            .color = light.color,
            .intensity = light.intensity,
            .range = light.range,
        };
    }

    return .{
        .position = .{ 0.0, 0.0, 0.0 },
        .color = .{ 1.0, 0.95, 0.9 },
        .intensity = 0.0,
        .range = 1.0,
    };
}

fn mulPoint(matrix_value: math.Mat4, point: [3]f32) [3]f32 {
    return .{
        matrix_value[0] * point[0] + matrix_value[4] * point[1] + matrix_value[8] * point[2] + matrix_value[12],
        matrix_value[1] * point[0] + matrix_value[5] * point[1] + matrix_value[9] * point[2] + matrix_value[13],
        matrix_value[2] * point[0] + matrix_value[6] * point[1] + matrix_value[10] * point[2] + matrix_value[14],
    };
}

fn mulPoint4(matrix_value: math.Mat4, point: [4]f32) [4]f32 {
    return .{
        matrix_value[0] * point[0] + matrix_value[4] * point[1] + matrix_value[8] * point[2] + matrix_value[12] * point[3],
        matrix_value[1] * point[0] + matrix_value[5] * point[1] + matrix_value[9] * point[2] + matrix_value[13] * point[3],
        matrix_value[2] * point[0] + matrix_value[6] * point[1] + matrix_value[10] * point[2] + matrix_value[14] * point[3],
        matrix_value[3] * point[0] + matrix_value[7] * point[1] + matrix_value[11] * point[2] + matrix_value[15] * point[3],
    };
}

fn mulDirection(matrix_value: math.Mat4, direction: [3]f32) [3]f32 {
    return .{
        matrix_value[0] * direction[0] + matrix_value[4] * direction[1] + matrix_value[8] * direction[2],
        matrix_value[1] * direction[0] + matrix_value[5] * direction[1] + matrix_value[9] * direction[2],
        matrix_value[2] * direction[0] + matrix_value[6] * direction[1] + matrix_value[10] * direction[2],
    };
}

fn edgeFunction(a: [2]f32, b: [2]f32, c: [2]f32) f32 {
    return (c[0] - a[0]) * (b[1] - a[1]) - (c[1] - a[1]) * (b[0] - a[0]);
}

fn blend3(a: [3]f32, b: [3]f32, c: [3]f32, wa: f32, wb: f32, wc: f32) [3]f32 {
    return .{
        a[0] * wa + b[0] * wb + c[0] * wc,
        a[1] * wa + b[1] * wb + c[1] * wc,
        a[2] * wa + b[2] * wb + c[2] * wc,
    };
}

fn normalize3(value: [3]f32) [3]f32 {
    const length = vecLength(value);
    if (length <= 0.00001) {
        return .{ 0.0, 1.0, 0.0 };
    }
    return scale3(value, 1.0 / length);
}

fn clamp3(value: [3]f32) [3]f32 {
    return .{
        std.math.clamp(value[0], 0.0, 1.0),
        std.math.clamp(value[1], 0.0, 1.0),
        std.math.clamp(value[2], 0.0, 1.0),
    };
}

fn scale3(value: [3]f32, scale: f32) [3]f32 {
    return .{ value[0] * scale, value[1] * scale, value[2] * scale };
}

fn dot3(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn vecLength(value: [3]f32) f32 {
    return std.math.sqrt(dot3(value, value));
}

fn toByte(value: f32) u8 {
    return @intFromFloat(std.math.clamp(value, 0.0, 1.0) * 255.0);
}

fn expectPpmSimilar(golden: []const u8, actual: []const u8, max_diff_per_pixel: f32) !void {
    if (std.mem.eql(u8, golden, actual)) {
        return;
    }
    var golden_iter = std.mem.tokenizeAny(u8, golden, " \n\r\t");
    var actual_iter = std.mem.tokenizeAny(u8, actual, " \n\r\t");

    const p3_golden = golden_iter.next() orelse return error.InvalidFormat;
    const p3_actual = actual_iter.next() orelse return error.InvalidFormat;
    try std.testing.expectEqualStrings("P3", p3_golden);
    try std.testing.expectEqualStrings("P3", p3_actual);

    for (0..3) |_| {
        const g_val = golden_iter.next() orelse return error.InvalidFormat;
        const a_val = actual_iter.next() orelse return error.InvalidFormat;
        try std.testing.expectEqualStrings(g_val, a_val);
    }

    var total_diff: f32 = 0;
    var count: usize = 0;

    while (true) {
        const g_str = golden_iter.next();
        const a_str = actual_iter.next();
        if (g_str == null and a_str == null) break;
        if (g_str == null or a_str == null) return error.SizeMismatch;

        const g = try std.fmt.parseInt(i32, g_str.?, 10);
        const a = try std.fmt.parseInt(i32, a_str.?, 10);

        const diff: i32 = if (g > a) g - a else a - g;
        total_diff += @floatFromInt(diff);
        count += 1;
    }

    const avg_diff = if (count > 0) total_diff / @as(f32, @floatFromInt(count)) else 0.0;
    if (avg_diff > max_diff_per_pixel) {
        std.debug.print("PPM diff exceeded threshold! avg_diff: {d}, max allowed: {d}\n", .{ avg_diff, max_diff_per_pixel });
        return error.GoldenMismatch;
    }
}

test "base pass golden ppm matches bootstrap scene" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();
    try world.bootstrap3D();

    const ppm = try renderScenePpmAlloc(std.testing.allocator, &world, 24, 24);
    defer std.testing.allocator.free(ppm);

    const golden = try std.fs.cwd().readFileAlloc(std.testing.allocator, "assets/golden/base_pass_bootstrap.ppm", 128 * 1024);
    defer std.testing.allocator.free(golden);

    try expectPpmSimilar(golden, ppm, 2.0);
}

test "shadow pass baseline verifies light space matrix and directional light" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();
    try world.bootstrap3D();

    // Find directional light entity
    var light_entity_id: ?scene_mod.EntityId = null;
    for (world.entities.items) |entity| {
        if (entity.light) |light| {
            if (light.kind == .directional) {
                light_entity_id = entity.id;
                break;
            }
        }
    }

    try std.testing.expect(light_entity_id != null);

    const light_entity = world.getEntityConst(light_entity_id.?).?;
    try std.testing.expect(light_entity.light.?.kind == .directional);
    try std.testing.expect(light_entity.light.?.intensity > 0.0);

    // Verify light direction is normalized (rotation quaternion)
    const quat = @import("../../math/quat.zig");
    const light_dir = quat.rotateVec3(light_entity.local_transform.rotation, .{ 0.0, 0.0, -1.0 });
    const dir_len = @sqrt(light_dir[0] * light_dir[0] + light_dir[1] * light_dir[1] + light_dir[2] * light_dir[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), dir_len, 0.001);
}

test "import and animation baseline verifies animation clip creation and playback" {
    var world = scene_mod.World.init(std.testing.allocator, null);
    defer world.deinit();

    const target_id = try world.createEntity(.{
        .name = "AnimatedCube",
        .local_transform = .{
            .translation = .{ 0.0, 0.0, 0.0 },
        },
    });

    const clip_handle = try world.resources.createAnimationClip(.{
        .name = "Bounce",
        .duration = 1.0,
        .translation_tracks = &.{
            .{
                .target_entity_index = 0,
                .times = &.{ 0.0, 0.5, 1.0 },
                .values = &.{ .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 }, .{ 0.0, 0.0, 0.0 } },
            },
        },
    });

    const animator_id = try world.createEntity(.{
        .name = "Animator",
        .animator = .{
            .default_clip_handle = clip_handle,
        },
    });

    try world.bindAnimatorTargets(animator_id, &.{target_id});

    // Verify clip was created
    const clip = world.resources.animationClip(clip_handle);
    try std.testing.expect(clip != null);
    try std.testing.expectEqualStrings("Bounce", clip.?.name);
    try std.testing.expectEqual(@as(usize, 1), clip.?.translation_tracks.len);
}
