struct GridUniforms {
    inverse_view_projection: mat4x4<f32>,
    view_projection: mat4x4<f32>,
    camera_position: vec4<f32>,
    viewport: vec4<f32>,
    plane_u: vec4<f32>,
    plane_v: vec4<f32>,
};
@group(0) @binding(0) var<uniform> grid: GridUniforms;

@vertex
fn vs_main(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
    let positions = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0)
    );
    return vec4<f32>(positions[index], 0.0, 1.0);
}

fn grid_line(position: vec2<f32>, footprint: vec2<f32>, spacing: f32) -> f32 {
    let distance = abs(fract(position / spacing + 0.5) - 0.5) * spacing;
    let coverage = 1.0 - smoothstep(vec2<f32>(0.0), footprint, distance);
    // Suppress subpixel cells before they turn into a solid shimmering plane.
    let fade = 1.0 - smoothstep(0.25, 1.0, max(footprint.x, footprint.y) / spacing);
    return max(coverage.x, coverage.y) * fade;
}

fn axis_color(axis: f32) -> vec3<f32> {
    if axis < 0.5 { return vec3<f32>(0.80, 0.16, 0.12); }
    if axis < 1.5 { return vec3<f32>(0.16, 0.70, 0.22); }
    return vec3<f32>(0.12, 0.36, 0.85);
}

struct GridFragment {
    @location(0) color: vec4<f32>,
    @builtin(frag_depth) depth: f32,
};

@fragment
fn fs_main(@builtin(position) pixel: vec4<f32>) -> GridFragment {
    // Use the rendered region, which may be smaller than the backing texture.
    let ndc = vec2<f32>(pixel.x / grid.viewport.x * 2.0 - 1.0,
                        1.0 - pixel.y / grid.viewport.y * 2.0);
    let near_h = grid.inverse_view_projection * vec4<f32>(ndc, 0.0, 1.0);
    let far_h = grid.inverse_view_projection * vec4<f32>(ndc, 0.9999, 1.0);
    let near = near_h.xyz / near_h.w;
    let far = far_h.xyz / far_h.w;
    let ray = far - near;
    let normal = cross(grid.plane_u.xyz, grid.plane_v.xyz);
    let denominator = dot(ray, normal);
    let safe_denominator = select(-max(abs(denominator), 0.00001),
                                   max(abs(denominator), 0.00001), denominator >= 0.0);
    let t = -dot(near, normal) / safe_denominator;
    let world = near + ray * t;
    let clip = grid.view_projection * vec4<f32>(world, 1.0);
    let depth = clip.z / clip.w;
    // Derivatives precede all divergent discards so WGSL validation and
    // antialiasing remain well defined even at the horizon.
    let coordinates = vec2<f32>(dot(world, grid.plane_u.xyz), dot(world, grid.plane_v.xyz));
    let footprint = max(fwidth(coordinates), vec2<f32>(0.00001));
    let minor = grid_line(coordinates, footprint, grid.viewport.z);
    let major = grid_line(coordinates, footprint, grid.viewport.z * 10.0);
    var color = mix(vec3<f32>(0.28, 0.32, 0.40), vec3<f32>(0.45, 0.49, 0.58), major);
    var alpha = max(minor * 0.35, major * 0.55);
    // Two in-plane world axes, with widths measured in pixels.
    let u_axis = 1.0 - smoothstep(0.0, footprint.y * 1.5, abs(coordinates.y));
    let v_axis = 1.0 - smoothstep(0.0, footprint.x * 1.5, abs(coordinates.x));
    color = mix(color, axis_color(grid.plane_u.w), u_axis);
    color = mix(color, axis_color(grid.plane_v.w), v_axis);
    alpha = max(alpha, max(u_axis, v_axis) * 0.85);
    let distance = length(world - grid.camera_position.xyz);
    let distance_fade = 1.0 - smoothstep(grid.viewport.w * 0.25, grid.viewport.w, distance);
    let horizon_fade = smoothstep(0.01, 0.15, abs(dot(normalize(ray), normal)));
    alpha *= distance_fade * horizon_fade;
    if abs(denominator) < 0.00001 || t <= 0.0 || clip.w <= 0.0 || depth < 0.0 || depth > 1.0 || alpha < 0.001 {
        discard;
    }
    var output: GridFragment;
    output.color = vec4<f32>(color, alpha);
    output.depth = depth;
    return output;
}
