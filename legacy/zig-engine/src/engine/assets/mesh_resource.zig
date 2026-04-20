const std = @import("std");
const gfx_types = @import("guava_rhi").types;
const AABB = @import("../math/aabb.zig").AABB;

// CPU 侧顶点布局：资产/模型使用的原始顶点格式
// 在上传到 GPU 时可能需要重新打包为与 shader 匹配的 GpuVertex
pub const Vertex = extern struct {
    // 位置（vec3）
    position: [3]f32,
    // 法线（vec3）
    normal: [3]f32,
    // 切线（vec4），w 通常用来指示副切线方向
    tangent: [4]f32,
    // 顶点颜色（RGBA）
    color: [4]f32,
    // 纹理坐标（UV）
    uv: [2]f32,
    // 骨骼索引（16-bit），用于蒙皮，默认为 {0,0,0,0}
    joints: [4]u16 = .{ 0, 0, 0, 0 },
    // 骨骼权重（默认第一个权重为 1，表示无蒙皮）
    weights: [4]f32 = .{ 1.0, 0.0, 0.0, 0.0 },
};

pub const MeshResource = struct {
    name: []u8,
    vertices: []Vertex,
    indices: []u32,
    primitive_type: gfx_types.PrimitiveType = .triangle_list,
    local_bounds: AABB = .{},

    pub fn deinit(self: *MeshResource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.vertices);
        allocator.free(self.indices);
        self.* = undefined;
    }
};

pub const MeshResourceDesc = struct {
    name: []const u8,
    vertices: []const Vertex,
    indices: []const u32,
    primitive_type: gfx_types.PrimitiveType = .triangle_list,
};

pub fn computeLocalBounds(vertices: []const Vertex) AABB {
    var local_bounds = AABB.empty();
    for (vertices) |vertex| {
        local_bounds.expand(vertex.position);
    }
    return local_bounds;
}

pub fn clone(allocator: std.mem.Allocator, desc: MeshResourceDesc) !MeshResource {
    return .{
        .name = try allocator.dupe(u8, desc.name),
        .vertices = try allocator.dupe(Vertex, desc.vertices),
        .indices = try allocator.dupe(u32, desc.indices),
        .primitive_type = desc.primitive_type,
        .local_bounds = computeLocalBounds(desc.vertices),
    };
}
