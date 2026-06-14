// Camera-facing billboard particles. One instanced quad per particle: the quad
// corners come from @builtin(vertex_index) (6 verts = 2 triangles), the per-
// particle center/size/color from a read-only storage buffer indexed by
// @builtin(instance_index). The fragment shader shapes each quad into a soft
// round sprite via a radial alpha falloff. Drawn with alpha blending, depth-test
// (read) against the scene depth, depth-write disabled.

struct ParticleUniforms {
    view_proj : mat4x4<f32>,
    camera_right : vec4<f32>,
    camera_up : vec4<f32>,
};

struct ParticleInstance {
    position_size : vec4<f32>,  // xyz = world position, w = size
    color : vec4<f32>,
};

@group(0) @binding(0) var<uniform> u : ParticleUniforms;
@group(0) @binding(1) var<storage, read> particles : array<ParticleInstance>;

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) uv : vec2<f32>,
    @location(1) color : vec4<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vertex_index : u32,
           @builtin(instance_index) instance_index : u32) -> VsOut {
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(-0.5, -0.5),
        vec2<f32>( 0.5, -0.5),
        vec2<f32>( 0.5,  0.5),
        vec2<f32>(-0.5, -0.5),
        vec2<f32>( 0.5,  0.5),
        vec2<f32>(-0.5,  0.5)
    );

    let particle = particles[instance_index];
    let corner = corners[vertex_index];
    let offset = (u.camera_right.xyz * corner.x + u.camera_up.xyz * corner.y) * particle.position_size.w;
    let world_position = particle.position_size.xyz + offset;

    var out : VsOut;
    out.position = u.view_proj * vec4<f32>(world_position, 1.0);
    out.uv = corner + vec2<f32>(0.5, 0.5);
    out.color = particle.color;
    return out;
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let dist = length(in.uv - vec2<f32>(0.5, 0.5)) * 2.0;
    let falloff = smoothstep(1.0, 0.0, dist);
    let alpha = in.color.a * falloff;
    return vec4<f32>(in.color.rgb, alpha);
}
