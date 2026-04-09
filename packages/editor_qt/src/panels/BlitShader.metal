#include <metal_stdlib>
using namespace metal;

// Vertex shader data
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Vertex shader: full-screen quad
vertex VertexOut
vertexShader(uint vertexID [[vertex_id]]) {
    VertexOut out;
    
    // Generate full-screen quad vertices
    float2 positions[] = {
        {-1.0, -1.0},   // Bottom-left
        { 1.0, -1.0},   // Bottom-right
        {-1.0,  1.0},   // Top-left
        { 1.0,  1.0}    // Top-right
    };
    
    float2 texCoords[] = {
        {0.0, 1.0},
        {1.0, 1.0},
        {0.0, 0.0},
        {1.0, 0.0}
    };
    
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Fragment shader: sample IOSurface texture
fragment float4
fragmentShader(VertexOut in [[stage_in]],
               texture2d<float> diffuseTexture [[texture(0)]],
               sampler samplerState [[sampler(0)]]) {
    return diffuseTexture.sample(samplerState, in.texCoord);
}
