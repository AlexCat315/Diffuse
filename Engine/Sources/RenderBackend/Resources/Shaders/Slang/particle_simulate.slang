#include "particle_simulation_common.slang"
struct ParticleSimUniforms {
    float4 time; float4 gravity; float4 noise;
    float4 vector_field_direction_strength; float4 vector_field_params;
    float4 force_center_radius; float4 force_axis_mode; float4 force_params;
    float4 collision_params;
    column_major float4x4 collision_to_world;
    column_major float4x4 collision_to_local;
};
struct CollisionResult { float3 position; float3 velocity; bool collided; };
[[vk::binding(0,0)]] ConstantBuffer<ParticleSimUniforms> uniforms : register(b0,space0);
[[vk::binding(1,0)]] RWStructuredBuffer<ParticleSimState> particles : register(u1,space0);
[[vk::binding(2,0)]] RWStructuredBuffer<ParticleSimMetadata> metadata : register(u2,space0);
[[vk::binding(3,0)]] RWStructuredBuffer<ParticleSimEvent> events : register(u3,space0);
void record_event(uint trigger,uint index,float3 position,float lifetime,float3 velocity,float age,uint generation,uint appearance) {
    uint eventIndex; InterlockedAdd(metadata[0].event_count,1,eventIndex);
    if (eventIndex >= uint(max(uniforms.time.w,0.0))) return;
    ParticleSimEvent event;
    event.position_lifetime = float4(position,lifetime); event.velocity_age = float4(velocity,age);
    event.params = uint4(trigger,index,generation,appearance); events[eventIndex] = event;
}
float3 safe_normalize(float3 value,float3 fallback) {
    float lengthSquared = dot(value,value);
    return lengthSquared <= 0.000001 ? fallback : value*rsqrt(lengthSquared);
}
float3 noise_acceleration(float3 position,float age) {
    float strength = uniforms.noise.x;
    if (strength <= 0) return 0;
    float3 p = position*max(uniforms.noise.y,0.0001);
    float phase = age*max(uniforms.noise.z,0.0)+uniforms.noise.w;
    return float3(sin(p.x*12.9898+p.y*78.233+p.z*37.719+phase),
        sin(p.y*26.651+p.z*91.191+p.x*13.153+phase+2.17),
        sin(p.z*54.123+p.x*44.531+p.y*9.151+phase+4.31))*strength;
}
float3 curl_field(float3 position,float age) {
    float3 p = position*max(uniforms.vector_field_params.x,0.0001);
    float phase = age*uniforms.vector_field_params.y+uniforms.time.z;
    float3 bias = safe_normalize(uniforms.vector_field_direction_strength.xyz,float3(0,1,0));
    float3 field = float3(sin(p.y*8.173+p.z*3.117+phase)-sin(p.z*5.731+p.x*7.191-phase),
        sin(p.z*6.313+p.x*4.997+phase+1.37)-sin(p.x*9.239+p.y*2.173-phase),
        sin(p.x*4.113+p.y*7.911+phase+2.71)-sin(p.y*5.337+p.z*6.771-phase));
    return safe_normalize(field+bias*0.25,bias);
}
float3 vector_field_acceleration(float3 position,float age) {
    float strength = uniforms.vector_field_direction_strength.w;
    float mode = uniforms.vector_field_params.z;
    if (strength == 0 || mode < 0.5) return 0;
    float3 direction = safe_normalize(uniforms.vector_field_direction_strength.xyz,float3(0,1,0));
    return (mode < 1.5 ? direction : curl_field(position,age))*strength;
}
float3 force_acceleration(float3 position) {
    float mode = uniforms.force_axis_mode.w, strength = uniforms.force_params.x;
    if (mode < 0.5 || strength == 0) return 0;
    float radius = max(uniforms.force_center_radius.w,0.0);
    float3 offset = position-uniforms.force_center_radius.xyz;
    float distance = length(offset);
    if (radius > 0 && distance >= radius) return 0;
    float attenuation = radius > 0 ? pow(max(0.0,1-distance/radius),max(uniforms.force_params.y,0.0)) : 1;
    if (attenuation <= 0) return 0;
    if (mode < 1.5) return distance <= 0.0001 ? float3(0) : (offset/distance)*strength*attenuation;
    float3 axis = safe_normalize(uniforms.force_axis_mode.xyz,float3(0,1,0));
    float3 planar = offset-axis*dot(offset,axis);
    float planarDistance = length(planar);
    if (planarDistance <= 0.0001) return 0;
    float3 tangent = safe_normalize(cross(axis,planar/planarDistance),float3(0,0,1));
    return tangent*strength*attenuation;
}
CollisionResult particle_collision(float3 position,float3 velocity) {
    CollisionResult result = {position,velocity,false};
    float mode = uniforms.collision_params.x;
    if (mode < 0.5) return result;
    float planeY = uniforms.collision_params.y, restitution = clamp(uniforms.collision_params.z,0.0,1.0);
    float tangentScale = 1-clamp(uniforms.collision_params.w,0.0,1.0);
    if (mode < 1.5) {
        if (position.y < planeY) {
            result.position.y = planeY; result.collided = true;
            if (velocity.y < 0) result.velocity = float3(velocity.x*tangentScale,-velocity.y*restitution,velocity.z*tangentScale);
        }
        return result;
    }
    float4 worldPosition = mul(uniforms.collision_to_world,float4(position,1));
    if (worldPosition.y < planeY) {
        result.collided = true; worldPosition.y = planeY;
        float4 localPosition = mul(uniforms.collision_to_local,worldPosition);
        result.position = abs(localPosition.w) > 0.0001 ? localPosition.xyz/localPosition.w : localPosition.xyz;
        float4 worldVelocity = mul(uniforms.collision_to_world,float4(velocity,0));
        if (worldVelocity.y < 0) result.velocity = mul(uniforms.collision_to_local,
            float4(worldVelocity.x*tangentScale,-worldVelocity.y*restitution,worldVelocity.z*tangentScale,0)).xyz;
    }
    return result;
}
[shader("compute")]
[numthreads(particleWorkgroupSize,1,1)]
void particleSimulate(uint3 gid : SV_DispatchThreadID) {
    uint index = gid.x, ignored;
    if (index >= uint(uniforms.time.y)) return;
    ParticleSimState particle = particles[index];
    float3 position = particle.position_lifetime.xyz, velocity = particle.velocity_age.xyz;
    float lifetime = particle.position_lifetime.w, age = particle.velocity_age.w;
    if (lifetime <= 0) return;
    if (age >= lifetime) {
        InterlockedAdd(metadata[0].expired_count,1,ignored);
        record_event(2,index,position,lifetime,velocity,age,particle.params.x,particle.params.y); return;
    }
    float dt = max(uniforms.time.x,0.0);
    float3 noise = noise_acceleration(position,age), field = vector_field_acceleration(position,age), force = force_acceleration(position);
    velocity += (uniforms.gravity.xyz+noise+force+field)*dt;
    position += velocity*dt;
    CollisionResult collision = particle_collision(position,velocity);
    position = collision.position; velocity = collision.velocity;
    if (collision.collided) {
        InterlockedAdd(metadata[0].collision_count,1,ignored);
        record_event(1,index,position,lifetime,velocity,age,particle.params.x,particle.params.y);
    }
    age = min(age+dt,lifetime);
    particle.position_lifetime = float4(position,lifetime); particle.velocity_age = float4(velocity,age);
    particle.size_rotation.y += particle.size_rotation.z*dt; particles[index] = particle;
    if (age < lifetime) InterlockedAdd(metadata[0].alive_count,1,ignored);
    else { InterlockedAdd(metadata[0].expired_count,1,ignored); record_event(2,index,position,lifetime,velocity,age,particle.params.x,particle.params.y); }
}
