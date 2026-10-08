struct GridUniforms {
    column_major float4x4 inverseRelativeViewProjection;
    column_major float4x4 relativeViewProjection;
    float4 cameraPosition;
    float4 viewport;
    float4 planeU;
    float4 planeV;
};
[[vk::binding(0, 0)]] ConstantBuffer<GridUniforms> grid : register(b0, space0);

[shader("vertex")]
float4 gridVertex(uint index : SV_VertexID) : SV_Position {
    float2 positions[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)};
    return float4(positions[index], 0, 1);
}

float gridLine(float2 position, float2 footprint, float spacing, float width) {
    float2 distance = abs(frac(position / spacing + 0.5) - 0.5) * spacing;
    float2 coverage = 1 - smoothstep(width * 0.5 - 0.5, width * 0.5 + 0.5, distance / footprint);
    float2 fade = 1 - smoothstep(0.25, 0.75, footprint / spacing);
    return max(coverage.x * fade.x, coverage.y * fade.y);
}

float gridLevels(float2 position, float2 footprint, float spacing, float transition, float width) {
    float minor = gridLine(position, footprint, spacing, width) * 0.40 * (1 - transition);
    float major = gridLine(position, footprint, spacing * 10, width) * lerp(0.65, 0.40, transition);
    float coarse = gridLine(position, footprint, spacing * 100, width) * 0.65 * transition;
    return max(minor, max(major, coarse));
}

float3 axisColor(float axis) {
    if (axis < 0.5) return float3(0.95, 0.27, 0.34);
    if (axis < 1.5) return float3(0.36, 0.86, 0.41);
    return float3(0.18, 0.36, 1);
}

struct GridFragment {
    float4 color : SV_Target0;
    float depth : SV_Depth;
};

[shader("fragment")]
GridFragment gridFragment(float4 pixel : SV_Position) {
    float2 ndc = float2(pixel.x / grid.viewport.x * 2 - 1, 1 - pixel.y / grid.viewport.y * 2);
    float4 nearH = mul(grid.inverseRelativeViewProjection, float4(ndc, 0, 1));
    float4 farH = mul(grid.inverseRelativeViewProjection, float4(ndc, 0.5, 1));
    float3 nearPoint = nearH.xyz / nearH.w;
    float3 farPoint = farH.xyz / farH.w;
    float3 ray = farPoint - nearPoint;
    float3 normal = cross(grid.planeU.xyz, grid.planeV.xyz);
    float denominator = dot(ray, normal);
    float safeDenominator = denominator >= 0 ? max(abs(denominator), 0.00001) : -max(abs(denominator), 0.00001);
    float t = -dot(grid.cameraPosition.xyz + nearPoint, normal) / safeDenominator;
    float3 relativeWorld = nearPoint + ray * t;
    float3 world = grid.cameraPosition.xyz + relativeWorld;
    float4 clip = mul(grid.relativeViewProjection, float4(relativeWorld, 1));
    float depth = clip.z / clip.w;
    float2 coordinates = float2(dot(world, grid.planeU.xyz), dot(world, grid.planeV.xyz));
    // Derivatives must precede divergent discard, including at the horizon.
    float2 dx = ddx(coordinates), dy = ddy(coordinates);
    float2 footprint = max(sqrt(dx * dx + dy * dy), 0.00001);
    float lod = log2(max(max(footprint.x, footprint.y) * 8 / grid.viewport.z, 1)) / log2(10.0);
    float spacing = grid.viewport.z * pow(10.0, floor(lod));
    float transition = smoothstep(0.0, 1.0, frac(lod));
    float lines = gridLevels(coordinates, footprint, spacing, transition, 1.25);
    float outline = gridLevels(coordinates, footprint, spacing, transition, 2.75);
    float3 dark = float3(0.04, 0.05, 0.07);
    float3 color = lerp(dark, float3(0.66, 0.70, 0.78), lines / max(outline, 0.00001));
    float alpha = outline;
    float2 axisDistance = abs(coordinates) / footprint;
    float uAxis = 1 - smoothstep(0.5, 1.5, axisDistance.y);
    float vAxis = 1 - smoothstep(0.5, 1.5, axisDistance.x);
    float axisOutline = 1 - smoothstep(1.5, 2.5, min(axisDistance.x, axisDistance.y));
    color = lerp(color, dark, axisOutline);
    color = lerp(color, axisColor(grid.planeU.w), uAxis);
    color = lerp(color, axisColor(grid.planeV.w), vAxis);
    alpha = max(alpha, axisOutline * 0.95);
    alpha *= smoothstep(0.001, 0.01, abs(dot(normalize(ray), normal)));
    if (abs(denominator) < 0.00001 || t <= 0 || clip.w <= 0 || depth < 0 || alpha < 0.001) discard;
    GridFragment output;
    output.color = float4(color, alpha);
    output.depth = min(depth, 1.0);
    return output;
}
