struct Vertex { float4 position : SV_Position; };
[shader("mesh")]
[numthreads(3, 1, 1)]
[outputtopology("triangle")]
void meshMain(uint tid : SV_GroupIndex, out vertices Vertex verts[3], out indices uint3 tris[1]) {
 SetMeshOutputCounts(3, 1);
 float2 p[3] = {float2(-1,-1), float2(1,-1), float2(0,1)};
 Vertex v; v.position = float4(p[tid], 0, 1); verts[tid] = v;
 if (tid == 0) tris[0] = uint3(0,1,2);
}
[shader("fragment")]
float4 fragmentMain() : SV_Target { return float4(0,1,0,1); }
