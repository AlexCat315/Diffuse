#include "DX12Internal.hpp"
#ifdef _WIN32
using namespace grhi;
static D3D12_SHADER_VISIBILITY visibility(uint32_t stage) {
    switch (stage) { case GRHI_STAGE_VERTEX: return D3D12_SHADER_VISIBILITY_VERTEX; case GRHI_STAGE_FRAGMENT: return D3D12_SHADER_VISIBILITY_PIXEL;
    case GRHI_STAGE_TASK: return D3D12_SHADER_VISIBILITY_AMPLIFICATION; case GRHI_STAGE_MESH: return D3D12_SHADER_VISIBILITY_MESH; default: return D3D12_SHADER_VISIBILITY_ALL; }
}
int32_t grhi_dx12_binding_layout(GRHI_DX12Device* d, uint32_t id, const GRHI_BindingDecl* values, size_t count) { return run(d, [&](State& s) {
    std::vector<GRHI_BindingDecl> entries; if (count) entries.assign(values, values + count); s.bindingLayouts[id] = std::move(entries); }); }
int32_t grhi_dx12_pipeline_layout(GRHI_DX12Device* d, uint32_t id, const uint32_t* sets, size_t count, const GRHI_ConstantDecl* constants, size_t constantCount) { return run(d, [&](State& s) {
    Layout layout; if (count) layout.sets.assign(sets, sets + count);
    std::vector<D3D12_ROOT_PARAMETER> params; std::vector<D3D12_DESCRIPTOR_RANGE> ranges;
    size_t declarations = constantCount; for (size_t i = 0; i < count; ++i) declarations += s.bindingLayouts.at(sets[i]).size();
    params.reserve(declarations); ranges.reserve(declarations);
    for (uint32_t set = 0; set < count; ++set) for (auto entry : s.bindingLayouts.at(sets[set])) {
        D3D12_ROOT_PARAMETER param{}; param.ShaderVisibility = entry.stages && !(entry.stages & (entry.stages - 1)) ? visibility(entry.stages == 1 ? 0 : entry.stages == 2 ? 1 : entry.stages == 4 ? 2 : entry.stages == 8 ? 3 : 4) : D3D12_SHADER_VISIBILITY_ALL;
        if (entry.type == GRHI_BIND_UNIFORM || entry.type == GRHI_BIND_STORAGE || entry.type == GRHI_BIND_AS) {
            param.ParameterType = entry.type == GRHI_BIND_UNIFORM ? D3D12_ROOT_PARAMETER_TYPE_CBV : entry.type == GRHI_BIND_STORAGE && !entry.read_only ? D3D12_ROOT_PARAMETER_TYPE_UAV : D3D12_ROOT_PARAMETER_TYPE_SRV;
            param.Descriptor.ShaderRegister = entry.slot; param.Descriptor.RegisterSpace = set;
        } else {
            D3D12_DESCRIPTOR_RANGE range{}; range.NumDescriptors = 1; range.BaseShaderRegister = entry.slot; range.RegisterSpace = set;
            range.RangeType = entry.type == GRHI_BIND_SAMPLER ? D3D12_DESCRIPTOR_RANGE_TYPE_SAMPLER : entry.type == GRHI_BIND_STORAGE_TEXTURE ? D3D12_DESCRIPTOR_RANGE_TYPE_UAV : D3D12_DESCRIPTOR_RANGE_TYPE_SRV;
            ranges.push_back(range); param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE; param.DescriptorTable.NumDescriptorRanges = 1; param.DescriptorTable.pDescriptorRanges = &ranges.back();
        }
        layout.roots[{set, entry.slot}] = {UINT(params.size()), uint32_t(param.ParameterType), entry.stages}; params.push_back(param);
    }
    for (size_t i = 0; i < constantCount; ++i) {
        auto c = constants[i]; require(c.bytes && c.bytes % 4 == 0, "root constants must be aligned");
        for (auto p : params) require(!(p.ParameterType == D3D12_ROOT_PARAMETER_TYPE_CBV && p.Descriptor.RegisterSpace == 0 && p.Descriptor.ShaderRegister == c.slot), "push constants overlap a uniform binding");
        D3D12_ROOT_PARAMETER param{}; param.ParameterType = D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS; param.ShaderVisibility = visibility(c.stage);
        param.Constants = {c.slot, 0, c.bytes / 4}; layout.constants[c.slot] = {{UINT(params.size()), uint32_t(param.ParameterType), c.stage}, c.bytes}; params.push_back(param);
    }
    D3D12_ROOT_SIGNATURE_DESC desc{}; desc.NumParameters = UINT(params.size()); desc.pParameters = params.data(); desc.Flags = D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT;
    ComPtr<ID3DBlob> blob, errors; auto hr = D3D12SerializeRootSignature(&desc, D3D_ROOT_SIGNATURE_VERSION_1, &blob, &errors);
    if (FAILED(hr) && errors) throw std::runtime_error(std::string((char*)errors->GetBufferPointer(), errors->GetBufferSize())); check(hr, "D3D12SerializeRootSignature");
    check(s.device->CreateRootSignature(0, blob->GetBufferPointer(), blob->GetBufferSize(), IID_PPV_ARGS(&layout.native)), "CreateRootSignature"); s.layouts.emplace(id, std::move(layout)); }); }
int32_t grhi_dx12_binding_set(GRHI_DX12Device* d, uint32_t id, uint32_t layout, const GRHI_BindingValue* values, size_t count) { return run(d, [&](State& s) {
    BindingSet set{layout, {}, {}}; if (count) set.values.assign(values, values + count);
    auto& declarations = s.bindingLayouts.at(layout); require(count == declarations.size(), "binding set size differs from layout");
    try {
        for (auto entry : set.values) {
            auto declaration = std::find_if(declarations.begin(), declarations.end(), [&](auto x) { return x.slot == entry.slot && x.type == entry.type; }); require(declaration != declarations.end(), "binding type mismatch");
            if (entry.type == GRHI_BIND_UNIFORM || entry.type == GRHI_BIND_STORAGE) {
                auto& buffer = s.buffers.at(entry.resource); require(entry.offset < buffer.size, "binding offset out of bounds");
                require(entry.offset % (entry.type == GRHI_BIND_UNIFORM ? 256 : 4) == 0, "unaligned root buffer descriptor"); continue;
            }
            if (entry.type == GRHI_BIND_AS) { s.acceleration.at(entry.resource); continue; }
            Heap& heap = entry.type == GRHI_BIND_SAMPLER ? s.samplers : s.views; UINT index = heap.allocate(); set.descriptors[entry.slot] = index;
            if (entry.type == GRHI_BIND_SAMPLER) { s.device->CreateSampler(&s.samplerValues.at(entry.resource), heap.cpu(index)); continue; }
            auto& texture = s.textures.at(entry.resource); auto& t = texture.texture;
            if (entry.type == GRHI_BIND_STORAGE_TEXTURE) {
                require(t.usage & (1 << 4), "storage texture lacks write usage"); D3D12_UNORDERED_ACCESS_VIEW_DESC view{}; view.Format = format(t.format);
                if (t.dimension == 1) { view.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE3D; view.Texture3D.WSize = t.depth; }
                else if (t.dimension == 2 || t.dimension == 3) { view.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2DARRAY; view.Texture2DArray.ArraySize = t.dimension == 2 ? 6 : t.layers; }
                else view.ViewDimension = D3D12_UAV_DIMENSION_TEXTURE2D;
                s.device->CreateUnorderedAccessView(texture.native.Get(), nullptr, &view, heap.cpu(index));
            } else {
                D3D12_SHADER_RESOURCE_VIEW_DESC view{}; view.Shader4ComponentMapping = D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; view.Format = t.format == GRHI_FORMAT_DEPTH32 ? DXGI_FORMAT_R32_FLOAT : t.format >= GRHI_FORMAT_DEPTH24 ? DXGI_FORMAT_R24_UNORM_X8_TYPELESS : format(t.format);
                if (t.dimension == 1) { view.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE3D; view.Texture3D.MipLevels = t.mips; }
                else if (t.dimension == 2) { view.ViewDimension = D3D12_SRV_DIMENSION_TEXTURECUBE; view.TextureCube.MipLevels = t.mips; }
                else if (t.dimension == 3) { view.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2DARRAY; view.Texture2DArray.MipLevels = t.mips; view.Texture2DArray.ArraySize = t.layers; }
                else { view.ViewDimension = D3D12_SRV_DIMENSION_TEXTURE2D; view.Texture2D.MipLevels = t.mips; }
                s.device->CreateShaderResourceView(texture.native.Get(), &view, heap.cpu(index));
            }
        }
    } catch (...) { for (auto v : set.values) { auto p = set.descriptors.find(v.slot); if (p != set.descriptors.end()) (v.type == GRHI_BIND_SAMPLER ? s.samplers : s.views).free.push_back(p->second); } throw; }
    s.sets.emplace(id, std::move(set)); }); }
#endif
