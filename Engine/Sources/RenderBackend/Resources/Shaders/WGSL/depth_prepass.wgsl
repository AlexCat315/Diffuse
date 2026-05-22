struct Uniforms {
    mvp : mat4x4<f32>,
    model : mat4x4<f32>,
    color_tint : vec4<f32>,
};

@group(0) @binding(0) var<uniform> u : Uniforms;
@group(0) @binding(8) var<storage, read> joint_palette : array<mat4x4<f32>>;

struct VsIn {
    @location(0) pos            : vec3<f32>,
    @location(1) normal         : vec3<f32>,
    @location(2) color          : vec3<f32>,
    @location(3) uv             : vec2<f32>,
    @location(4) tangent        : vec4<f32>,
    @location(5) material_index : f32,
    @location(6) joints         : vec4<f32>,
    @location(7) weights        : vec4<f32>,
};

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) depth : f32,
};

@vertex
fn vs_main(in : VsIn) -> VsOut {
    var out : VsOut;
    let skin = skin_matrix(in.joints, in.weights);
    out.position = u.mvp * (skin * vec4<f32>(in.pos, 1.0));
    out.depth = out.position.z / max(out.position.w, 0.00001);
    return out;
}

fn skin_matrix(joints : vec4<f32>, weights : vec4<f32>) -> mat4x4<f32> {
    let total_weight = weights.x + weights.y + weights.z + weights.w;
    if total_weight > 0.0001 && arrayLength(&joint_palette) > 0u {
        let j = vec4<u32>(u32(joints.x), u32(joints.y), u32(joints.z), u32(joints.w));
        let count = arrayLength(&joint_palette);
        return joint_matrix(j.x, count) * weights.x
            + joint_matrix(j.y, count) * weights.y
            + joint_matrix(j.z, count) * weights.z
            + joint_matrix(j.w, count) * weights.w;
    }
    return identity_matrix();
}

fn joint_matrix(index : u32, count : u32) -> mat4x4<f32> {
    if index < count {
        return joint_palette[index];
    }
    return identity_matrix();
}

fn identity_matrix() -> mat4x4<f32> {
    return mat4x4<f32>(
        vec4<f32>(1.0, 0.0, 0.0, 0.0),
        vec4<f32>(0.0, 1.0, 0.0, 0.0),
        vec4<f32>(0.0, 0.0, 1.0, 0.0),
        vec4<f32>(0.0, 0.0, 0.0, 1.0)
    );
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let depth = clamp(in.depth, 0.0, 1.0);
    return vec4<f32>(vec3<f32>(depth), 1.0);
}
