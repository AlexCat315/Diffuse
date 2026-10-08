#include "DX12Internal.hpp"
#ifdef _WIN32
using namespace grhi;
static thread_local std::string initializationError;
void grhi::waitFence(ID3D12Fence* fence, uint64_t value) {
    if (fence->GetCompletedValue() == UINT64_MAX) throw std::runtime_error("D3D12 device removed");
    if (fence->GetCompletedValue() >= value) return;
    HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    require(event != nullptr, "CreateEvent failed");
    HRESULT hr = fence->SetEventOnCompletion(value, event);
    if (FAILED(hr)) { CloseHandle(event); check(hr, "SetEventOnCompletion"); }
    auto result = WaitForSingleObject(event, INFINITE); CloseHandle(event);
    require(result == WAIT_OBJECT_0 && fence->GetCompletedValue() != UINT64_MAX, "GPU fence wait failed");
}
void State::idle() { for (auto& q : queues) if (q.native) { check(q.native->Signal(q.fence.Get(), ++q.value), "idle signal"); waitFence(q.fence.Get(), q.value); } }
State::~State() { try { idle(); } catch (...) {} }
void grhi::makeHeap(State& s, Heap& heap, D3D12_DESCRIPTOR_HEAP_TYPE type, UINT capacity, bool visible) {
    D3D12_DESCRIPTOR_HEAP_DESC desc{}; desc.Type = type; desc.NumDescriptors = capacity;
    desc.Flags = visible ? D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE : D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
    check(s.device->CreateDescriptorHeap(&desc, IID_PPV_ARGS(&heap.native)), "CreateDescriptorHeap");
    heap.stride = s.device->GetDescriptorHandleIncrementSize(type); heap.capacity = capacity;
}
Resource grhi::makeBuffer(State& s, uint64_t size, D3D12_HEAP_TYPE heap, D3D12_RESOURCE_FLAGS flags, D3D12_RESOURCE_STATES state) {
    require(size > 0, "empty buffer"); Resource result; result.size = size; result.state = state;
    D3D12_HEAP_PROPERTIES props{}; props.Type = heap;
    D3D12_RESOURCE_DESC desc{}; desc.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER; desc.Width = size;
    desc.Height = 1; desc.DepthOrArraySize = 1; desc.MipLevels = 1; desc.SampleDesc.Count = 1;
    desc.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR; desc.Flags = flags;
    check(s.device->CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &desc, state, nullptr, IID_PPV_ARGS(&result.native)), "CreateCommittedResource buffer");
    return result;
}
ComPtr<ID3D12Fence>& grhi::timeline(State& s, uint32_t id) {
    auto& result = s.timelines[id]; if (!result) check(s.device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&result)), "timeline fence"); return result;
}
GRHI_DX12Device* grhi_dx12_create(uint32_t validation, uint32_t lowPower) {
    try {
        auto s = std::make_shared<State>(); UINT flags = 0;
        if (validation) { ComPtr<ID3D12Debug> debug; check(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)), "D3D12 debug layer (install Graphics Tools)"); debug->EnableDebugLayer(); flags = DXGI_CREATE_FACTORY_DEBUG; }
        check(CreateDXGIFactory2(flags, IID_PPV_ARGS(&s->factory)), "CreateDXGIFactory2");
        for (UINT i = 0;; ++i) {
            ComPtr<IDXGIAdapter1> adapter;
            auto hr = s->factory->EnumAdapterByGpuPreference(i, lowPower ? DXGI_GPU_PREFERENCE_MINIMUM_POWER : DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE, IID_PPV_ARGS(&adapter));
            if (hr == DXGI_ERROR_NOT_FOUND) break; check(hr, "EnumAdapterByGpuPreference");
            DXGI_ADAPTER_DESC1 info{}; adapter->GetDesc1(&info); if (info.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) continue;
            if (SUCCEEDED(D3D12CreateDevice(adapter.Get(), D3D_FEATURE_LEVEL_12_0, IID_PPV_ARGS(&s->device)))) {
                int bytes = WideCharToMultiByte(CP_UTF8, 0, info.Description, -1, nullptr, 0, nullptr, nullptr);
                std::vector<char> name(bytes); WideCharToMultiByte(CP_UTF8, 0, info.Description, -1, name.data(), bytes, nullptr, nullptr); s->name = name.data(); break;
            }
        }
        require(bool(s->device), "no D3D12 hardware adapter with feature level 12_0");
        D3D12_FEATURE_DATA_SHADER_MODEL shaderModel{D3D_SHADER_MODEL_6_6};
        check(s->device->CheckFeatureSupport(D3D12_FEATURE_SHADER_MODEL, &shaderModel, sizeof(shaderModel)), "shader model query");
        require(shaderModel.HighestShaderModel >= D3D_SHADER_MODEL_6_6, "Slang DXIL artifacts require shader model 6_6");
        D3D12_FEATURE_DATA_D3D12_OPTIONS5 rt{};
        if (SUCCEEDED(s->device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS5, &rt, sizeof(rt)))) s->capabilities.ray_tier = rt.RaytracingTier >= D3D12_RAYTRACING_TIER_1_1 ? 11 : rt.RaytracingTier >= D3D12_RAYTRACING_TIER_1_0 ? 10 : 0;
        D3D12_FEATURE_DATA_D3D12_OPTIONS7 mesh{};
        if (SUCCEEDED(s->device->CheckFeatureSupport(D3D12_FEATURE_D3D12_OPTIONS7, &mesh, sizeof(mesh)))) s->capabilities.mesh = s->capabilities.task = mesh.MeshShaderTier != D3D12_MESH_SHADER_TIER_NOT_SUPPORTED;
        for (UINT i = 0; i < 3; ++i) { D3D12_COMMAND_QUEUE_DESC desc{}; desc.Type = queueType(i);
            check(s->device->CreateCommandQueue(&desc, IID_PPV_ARGS(&s->queues[i].native)), "CreateCommandQueue");
            check(s->device->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&s->queues[i].fence)), "CreateFence"); }
        makeHeap(*s, s->views, D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV, 65536, true);
        makeHeap(*s, s->samplers, D3D12_DESCRIPTOR_HEAP_TYPE_SAMPLER, 2048, true);
        makeHeap(*s, s->rtvs, D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 4096, false);
        makeHeap(*s, s->dsvs, D3D12_DESCRIPTOR_HEAP_TYPE_DSV, 4096, false);
        for (int dispatch = 0; dispatch < 2; ++dispatch) { D3D12_INDIRECT_ARGUMENT_DESC arg{}; arg.Type = dispatch ? D3D12_INDIRECT_ARGUMENT_TYPE_DISPATCH : D3D12_INDIRECT_ARGUMENT_TYPE_DRAW;
            D3D12_COMMAND_SIGNATURE_DESC desc{}; desc.ByteStride = dispatch ? sizeof(D3D12_DISPATCH_ARGUMENTS) : sizeof(D3D12_DRAW_ARGUMENTS); desc.NumArgumentDescs = 1; desc.pArgumentDescs = &arg;
            if (dispatch) check(s->device->CreateCommandSignature(&desc, nullptr, IID_PPV_ARGS(&s->dispatchSignature)), "CreateCommandSignature dispatch");
            else check(s->device->CreateCommandSignature(&desc, nullptr, IID_PPV_ARGS(&s->drawSignature)), "CreateCommandSignature draw"); }
        return new GRHI_DX12Device{s};
    } catch (const std::exception& error) { initializationError = error.what(); return nullptr; }
}
void grhi_dx12_release(GRHI_DX12Device* d) { delete d; }
const char* grhi_dx12_error(GRHI_DX12Device* d) { static thread_local std::string message; if (!d) return initializationError.c_str(); std::lock_guard<std::mutex> lock(d->state->mutex);
    if (d->state->execution.failed) { std::lock_guard<std::mutex> status(d->state->execution.mutex); message = d->state->execution.error; } else message = d->state->error;
    return message.c_str(); }
const char* grhi_dx12_name(GRHI_DX12Device* d) { return d->state->name.c_str(); }
GRHI_DX12Capabilities grhi_dx12_capabilities(GRHI_DX12Device* d) { return d->state->capabilities; }
int32_t grhi_dx12_wait_idle(GRHI_DX12Device* d) { return run(d, [](State& s) { s.idle(); if (s.execution.failed) { std::lock_guard<std::mutex> status(s.execution.mutex); throw std::runtime_error(s.execution.error); } }); }
int32_t grhi_dx12_buffer(GRHI_DX12Device* d, uint32_t id, uint64_t size, uint32_t usage, uint32_t upload) { return run(d, [&](State& s) {
    auto buffer = makeBuffer(s, size, upload ? D3D12_HEAP_TYPE_UPLOAD : D3D12_HEAP_TYPE_DEFAULT,
        !upload && (usage & (1 << 5)) ? D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS : D3D12_RESOURCE_FLAG_NONE,
        upload ? D3D12_RESOURCE_STATE_GENERIC_READ : D3D12_RESOURCE_STATE_COMMON);
    buffer.upload = upload; buffer.usage = usage; s.buffers.emplace(id, std::move(buffer)); }); }
int32_t grhi_dx12_texture(GRHI_DX12Device* d, uint32_t id, const GRHI_TextureDesc* desc) { return run(d, [&](State& s) {
    require(desc && desc->width && desc->height && desc->depth && desc->layers && desc->mips, "invalid texture size");
    require(desc->samples == 1 && desc->layers <= UINT16_MAX && desc->depth <= UINT16_MAX && desc->mips <= UINT16_MAX, "unsupported texture samples or extent");
    Resource r; r.texture = *desc; r.usage = desc->usage;
    D3D12_RESOURCE_DESC native{}; native.Dimension = desc->dimension == 1 ? D3D12_RESOURCE_DIMENSION_TEXTURE3D : D3D12_RESOURCE_DIMENSION_TEXTURE2D;
    native.Width = desc->width; native.Height = desc->height; native.DepthOrArraySize = UINT16(desc->dimension == 1 ? desc->depth : desc->dimension == 2 ? 6 : desc->layers);
    native.MipLevels = UINT16(desc->mips); native.Format = format(desc->format); native.SampleDesc.Count = 1;
    if (desc->usage & (1 << 1)) native.Flags |= D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
    if (desc->usage & (1 << 2)) { native.Flags |= D3D12_RESOURCE_FLAG_ALLOW_DEPTH_STENCIL; native.Format = desc->format == GRHI_FORMAT_DEPTH32 ? DXGI_FORMAT_R32_TYPELESS : DXGI_FORMAT_R24G8_TYPELESS; }
    if (desc->usage & (1 << 4)) native.Flags |= D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS;
    D3D12_HEAP_PROPERTIES props{}; props.Type = D3D12_HEAP_TYPE_DEFAULT;
    check(s.device->CreateCommittedResource(&props, D3D12_HEAP_FLAG_NONE, &native, r.state, nullptr, IID_PPV_ARGS(&r.native)), "CreateCommittedResource texture");
    if (desc->usage & (1 << 1)) { r.view = s.rtvs.allocate(); s.device->CreateRenderTargetView(r.native.Get(), nullptr, s.rtvs.cpu(r.view)); }
    else if (desc->usage & (1 << 2)) { r.view = s.dsvs.allocate(); D3D12_DEPTH_STENCIL_VIEW_DESC view{}; view.Format = format(desc->format); view.ViewDimension = D3D12_DSV_DIMENSION_TEXTURE2D; s.device->CreateDepthStencilView(r.native.Get(), &view, s.dsvs.cpu(r.view)); }
    s.textures.emplace(id, std::move(r)); }); }
int32_t grhi_dx12_sampler(GRHI_DX12Device* d, uint32_t id, const GRHI_SamplerDesc* desc) { return run(d, [&](State& s) {
    D3D12_SAMPLER_DESC result{};
    result.Filter = D3D12_ENCODE_BASIC_FILTER(desc->min_filter ? D3D12_FILTER_TYPE_LINEAR : D3D12_FILTER_TYPE_POINT, desc->mag_filter ? D3D12_FILTER_TYPE_LINEAR : D3D12_FILTER_TYPE_POINT, desc->mip_filter ? D3D12_FILTER_TYPE_LINEAR : D3D12_FILTER_TYPE_POINT, desc->compare_enabled ? D3D12_FILTER_REDUCTION_TYPE_COMPARISON : D3D12_FILTER_REDUCTION_TYPE_STANDARD);
    auto address = [](uint32_t a) { return a == 0 ? D3D12_TEXTURE_ADDRESS_MODE_WRAP : a == 1 ? D3D12_TEXTURE_ADDRESS_MODE_MIRROR : D3D12_TEXTURE_ADDRESS_MODE_CLAMP; };
    result.AddressU = address(desc->address_u); result.AddressV = address(desc->address_v); result.AddressW = address(desc->address_w); result.MaxLOD = D3D12_FLOAT32_MAX; result.ComparisonFunc = D3D12_COMPARISON_FUNC(desc->compare_op + 1); s.samplerValues[id] = result; }); }
int32_t grhi_dx12_shader(GRHI_DX12Device* d, uint32_t id, uint32_t stage, const void* bytes, size_t count) { return run(d, [&](State& s) {
    require(bytes && count >= 4 && !memcmp(bytes, "DXBC", 4), "shader must contain a DXIL container"); Shader shader{stage, {}}; shader.bytes.assign((const uint8_t*)bytes, (const uint8_t*)bytes + count); s.shaders.emplace(id, std::move(shader)); }); }
void grhi_dx12_destroy(GRHI_DX12Device* d, uint32_t kind, uint32_t id) { run(d, [&](State& s) {
    switch (kind) {
    case GRHI_RESOURCE_BUFFER: s.buffers.erase(id); break;
    case GRHI_RESOURCE_TEXTURE: { auto i = s.textures.find(id); if (i != s.textures.end()) { if (i->second.view != UINT_MAX) ((i->second.usage & (1 << 2)) ? s.dsvs : s.rtvs).free.push_back(i->second.view); s.textures.erase(i); } break; }
    case GRHI_RESOURCE_SAMPLER: s.samplerValues.erase(id); break; case GRHI_RESOURCE_SHADER: s.shaders.erase(id); break;
    case GRHI_RESOURCE_GRAPHICS_PIPELINE: s.graphics.erase(id); break; case GRHI_RESOURCE_COMPUTE_PIPELINE: s.compute.erase(id); break;
    case GRHI_RESOURCE_MESH_PIPELINE: s.mesh.erase(id); break; case GRHI_RESOURCE_AS: s.acceleration.erase(id); break;
    case GRHI_RESOURCE_SET: { auto i = s.sets.find(id); if (i != s.sets.end()) { for (auto entry : i->second.values) { auto p = i->second.descriptors.find(entry.slot); if (p != i->second.descriptors.end()) (entry.type == GRHI_BIND_SAMPLER ? s.samplers : s.views).free.push_back(p->second); } s.sets.erase(i); } break; }
    }
}); }
#endif
