struct GridUniforms {
    inverse_relative_view_projection: mat4x4<f32>,
    relative_view_projection: mat4x4<f32>,
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

fn grid_line(position: vec2<f32>, footprint: vec2<f32>, spacing: f32, width: f32) -> f32 {
    let distance = abs(fract(position / spacing + 0.5) - 0.5) * spacing;
    let coverage = 1.0 - smoothstep(vec2<f32>(width * 0.5 - 0.5),
                                   vec2<f32>(width * 0.5 + 0.5), distance / footprint);
    // Fade each direction independently at grazing angles.
    let fade = 1.0 - smoothstep(vec2<f32>(0.25), vec2<f32>(0.75), footprint / spacing);
    return max(coverage.x * fade.x, coverage.y * fade.y);
}

fn grid_levels(position: vec2<f32>, footprint: vec2<f32>, spacing: f32,
               transition: f32, width: f32) -> f32 {
    let minor = grid_line(position, footprint, spacing, width) * 0.40 * (1.0 - transition);
    let major = grid_line(position, footprint, spacing * 10.0, width) * mix(0.65, 0.40, transition);
    let coarse = grid_line(position, footprint, spacing * 100.0, width) * 0.65 * transition;
    return max(minor, max(major, coarse));
}

fn axis_color(axis: f32) -> vec3<f32> {
    if axis < 0.5 { return vec3<f32>(0.95, 0.27, 0.34); }
    if axis < 1.5 { return vec3<f32>(0.36, 0.86, 0.41); }
    return vec3<f32>(0.18, 0.36, 1.0);
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
    let near_h = grid.inverse_relative_view_projection * vec4<f32>(ndc, 0.0, 1.0);
    // An interior depth avoids precision loss at a very distant far plane.
    let far_h = grid.inverse_relative_view_projection * vec4<f32>(ndc, 0.5, 1.0);
    let near = near_h.xyz / near_h.w;
    let far = far_h.xyz / far_h.w;
    let ray = far - near;
    let normal = cross(grid.plane_u.xyz, grid.plane_v.xyz);
    let denominator = dot(ray, normal);
    let safe_denominator = select(-max(abs(denominator), 0.00001),
                                   max(abs(denominator), 0.00001), denominator >= 0.0);
    let t = -dot(grid.camera_position.xyz + near, normal) / safe_denominator;
    let relative_world = near + ray * t;
    let world = grid.camera_position.xyz + relative_world;
    let clip = grid.relative_view_projection * vec4<f32>(relative_world, 1.0);
    let depth = clip.z / clip.w;
    // Derivatives precede all divergent discards so WGSL validation and
    // antialiasing remain well defined even at the horizon.
    let coordinates = vec2<f32>(dot(world, grid.plane_u.xyz), dot(world, grid.plane_v.xyz));
    let dx = dpdx(coordinates);
    let dy = dpdy(coordinates);
    let footprint = max(sqrt(dx * dx + dy * dy), vec2<f32>(0.00001));
    // Select and blend decade levels from the actual pixel footprint. This
    // keeps the plane readable while zooming and at oblique viewing angles.
    let lod = log2(max(max(footprint.x, footprint.y) * 8.0 / grid.viewport.z, 1.0)) / log2(10.0);
    let spacing = grid.viewport.z * pow(10.0, floor(lod));
    let transition = smoothstep(0.0, 1.0, fract(lod));
    let lines = grid_levels(coordinates, footprint, spacing, transition, 1.25);
    let outline = grid_levels(coordinates, footprint, spacing, transition, 2.75);
    let dark = vec3<f32>(0.04, 0.05, 0.07);
    var color = mix(dark, vec3<f32>(0.66, 0.70, 0.78), lines / max(outline, 0.00001));
    var alpha = outline;
    // A subtle dark border preserves axis contrast against light backgrounds.
    let axis_distance = abs(coordinates) / footprint;
    let u_axis = 1.0 - smoothstep(0.5, 1.5, axis_distance.y);
    let v_axis = 1.0 - smoothstep(0.5, 1.5, axis_distance.x);
    let axis_outline = 1.0 - smoothstep(1.5, 2.5, min(axis_distance.x, axis_distance.y));
    color = mix(color, dark, axis_outline);
    color = mix(color, axis_color(grid.plane_u.w), u_axis);
    color = mix(color, axis_color(grid.plane_v.w), v_axis);
    alpha = max(alpha, axis_outline * 0.95);
    let horizon_fade = smoothstep(0.001, 0.01, abs(dot(normalize(ray), normal)));
    alpha *= horizon_fade;
    if abs(denominator) < 0.00001 || t <= 0.0 || clip.w <= 0.0 || depth < 0.0 || alpha < 0.001 {
        discard;
    }
    var output: GridFragment;
    output.color = vec4<f32>(color, alpha);
    // Reference geometry extends past the scene far plane. At depth 1 it
    // still yields to scene geometry, without a visible clipping boundary.
    output.depth = min(depth, 1.0);
    return output;
}
