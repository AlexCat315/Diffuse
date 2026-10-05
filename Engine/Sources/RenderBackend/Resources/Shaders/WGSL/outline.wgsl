struct Uniforms {
    mvp : mat4x4<f32>,
    model : mat4x4<f32>,
    color_tint : vec4<f32>,
    material : vec4<f32>, // mode, cutoff, double-sided, use instance storage
};

struct StylizedStyle {
    toon_thresholds : vec4<f32>,
    toon_levels : vec4<f32>,
    ink_wash_color : vec4<f32>,
    params : vec4<f32>,
};

@group(0) @binding(0) var<uniform> u : Uniforms;
@group(0) @binding(2) var base_color_sampler : sampler;
@group(0) @binding(3) var base_color_texture : texture_2d<f32>;
@group(0) @binding(1) var<uniform> style : StylizedStyle;
@group(0) @binding(8) var<storage, read> joint_palette : array<mat4x4<f32>>;
@group(0) @binding(12) var<storage, read> mesh_instances : array<Uniforms>;

fn instance_uniform(index : u32) -> Uniforms {
    if u.material.w > 0.5 { return mesh_instances[index]; }
    return u;
}


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
    @location(0) uv : vec2<f32>,
};

@vertex
fn vs_main(in : VsIn, @builtin(instance_index) instance_index : u32) -> VsOut {
    let draw = instance_uniform(instance_index);
    var out : VsOut;
    let skin = skin_matrix(in.joints, in.weights);
    let local = skin * vec4<f32>(in.pos, 1.0);
    let normal = skin * vec4<f32>(in.normal, 0.0);
    let expanded = local.xyz + safe_normalize(normal.xyz) * style.params.w;
    out.position = draw.mvp * vec4<f32>(expanded, 1.0);
    out.uv = in.uv;
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

fn safe_normalize(v : vec3<f32>) -> vec3<f32> {
    let len2 = dot(v, v);
    if len2 <= 0.000001 {
        return vec3<f32>(0.0, 1.0, 0.0);
    }
    return v * inverseSqrt(len2);
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let coverage = textureSample(base_color_texture, base_color_sampler, in.uv).a * u.color_tint.a;
    if u.material.x > 0.5 && coverage < u.material.y { discard; }
    return vec4<f32>(0.03, 0.03, 0.04, 1.0);
}
