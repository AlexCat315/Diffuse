#include "DX12Internal.hpp"
#ifdef _WIN32
using namespace grhi;
static D3D12_BLEND blend(uint32_t b) {
    static const D3D12_BLEND values[] = {D3D12_BLEND_ZERO,D3D12_BLEND_ONE,D3D12_BLEND_SRC_COLOR,D3D12_BLEND_INV_SRC_COLOR,D3D12_BLEND_DEST_COLOR,D3D12_BLEND_INV_DEST_COLOR,D3D12_BLEND_SRC_ALPHA,D3D12_BLEND_INV_SRC_ALPHA,D3D12_BLEND_DEST_ALPHA,D3D12_BLEND_INV_DEST_ALPHA,D3D12_BLEND_BLEND_FACTOR,D3D12_BLEND_INV_BLEND_FACTOR,D3D12_BLEND_SRC_ALPHA_SAT};
    require(b < 13, "invalid blend factor"); return values[b];
}
static D3D12_PRIMITIVE_TOPOLOGY_TYPE topologyType(uint32_t p) { return p < 2 ? D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE : p < 4 ? D3D12_PRIMITIVE_TOPOLOGY_TYPE_LINE : D3D12_PRIMITIVE_TOPOLOGY_TYPE_POINT; }
template<D3D12_PIPELINE_STATE_SUBOBJECT_TYPE Type, typename Value> struct alignas(void*) Subobject { D3D12_PIPELINE_STATE_SUBOBJECT_TYPE type = Type; Value value{}; };
struct MeshStream {
    Subobject<D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_ROOT_SIGNATURE,ID3D12RootSignature*> root;
    Subobject<D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_AS,D3D12_SHADER_BYTECODE> task;
    Subobject<D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_MS,D3D12_SHADER_BYTECODE> mesh;
    Subobject<D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PS,D3D12_SHADER_BYTECODE> fragment;
    Subobject<D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_BLEND,D3D12_BLEND_DESC> blend;
    Subobject<D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RASTERIZER,D3D12_RASTERIZER_DESC> raster;
    Subobject<D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL,D3D12_DEPTH_STENCIL_DESC> depth;
    Subobject<D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_PRIMITIVE_TOPOLOGY,D3D12_PRIMITIVE_TOPOLOGY_TYPE> topology;
    Subobject<D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_RENDER_TARGET_FORMATS,D3D12_RT_FORMAT_ARRAY> formats;
    Subobject<D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_DEPTH_STENCIL_FORMAT,DXGI_FORMAT> depthFormat;
    Subobject<D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_SAMPLE_DESC,DXGI_SAMPLE_DESC> sample;
    Subobject<D3D12_PIPELINE_STATE_SUBOBJECT_TYPE_SAMPLE_MASK,UINT> mask;
};
void grhi::graphicsPipeline(State& s, uint32_t id, const GRHI_GraphicsDesc& d) {
    require(d.color_count <= 8, "too many render targets"); auto& layout = s.layouts.at(d.layout);
    Pipeline result; result.layout = d.layout; result.raster = d.raster; result.mesh = d.mesh != 0;
    D3D12_GRAPHICS_PIPELINE_STATE_DESC native{}; native.pRootSignature = layout.native.Get(); native.SampleMask = UINT_MAX; native.SampleDesc.Count = 1;
    native.PrimitiveTopologyType = topologyType(d.raster.primitive);
    native.RasterizerState.FillMode = d.raster.fill ? D3D12_FILL_MODE_WIREFRAME : D3D12_FILL_MODE_SOLID;
    native.RasterizerState.CullMode = d.raster.cull == 0 ? D3D12_CULL_MODE_NONE : d.raster.cull == 1 ? D3D12_CULL_MODE_FRONT : D3D12_CULL_MODE_BACK;
    native.RasterizerState.FrontCounterClockwise = d.raster.winding != 0; native.RasterizerState.DepthClipEnable = TRUE;
    native.DepthStencilState.DepthEnable = d.depth.enabled; native.DepthStencilState.DepthWriteMask = d.depth.write ? D3D12_DEPTH_WRITE_MASK_ALL : D3D12_DEPTH_WRITE_MASK_ZERO; native.DepthStencilState.DepthFunc = D3D12_COMPARISON_FUNC(d.depth.compare + 1);
    native.DepthStencilState.StencilReadMask = native.DepthStencilState.StencilWriteMask = 0xff;
    D3D12_DEPTH_STENCILOP_DESC face{D3D12_STENCIL_OP_KEEP,D3D12_STENCIL_OP_KEEP,D3D12_STENCIL_OP_KEEP,D3D12_COMPARISON_FUNC_ALWAYS}; native.DepthStencilState.FrontFace = native.DepthStencilState.BackFace = face;
    native.DSVFormat = format(d.depth.format); result.depth = native.DSVFormat;
    native.NumRenderTargets = d.color_count; native.BlendState.IndependentBlendEnable = TRUE;
    for (UINT i = 0; i < d.color_count; ++i) { auto c = d.colors[i]; native.RTVFormats[i] = format(c.format); result.colors.push_back(native.RTVFormats[i]); auto& b = native.BlendState.RenderTarget[i];
        b.BlendEnable = c.enabled; b.SrcBlend = blend(c.source_rgb); b.DestBlend = blend(c.destination_rgb); b.BlendOp = D3D12_BLEND_OP(c.operation_rgb + 1);
        b.SrcBlendAlpha = blend(c.source_alpha); b.DestBlendAlpha = blend(c.destination_alpha); b.BlendOpAlpha = D3D12_BLEND_OP(c.operation_alpha + 1); b.RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL; }
    if (d.fragment) { auto& shader = s.shaders.at(d.fragment); require(shader.stage == GRHI_STAGE_FRAGMENT, "fragment stage mismatch"); native.PS = shader.code(); }
    if (d.mesh) {
        require(s.capabilities.mesh, "mesh shaders unsupported"); auto& shader = s.shaders.at(d.mesh); require(shader.stage == GRHI_STAGE_MESH, "mesh stage mismatch");
        MeshStream stream; stream.root.value = native.pRootSignature; stream.mesh.value = shader.code(); stream.fragment.value = native.PS;
        if (d.task) { auto& task = s.shaders.at(d.task); require(task.stage == GRHI_STAGE_TASK, "task stage mismatch"); stream.task.value = task.code(); }
        stream.blend.value = native.BlendState; stream.raster.value = native.RasterizerState; stream.depth.value = native.DepthStencilState; stream.topology.value = native.PrimitiveTopologyType;
        stream.formats.value.NumRenderTargets = native.NumRenderTargets; memcpy(stream.formats.value.RTFormats, native.RTVFormats, sizeof(native.RTVFormats)); stream.depthFormat.value = native.DSVFormat; stream.sample.value = native.SampleDesc; stream.mask.value = UINT_MAX;
        D3D12_PIPELINE_STATE_STREAM_DESC info{sizeof(stream), &stream}; check(s.device->CreatePipelineState(&info, IID_PPV_ARGS(&result.native)), "CreatePipelineState mesh"); s.mesh.emplace(id, std::move(result)); return;
    }
    auto& shader = s.shaders.at(d.vertex); require(shader.stage == GRHI_STAGE_VERTEX, "vertex stage mismatch"); native.VS = shader.code();
    std::vector<D3D12_INPUT_ELEMENT_DESC> attributes;
    for (UINT i = 0; i < d.vertex_buffer_count; ++i) result.strides.push_back(d.vertex_buffers[i].stride);
    for (UINT i = 0; i < d.attribute_count; ++i) { auto a = d.attributes[i]; require(a.buffer < d.vertex_buffer_count && a.format < 3 && a.semantic, "invalid vertex attribute");
        static const DXGI_FORMAT formats[] = {DXGI_FORMAT_R32G32_FLOAT,DXGI_FORMAT_R32G32B32_FLOAT,DXGI_FORMAT_R32G32B32A32_FLOAT}; bool instance = d.vertex_buffers[a.buffer].per_instance;
        attributes.push_back({a.semantic,a.semantic_index,formats[a.format],a.buffer,a.offset,instance ? D3D12_INPUT_CLASSIFICATION_PER_INSTANCE_DATA : D3D12_INPUT_CLASSIFICATION_PER_VERTEX_DATA,instance ? 1u : 0u}); }
    native.InputLayout = {attributes.data(), UINT(attributes.size())}; check(s.device->CreateGraphicsPipelineState(&native, IID_PPV_ARGS(&result.native)), "CreateGraphicsPipelineState"); s.graphics.emplace(id, std::move(result));
}
int32_t grhi_dx12_graphics_pipeline(GRHI_DX12Device* d, uint32_t id, const GRHI_GraphicsDesc* desc) { return run(d, [&](State& s) { graphicsPipeline(s, id, *desc); }); }
int32_t grhi_dx12_compute_pipeline(GRHI_DX12Device* d, uint32_t id, uint32_t layout, uint32_t shaderID) { return run(d, [&](State& s) {
    auto& shader = s.shaders.at(shaderID); require(shader.stage == GRHI_STAGE_COMPUTE, "compute stage mismatch"); Pipeline pipeline; pipeline.layout = layout; pipeline.compute = true;
    D3D12_COMPUTE_PIPELINE_STATE_DESC desc{}; desc.pRootSignature = s.layouts.at(layout).native.Get(); desc.CS = shader.code();
    check(s.device->CreateComputePipelineState(&desc, IID_PPV_ARGS(&pipeline.native)), "CreateComputePipelineState"); s.compute.emplace(id, std::move(pipeline)); }); }
#endif
