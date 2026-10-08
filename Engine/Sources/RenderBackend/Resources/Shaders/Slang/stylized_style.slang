struct StylizedStyle {
    float4 toonThresholds;
    float4 toonLevels;
    float4 inkWashColor;
    float4 params;
};
[[vk::binding(13,0)]] ConstantBuffer<StylizedStyle> style : register(b13, space0);
