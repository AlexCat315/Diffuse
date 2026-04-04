const std = @import("std");
const components = @import("../scene/components.zig");
const quat = @import("quat.zig");

pub const Mat4 = [16]f32;

pub fn identity() Mat4 {
    return .{
        1.0, 0.0, 0.0, 0.0,
        0.0, 1.0, 0.0, 0.0,
        0.0, 0.0, 1.0, 0.0,
        0.0, 0.0, 0.0, 1.0,
    };
}

pub fn mul(a: Mat4, b: Mat4) Mat4 {
    // 矩阵乘法：result = a * b
    // 说明：本模块使用“列主序（column-major）”存储（见下方 `get`/`set`），
    // 并采用列向量约定（向量作为 4x1 列向量，变换为 M * v）。
    // 因此在构造模型矩阵时按常见图形学约定使用 M = T * R * S，表示先缩放再旋转再平移。
    var result: Mat4 = [_]f32{0.0} ** 16;

    var col: usize = 0;
    while (col < 4) : (col += 1) {
        var row: usize = 0;
        while (row < 4) : (row += 1) {
            var value: f32 = 0.0;
            var i: usize = 0;
            while (i < 4) : (i += 1) {
                // 标准矩阵乘法（行*列）：a[row,i] * b[i,col]
                value += get(a, row, i) * get(b, i, col);
            }
            set(&result, row, col, value);
        }
    }

    return result;
}

pub fn transpose(matrix: Mat4) Mat4 {
    var result: Mat4 = undefined;
    for (0..4) |row| {
        for (0..4) |col| {
            set(&result, row, col, get(matrix, col, row));
        }
    }
    return result;
}

pub fn inverse(matrix: Mat4) ?Mat4 {
    var augmented: [4][8]f32 = undefined;

    for (0..4) |row| {
        for (0..4) |col| {
            augmented[row][col] = get(matrix, row, col);
            augmented[row][col + 4] = if (row == col) 1.0 else 0.0;
        }
    }

    for (0..4) |pivot_col| {
        var pivot_row = pivot_col;
        var max_value = @abs(augmented[pivot_row][pivot_col]);
        for ((pivot_col + 1)..4) |candidate_row| {
            const candidate_value = @abs(augmented[candidate_row][pivot_col]);
            if (candidate_value > max_value) {
                max_value = candidate_value;
                pivot_row = candidate_row;
            }
        }

        if (max_value <= 0.000001) {
            return null;
        }

        if (pivot_row != pivot_col) {
            const tmp = augmented[pivot_col];
            augmented[pivot_col] = augmented[pivot_row];
            augmented[pivot_row] = tmp;
        }

        const pivot = augmented[pivot_col][pivot_col];
        for (0..8) |col| {
            augmented[pivot_col][col] /= pivot;
        }

        for (0..4) |row| {
            if (row == pivot_col) {
                continue;
            }
            const factor = augmented[row][pivot_col];
            if (@abs(factor) <= 0.000001) {
                continue;
            }
            for (0..8) |col| {
                augmented[row][col] -= factor * augmented[pivot_col][col];
            }
        }
    }

    var result: Mat4 = undefined;
    for (0..4) |row| {
        for (0..4) |col| {
            set(&result, row, col, augmented[row][col + 4]);
        }
    }
    return result;
}

pub fn translation(offset: components.Vec3) Mat4 {
    var result = identity();
    set(&result, 0, 3, offset[0]);
    set(&result, 1, 3, offset[1]);
    set(&result, 2, 3, offset[2]);
    return result;
}

pub fn scale(factors: components.Vec3) Mat4 {
    var result = identity();
    set(&result, 0, 0, factors[0]);
    set(&result, 1, 1, factors[1]);
    set(&result, 2, 2, factors[2]);
    return result;
}

pub fn rotationX(radians: f32) Mat4 {
    var result = identity();
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    set(&result, 1, 1, c);
    set(&result, 1, 2, -s);
    set(&result, 2, 1, s);
    set(&result, 2, 2, c);
    return result;
}

pub fn rotationY(radians: f32) Mat4 {
    var result = identity();
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    set(&result, 0, 0, c);
    set(&result, 0, 2, s);
    set(&result, 2, 0, -s);
    set(&result, 2, 2, c);
    return result;
}

pub fn rotationZ(radians: f32) Mat4 {
    var result = identity();
    const c = std.math.cos(radians);
    const s = std.math.sin(radians);
    set(&result, 0, 0, c);
    set(&result, 0, 1, -s);
    set(&result, 1, 0, s);
    set(&result, 1, 1, c);
    return result;
}

pub fn transformMatrix(transform: components.Transform) Mat4 {
    // 构造模型矩阵：M = T * R * S
    // 解释：采用列向量约定（v' = M * v），因此表达式写成 T * R * S
    // 表示对顶点先应用 S（缩放），再应用 R（旋转），最后应用 T（平移）。
    const rotate = quat.toMat4(transform.rotation);
    return mul(mul(translation(transform.translation), rotate), scale(transform.scale));
}

pub fn inverseTransformMatrix(transform: components.Transform) Mat4 {
    const safe_inverse_scale: components.Vec3 = .{
        if (@abs(transform.scale[0]) <= 0.00001) 0.0 else 1.0 / transform.scale[0],
        if (@abs(transform.scale[1]) <= 0.00001) 0.0 else 1.0 / transform.scale[1],
        if (@abs(transform.scale[2]) <= 0.00001) 0.0 else 1.0 / transform.scale[2],
    };
    const inverse_scale = scale(safe_inverse_scale);
    const inverse_rotate = quat.toMat4(quat.inverse(quat.normalize(transform.rotation)));
    const inverse_translate = translation(.{
        -transform.translation[0],
        -transform.translation[1],
        -transform.translation[2],
    });
    return mul(inverse_scale, mul(inverse_rotate, inverse_translate));
}

pub fn viewMatrix(transform: components.Transform) Mat4 {
    const inverse_translate = translation(.{
        -transform.translation[0],
        -transform.translation[1],
        -transform.translation[2],
    });
    const inverse_rotate = quat.toMat4(quat.inverse(transform.rotation));
    return mul(inverse_rotate, inverse_translate);
}

pub fn lookAt(eye: components.Vec3, target: components.Vec3, up: components.Vec3) Mat4 {
    const vec3 = @import("vec3.zig");
    const z = vec3.normalize(vec3.sub(eye, target));
    const x = vec3.normalize(vec3.cross(up, z));
    const y = vec3.cross(z, x);

    var result = identity();
    set(&result, 0, 0, x[0]);
    set(&result, 0, 1, x[1]);
    set(&result, 0, 2, x[2]);
    set(&result, 0, 3, -vec3.dot(x, eye));
    set(&result, 1, 0, y[0]);
    set(&result, 1, 1, y[1]);
    set(&result, 1, 2, y[2]);
    set(&result, 1, 3, -vec3.dot(y, eye));
    set(&result, 2, 0, z[0]);
    set(&result, 2, 1, z[1]);
    set(&result, 2, 2, z[2]);
    set(&result, 2, 3, -vec3.dot(z, eye));
    return result;
}

pub fn perspective(fov_y_radians: f32, aspect_ratio: f32, near_clip: f32, far_clip: f32) Mat4 {
    const f = 1.0 / std.math.tan(fov_y_radians * 0.5);
    var result: Mat4 = [_]f32{0.0} ** 16;
    set(&result, 0, 0, f / aspect_ratio);
    set(&result, 1, 1, f);
    set(&result, 2, 2, far_clip / (near_clip - far_clip));
    set(&result, 2, 3, (far_clip * near_clip) / (near_clip - far_clip));
    set(&result, 3, 2, -1.0);
    return result;
}

pub fn orthographic(size: f32, aspect_ratio: f32, near_clip: f32, far_clip: f32) Mat4 {
    const half_height = size * 0.5;
    const half_width = half_height * aspect_ratio;
    var result = identity();
    set(&result, 0, 0, 1.0 / half_width);
    set(&result, 1, 1, 1.0 / half_height);
    set(&result, 2, 2, 1.0 / (near_clip - far_clip));
    set(&result, 2, 3, near_clip / (near_clip - far_clip));
    return result;
}

/// Asymmetric orthographic projection for tight-fit cascade shadow maps.
pub fn orthographicOffCenter(left: f32, right: f32, bottom: f32, top: f32, near_clip: f32, far_clip: f32) Mat4 {
    var result: Mat4 = [_]f32{0.0} ** 16;
    set(&result, 0, 0, 2.0 / (right - left));
    set(&result, 1, 1, 2.0 / (top - bottom));
    set(&result, 2, 2, 1.0 / (near_clip - far_clip));
    set(&result, 0, 3, -(right + left) / (right - left));
    set(&result, 1, 3, -(top + bottom) / (top - bottom));
    set(&result, 2, 3, near_clip / (near_clip - far_clip));
    set(&result, 3, 3, 1.0);
    return result;
}

pub fn projectionForCamera(camera: components.Camera, aspect_ratio: f32) Mat4 {
    return switch (camera.projection) {
        .perspective => |proj| perspective(
            proj.fov_y_radians,
            aspect_ratio,
            proj.near_clip,
            proj.far_clip,
        ),
        .orthographic => |proj| orthographic(
            proj.size,
            aspect_ratio,
            proj.near_clip,
            proj.far_clip,
        ),
    };
}

fn get(matrix: Mat4, row: usize, col: usize) f32 {
    // 存储映射（列主序）：索引 = col * 4 + row。
    // 例如，矩阵的第 4 列（索引 col=3）第 1 行（row=0）位于 array index = 3*4 + 0 = 12。
    return matrix[col * 4 + row];
}

fn set(matrix: *Mat4, row: usize, col: usize, value: f32) void {
    // 对应的写操作（列主序索引）。
    matrix[col * 4 + row] = value;
}

test "transform matrix keeps translation in the last column" {
    const matrix = transformMatrix(.{
        .translation = .{ 2.0, 3.0, 4.0 },
    });

    try std.testing.expectEqual(@as(f32, 2.0), matrix[12]);
    try std.testing.expectEqual(@as(f32, 3.0), matrix[13]);
    try std.testing.expectEqual(@as(f32, 4.0), matrix[14]);
}

test "perspective matrix keeps clip w positive for points in front of the camera" {
    const matrix = perspective(1.0471976, 1.0, 0.1, 1000.0);
    const view_space_point = [_]f32{ 0.0, 0.0, -5.0, 1.0 };
    const clip_w =
        matrix[3] * view_space_point[0] +
        matrix[7] * view_space_point[1] +
        matrix[11] * view_space_point[2] +
        matrix[15] * view_space_point[3];

    try std.testing.expect(clip_w > 0.0);
}

test "orthographic matrix keeps clip w constant and maps depth into 0..1" {
    const matrix = orthographic(10.0, 1.0, 0.1, 100.0);
    const near_point = [_]f32{ 0.0, 0.0, -0.1, 1.0 };
    const far_point = [_]f32{ 0.0, 0.0, -100.0, 1.0 };

    const near_clip = [_]f32{
        matrix[0] * near_point[0] + matrix[4] * near_point[1] + matrix[8] * near_point[2] + matrix[12] * near_point[3],
        matrix[1] * near_point[0] + matrix[5] * near_point[1] + matrix[9] * near_point[2] + matrix[13] * near_point[3],
        matrix[2] * near_point[0] + matrix[6] * near_point[1] + matrix[10] * near_point[2] + matrix[14] * near_point[3],
        matrix[3] * near_point[0] + matrix[7] * near_point[1] + matrix[11] * near_point[2] + matrix[15] * near_point[3],
    };
    const far_clip = [_]f32{
        matrix[0] * far_point[0] + matrix[4] * far_point[1] + matrix[8] * far_point[2] + matrix[12] * far_point[3],
        matrix[1] * far_point[0] + matrix[5] * far_point[1] + matrix[9] * far_point[2] + matrix[13] * far_point[3],
        matrix[2] * far_point[0] + matrix[6] * far_point[1] + matrix[10] * far_point[2] + matrix[14] * far_point[3],
        matrix[3] * far_point[0] + matrix[7] * far_point[1] + matrix[11] * far_point[2] + matrix[15] * far_point[3],
    };

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), near_clip[3], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), far_clip[3], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), near_clip[2], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), far_clip[2], 0.0001);
}

test "inverse transform matrix cancels transform matrix" {
    const transform: components.Transform = .{
        .translation = .{ 3.5, -2.0, 1.25 },
        .rotation = quat.normalize(.{ 0.2, 0.35, -0.1, 0.9 }),
        .scale = .{ 2.0, 0.5, 1.5 },
    };
    const composed = mul(transformMatrix(transform), inverseTransformMatrix(transform));

    try std.testing.expectApproxEqAbs(@as(f32, 1.0), composed[0], 0.0005);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), composed[5], 0.0005);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), composed[10], 0.0005);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), composed[15], 0.0005);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), composed[12], 0.0005);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), composed[13], 0.0005);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), composed[14], 0.0005);
}

test "generic inverse matches inverse transform matrix for affine transforms" {
    const transform: components.Transform = .{
        .translation = .{ -1.5, 0.75, 6.0 },
        .rotation = quat.normalize(.{ -0.15, 0.4, 0.2, 0.87 }),
        .scale = .{ 1.2, 2.5, 0.8 },
    };

    const matrix = transformMatrix(transform);
    const expected = inverseTransformMatrix(transform);
    const actual = inverse(matrix) orelse return error.TestUnexpectedResult;

    for (expected, actual) |expected_value, actual_value| {
        try std.testing.expectApproxEqAbs(expected_value, actual_value, 0.001);
    }
}
