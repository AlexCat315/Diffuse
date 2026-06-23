// Camera-facing billboard/ribbon particles. One instanced quad per particle: the quad
// corners come from @builtin(vertex_index) (6 verts = 2 triangles), the per-
// particle center/size/color from a read-only storage buffer indexed by
// @builtin(instance_index). Soft billboard particles use a radial alpha falloff;
// ribbon segments render as rectangular strips. Drawn with alpha blending,
// depth-test (read) against the scene depth, depth-write disabled.

struct ParticleUniforms {
    view_proj : mat4x4<f32>,
    camera_right : vec4<f32>,
    camera_up : vec4<f32>,
    camera_forward : vec4<f32>,
};

struct ParticleInstance {
    position_size : vec4<f32>,  // xyz = world position, w = size
    rotation : vec4<f32>,       // x = rotation, y = shape, z/w = ribbon V offset/scale
    color : vec4<f32>,
    uv_rect : vec4<f32>,        // x/y = origin, z/w = extent
    axis_stretch : vec4<f32>,   // xyz = optional world axis, w = stretch
    ribbon_color : vec4<f32>,   // ribbon end color; billboards mirror color
    ribbon_params : vec4<f32>,  // x/y = ribbon start/end width
};

@group(0) @binding(0) var<uniform> u : ParticleUniforms;
@group(0) @binding(1) var<storage, read> particles : array<ParticleInstance>;
@group(0) @binding(2) var particle_sampler : sampler;
@group(0) @binding(3) var particle_texture : texture_2d<f32>;

struct VsOut {
    @builtin(position) position : vec4<f32>,
    @location(0) uv : vec2<f32>,
    @location(1) color : vec4<f32>,
    @location(2) local_uv : vec2<f32>,
    @location(3) shape : f32,
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
    let local_uv = corner + vec2<f32>(0.5, 0.5);
    let is_ribbon_segment = particle.rotation.y > 0.5;
    let axis_len = length(particle.axis_stretch.xyz);
    var offset : vec3<f32>;
    if axis_len > 0.0001 {
        let axis = particle.axis_stretch.xyz / axis_len;
        let projected = axis - u.camera_forward.xyz * dot(axis, u.camera_forward.xyz);
        let projected_len = length(projected);
        var along = u.camera_up.xyz;
        if projected_len > 0.0001 {
            along = projected / projected_len;
        }
        let side = normalize(cross(along, u.camera_forward.xyz));
        if is_ribbon_segment {
            let width = mix(particle.ribbon_params.x, particle.ribbon_params.y, local_uv.y);
            offset = side * corner.x * width
                + along * corner.y * particle.axis_stretch.w * particle.position_size.w;
        } else {
            offset = (side * corner.x + along * corner.y * particle.axis_stretch.w)
                * particle.position_size.w;
        }
    } else {
        let s = sin(particle.rotation.x);
        let c = cos(particle.rotation.x);
        let rotated_corner = vec2<f32>(
            corner.x * c - corner.y * s,
            corner.x * s + corner.y * c
        );
        offset = (u.camera_right.xyz * rotated_corner.x + u.camera_up.xyz * rotated_corner.y)
            * particle.position_size.w;
    }
    let world_position = particle.position_size.xyz + offset;

    var out : VsOut;
    out.position = u.view_proj * vec4<f32>(world_position, 1.0);
    var sampled_local_uv = local_uv;
    if is_ribbon_segment && particle.rotation.w > 0.0001 {
        sampled_local_uv.y = fract(particle.rotation.z + local_uv.y * particle.rotation.w);
    }
    out.uv = particle.uv_rect.xy + sampled_local_uv * particle.uv_rect.zw;
    out.local_uv = local_uv;
    out.color = select(particle.color, mix(particle.color, particle.ribbon_color, local_uv.y), is_ribbon_segment);
    out.shape = particle.rotation.y;
    return out;
}

@fragment
fn fs_main(in : VsOut) -> @location(0) vec4<f32> {
    let dist = length(in.local_uv - vec2<f32>(0.5, 0.5)) * 2.0;
    let is_ribbon_segment = in.shape > 0.5;
    let falloff = select(smoothstep(1.0, 0.0, dist), 1.0, is_ribbon_segment);
    let texel = textureSample(particle_texture, particle_sampler, in.uv);
    let alpha = in.color.a * texel.a * falloff;
    return vec4<f32>(in.color.rgb * texel.rgb, alpha);
}
