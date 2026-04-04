#version 450

layout(location = 0) out vec4 out_color;

layout(set = 2, binding = 0) uniform sampler2D u_entity_ids;

layout(set = 3, binding = 0, std140) uniform OutlineUniforms {
    vec4 u_selected_entity_color;
    vec4 u_outline_color;
} outline_uniforms;

bool is_selected(ivec2 pixel, ivec2 texture_size) {
    ivec2 clamped = clamp(pixel, ivec2(0), texture_size - ivec2(1));
    vec3 encoded = texelFetch(u_entity_ids, clamped, 0).rgb;
    return distance(encoded, outline_uniforms.u_selected_entity_color.rgb) < 0.001;
}

void main() {
    ivec2 texture_size = textureSize(u_entity_ids, 0);
    ivec2 pixel = clamp(ivec2(gl_FragCoord.xy), ivec2(0), texture_size - ivec2(1));

    if (is_selected(pixel, texture_size)) {
        discard;
    }

    const ivec2 offsets[8] = ivec2[](
        ivec2(-1, 0),
        ivec2(1, 0),
        ivec2(0, -1),
        ivec2(0, 1),
        ivec2(-1, -1),
        ivec2(1, -1),
        ivec2(-1, 1),
        ivec2(1, 1)
    );

    bool edge = false;
    for (int index = 0; index < offsets.length(); index++) {
        if (is_selected(pixel + offsets[index], texture_size)) {
            edge = true;
            break;
        }
    }

    if (!edge) {
        discard;
    }

    out_color = outline_uniforms.u_outline_color;
}
