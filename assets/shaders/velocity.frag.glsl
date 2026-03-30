#version 450

layout(location = 0) in vec4 v_current_clip;
layout(location = 1) in vec4 v_prev_clip;
layout(location = 0) out vec4 out_velocity;

vec2 clipToUv(vec4 clip_pos) {
    vec2 ndc = clip_pos.xy / max(abs(clip_pos.w), 0.00001);
    vec2 uv = ndc * 0.5 + 0.5;
    uv.y = 1.0 - uv.y;
    return uv;
}

void main() {
    vec2 current_uv = clipToUv(v_current_clip);
    vec2 prev_uv = clipToUv(v_prev_clip);
    vec2 velocity = current_uv - prev_uv;
    out_velocity = vec4(velocity, 0.0, 1.0);
}
