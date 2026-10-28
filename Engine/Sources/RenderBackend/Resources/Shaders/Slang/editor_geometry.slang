struct OverlayInput {
    float4 position : TEXCOORD0;
    float4 color : TEXCOORD1;
    float4 barycentric : TEXCOORD2;
    float4 widths : TEXCOORD3;
    float4 edgeA : TEXCOORD4;
    float4 edgeB : TEXCOORD5;
    float4 edgeC : TEXCOORD6;
};
struct OverlayOutput {
    float4 position : SV_Position;
    float4 color : COLOR0;
    noperspective float4 barycentric : TEXCOORD0;
    nointerpolation float4 widths : TEXCOORD1;
    nointerpolation float4 edgeA : TEXCOORD2;
    nointerpolation float4 edgeB : TEXCOORD3;
    nointerpolation float4 edgeC : TEXCOORD4;
};
[shader("vertex")]
OverlayOutput overlayVertex(OverlayInput input) {
    OverlayOutput output;
    output.position = input.position;
    output.color = input.color;
    output.barycentric = input.barycentric;
    output.widths = input.widths;
    output.edgeA = input.edgeA;
    output.edgeB = input.edgeB;
    output.edgeC = input.edgeC;
    return output;
}
[shader("fragment")]
float4 overlayFragment(OverlayOutput input) : SV_Target0 {
    float3 distance = input.barycentric.xyz / max(fwidth(input.barycentric.xyz), 0.000001);
    float3 coverage = (1 - smoothstep(input.widths.xyz * 0.5 - 0.5, input.widths.xyz * 0.5 + 0.5, distance))
        * step(0.001, input.widths.xyz);
    float4 wire = input.edgeA;
    float amount = coverage.x;
    if (coverage.y > amount) { amount = coverage.y; wire = input.edgeB; }
    if (coverage.z > amount) { amount = coverage.z; wire = input.edgeC; }
    float alpha = wire.a * amount;
    float outputAlpha = alpha + input.color.a * (1 - alpha);
    if (outputAlpha < 0.001) discard;
    return float4((wire.rgb * alpha + input.color.rgb * input.color.a * (1-alpha)) / outputAlpha, outputAlpha);
}
