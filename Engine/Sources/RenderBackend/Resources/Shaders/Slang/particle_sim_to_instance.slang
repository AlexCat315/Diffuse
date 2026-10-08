#include "particle_sort_common.slang"
#include "particle_common.slang"
struct ParticleSimToInstanceUniforms {
    column_major float4x4 world_transform;
    float4 params; float4 uv_rect; float4 texture_sheet; float4 render_params; float4 trail_params;
    float4 texture_sheet_playback; float4 appearance_size; float4 appearance_start_color;
    float4 appearance_end_color; float4 appearance_color_curve; float4 curve_keyframes;
};
struct ParticleAppearance { float4 size; float4 start_color; float4 end_color; };
struct ParticleCurveKeyframe { float4 time_value; };
[[vk::binding(0,0)]] ConstantBuffer<ParticleSimToInstanceUniforms> uniforms : register(b0,space0);
[[vk::binding(1,0)]] StructuredBuffer<ParticleSimState> sim_particles : register(t1,space0);
[[vk::binding(2,0)]] RWStructuredBuffer<ParticleInstance> render_particles : register(u2,space0);
[[vk::binding(3,0)]] StructuredBuffer<ParticleSortItem> sorted_particles : register(t3,space0);
[[vk::binding(4,0)]] StructuredBuffer<ParticleAppearance> appearances : register(t4,space0);
[[vk::binding(5,0)]] StructuredBuffer<ParticleCurveKeyframe> curve_keyframes : register(t5,space0);
float normalized_age(ParticleSimState particle) {
    return particle.position_lifetime.w > 0.0001 ? clamp(particle.velocity_age.w/particle.position_lifetime.w,0.0,1.0) : 0;
}
float4 texture_sheet_uv_rect(ParticleSimState particle) {
    uint columns = max(uint(uniforms.texture_sheet.x),1u), rows = max(uint(uniforms.texture_sheet.y),1u);
    uint max_frames = max(columns*rows,1u);
    uint start_frame = min(uint(max(uniforms.texture_sheet_playback.y,0.0)),max_frames-1);
    uint frame_count = min(max(uint(uniforms.texture_sheet.z),1u),max_frames-start_frame);
    uint random_range = min(uint(max(uniforms.texture_sheet_playback.z,0.0)),frame_count-1);
    uint random_offset = random_range > 0 ? particle.params.z%(random_range+1) : 0;
    uint first_frame = min(frame_count-1,random_offset), mode = uint(max(uniforms.texture_sheet_playback.x,0.0));
    float play_once_rate = uniforms.texture_sheet.w > 0 ? uniforms.texture_sheet.w : float(frame_count);
    uint advanced_frame = 0;
    if (mode == 0) {
        advanced_frame = uniforms.texture_sheet.w > 0 ? uint(max(floor(max(particle.velocity_age.w,0.0)*uniforms.texture_sheet.w),0.0))
            : uint(max(floor(normalized_age(particle)*float(frame_count)),0.0));
    } else if (mode == 1) advanced_frame = uint(max(floor(normalized_age(particle)*float(frame_count)),0.0));
    else if (mode == 2 || mode == 3) advanced_frame = uint(max(floor(max(particle.velocity_age.w,0.0)*play_once_rate),0.0));
    uint frame_index;
    if (mode == 3) frame_index = start_frame+((first_frame+advanced_frame)%frame_count);
    else if (mode == 4) frame_index = start_frame+first_frame;
    else frame_index = start_frame+min(frame_count-1,first_frame+advanced_frame);
    uint column = frame_index%columns, row = frame_index/columns;
    float4 sheet_rect = float4(float(column)/float(columns),float(row)/float(rows),1.0/float(columns),1.0/float(rows));
    return float4(uniforms.uv_rect.xy+sheet_rect.xy*uniforms.uv_rect.zw,sheet_rect.zw*uniforms.uv_rect.zw);
}
float keyframe_curve_value(float offset,float count,float t) {
    uint keyframe_count = uint(max(count,0.0));
    if (keyframe_count == 0) return t;
    uint start = uint(max(offset,0.0));
    float4 previous = curve_keyframes[start].time_value;
    if (t <= previous.x) return previous.y;
    for (uint index = 1; index < keyframe_count; index++) {
        float4 current = curve_keyframes[start+index].time_value;
        if (t <= current.x) {
            float span = current.x-previous.x;
            if (span <= 0.0001) return current.y;
            return lerp(previous.y,current.y,(t-previous.x)/span);
        }
        previous = current;
    }
    return previous.y;
}
float curve_value(float mode,float constant_value,float offset,float count,float t) {
    if (mode < 0.5) return -1;
    if (mode < 1.5) return constant_value;
    if (mode < 2.5) return t;
    if (mode < 3.5) return t*t;
    if (mode < 4.5) return 1-(1-t)*(1-t);
    if (mode < 5.5) { float inv = -2*t+2; return t >= 0.5 ? 1-inv*inv*0.5 : 2*t*t; }
    return keyframe_curve_value(offset,count,t);
}
ParticleAppearance particle_appearance(ParticleSimState particle) {
    uint count = uint(max(uniforms.params.w,0.0));
    if (count == 0) { ParticleAppearance result = {uniforms.appearance_size,uniforms.appearance_start_color,uniforms.appearance_end_color}; return result; }
    uint index = particle.params.y;
    if (index >= count) index = count > 1 ? 1 : 0;
    return appearances[index];
}
float appearance_size(ParticleSimState particle,float t) {
    if (uniforms.appearance_color_curve.z < 0.5) return max(particle.size_rotation.x,0.0);
    ParticleAppearance appearance = particle_appearance(particle);
    float size_t = curve_value(uniforms.appearance_size.z,uniforms.appearance_size.w,uniforms.curve_keyframes.x,uniforms.curve_keyframes.y,t);
    if (size_t < 0) return max(particle.size_rotation.x,0.0);
    float size = lerp(max(appearance.size.x,0.0),max(appearance.size.y,0.0),size_t);
    return max(size*max(particle.size_rotation.w,0.0),0.0);
}
float4 appearance_color(ParticleSimState particle,float t) {
    if (uniforms.appearance_color_curve.z < 0.5) return particle.color;
    ParticleAppearance appearance = particle_appearance(particle);
    float color_t = curve_value(uniforms.appearance_color_curve.x,uniforms.appearance_color_curve.y,uniforms.curve_keyframes.z,uniforms.curve_keyframes.w,t);
    return color_t < 0 ? particle.color : lerp(appearance.start_color,appearance.end_color,color_t);
}
ParticleInstance empty_instance() {
    ParticleInstance instance = (ParticleInstance)0;
    instance.uvRect = uniforms.uv_rect; instance.axisStretch.w = 1; return instance;
}
[shader("compute")]
[numthreads(particleWorkgroupSize,1,1)]
void particleSimToInstance(uint3 gid : SV_DispatchThreadID) {
    uint output_index = gid.x, count = uint(uniforms.params.x), base_instance = uint(uniforms.params.y), start = uint(uniforms.params.z);
    uint trail_segments = uniforms.trail_params.y > 0 ? uint(uniforms.trail_params.x) : 0;
    uint multiplier = 1+trail_segments;
    if (output_index >= count*multiplier) return;
    uint local_index = output_index/multiplier, sorted_index = sorted_particles[local_index].index;
    uint segment = output_index%multiplier, output_instance = base_instance+output_index;
    // Padding sentinels must never become a storage-buffer address.
    if (sorted_index >= count) { render_particles[output_instance] = empty_instance(); return; }
    ParticleSimState particle = sim_particles[start+sorted_index];
    if (particle.position_lifetime.w <= 0 || particle.velocity_age.w >= particle.position_lifetime.w) {
        render_particles[output_instance] = empty_instance(); return;
    }
    float4 world_position = mul(uniforms.world_transform,float4(particle.position_lifetime.xyz,1));
    float3 world_velocity = mul(uniforms.world_transform,float4(particle.velocity_age.xyz,0)).xyz;
    float inv_w = abs(world_position.w) > 0.0001 ? 1/world_position.w : 1;
    float4 axis_stretch = float4(0,0,0,1);
    if (uniforms.render_params.x > 0.5) {
        float speed = length(world_velocity);
        if (speed > 0.0001) axis_stretch = float4(world_velocity/speed,min(max(uniforms.render_params.z,1.0),max(1.0,1+speed*max(uniforms.render_params.y,0.0))));
    }
    float trail_t = segment > 0 ? float(segment)/max(float(trail_segments),1.0) : 0;
    float3 trail_offset = world_velocity*uniforms.trail_params.y*trail_t;
    float trail_size_scale = lerp(1.0,max(uniforms.trail_params.z,0.0),trail_t);
    float trail_alpha_scale = lerp(1.0,clamp(uniforms.trail_params.w,0.0,1.0),trail_t);
    float t = normalized_age(particle);
    float4 color = appearance_color(particle,t);
    color.w *= clamp(uniforms.render_params.w,0.0,1.0)*trail_alpha_scale;
    float size = max(appearance_size(particle,t)*trail_size_scale,0.0);
    ParticleInstance instance;
    instance.positionSize = float4(world_position.xyz*inv_w-trail_offset,size);
    instance.rotation = float4(particle.size_rotation.y,0,0,0); instance.color = color;
    instance.uvRect = texture_sheet_uv_rect(particle); instance.axisStretch = axis_stretch;
    instance.ribbonColor = color; instance.ribbonParams = float4(size,size,0,0);
    render_particles[output_instance] = instance;
}
