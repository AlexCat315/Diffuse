#pragma once
#ifdef _WIN32
#define NOMINMAX
#include "include/CDX12Bridge.h"
#include <windows.h>
#include <d3d12.h>
#include <dxgi1_6.h>
#include <wrl/client.h>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
using Microsoft::WRL::ComPtr;
namespace grhi {
inline void check(HRESULT hr, const char* operation) {
    if (FAILED(hr)) throw std::runtime_error(std::string(operation) + " HRESULT=" + std::to_string(uint32_t(hr)));
}
inline void require(bool value, const char* message) { if (!value) throw std::runtime_error(message); }
inline DXGI_FORMAT format(uint32_t f) {
    static const DXGI_FORMAT formats[] = {DXGI_FORMAT_UNKNOWN, DXGI_FORMAT_R8_UNORM,
        DXGI_FORMAT_R8G8B8A8_UNORM, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_B8G8R8A8_UNORM_SRGB,
        DXGI_FORMAT_R8G8B8A8_UNORM_SRGB, DXGI_FORMAT_R16G16B16A16_FLOAT, DXGI_FORMAT_R32G32B32A32_FLOAT,
        DXGI_FORMAT_R32_UINT, DXGI_FORMAT_R32_FLOAT, DXGI_FORMAT_D24_UNORM_S8_UINT,
        DXGI_FORMAT_D24_UNORM_S8_UINT, DXGI_FORMAT_D32_FLOAT};
    require(f < sizeof(formats)/sizeof(formats[0]), "unknown texture format"); return formats[f];
}
inline uint32_t pixelBytes(uint32_t f) { return f == GRHI_FORMAT_R8 ? 1 : f == GRHI_FORMAT_RGBA16F ? 8 : f == GRHI_FORMAT_RGBA32F ? 16 : 4; }
struct Heap {
    ComPtr<ID3D12DescriptorHeap> native;
    UINT stride = 0, next = 0, capacity = 0;
    std::vector<UINT> free;
    UINT allocate() { if (!free.empty()) { auto n = free.back(); free.pop_back(); return n; } require(next < capacity, "descriptor heap exhausted"); return next++; }
    D3D12_CPU_DESCRIPTOR_HANDLE cpu(UINT n) const { auto h = native->GetCPUDescriptorHandleForHeapStart(); h.ptr += SIZE_T(n)*stride; return h; }
    D3D12_GPU_DESCRIPTOR_HANDLE gpu(UINT n) const { auto h = native->GetGPUDescriptorHandleForHeapStart(); h.ptr += UINT64(n)*stride; return h; }
};
struct Resource {
    ComPtr<ID3D12Resource> native;
    D3D12_RESOURCE_STATES state = D3D12_RESOURCE_STATE_COMMON;
    uint64_t size = 0;
    GRHI_TextureDesc texture{};
    UINT view = UINT_MAX;
    uint32_t usage = 0;
    bool upload = false;
};
struct Shader { uint32_t stage; std::vector<uint8_t> bytes; D3D12_SHADER_BYTECODE code() const { return {bytes.data(), bytes.size()}; } };
struct Root { UINT index; uint32_t type, stage; };
struct Layout { ComPtr<ID3D12RootSignature> native; std::vector<uint32_t> sets; std::map<std::pair<uint32_t,uint32_t>,Root> roots; std::map<uint32_t,std::pair<Root,uint32_t>> constants; };
struct BindingSet { uint32_t layout; std::vector<GRHI_BindingValue> values; std::map<uint32_t,UINT> descriptors; };
struct Pipeline { ComPtr<ID3D12PipelineState> native; uint32_t layout; GRHI_RasterDesc raster{}; std::vector<uint32_t> strides; std::vector<DXGI_FORMAT> colors; DXGI_FORMAT depth = DXGI_FORMAT_UNKNOWN; bool compute = false, mesh = false; };
struct Acceleration { Resource result, scratch, instances; std::vector<D3D12_RAYTRACING_GEOMETRY_DESC> geometry; std::vector<GRHI_Instance> authored; bool top = false; };
struct Queue { ComPtr<ID3D12CommandQueue> native; ComPtr<ID3D12Fence> fence; uint64_t value = 0; };
struct Surface { ComPtr<IDXGISwapChain3> native; HWND window = nullptr; UINT width = 0, height = 0; bool vsync = true; std::vector<uint32_t> ids; };
struct ExecutionStatus { std::atomic<bool> failed{false}; std::mutex mutex; std::string error; };
struct State {
    ComPtr<IDXGIFactory6> factory;
    ComPtr<ID3D12Device5> device;
    Queue queues[3];
    Heap views, samplers, rtvs, dsvs;
    std::map<uint32_t,Resource> buffers, textures;
    std::map<uint32_t,D3D12_SAMPLER_DESC> samplerValues;
    std::map<uint32_t,Shader> shaders;
    std::map<uint32_t,std::vector<GRHI_BindingDecl>> bindingLayouts;
    std::map<uint32_t,Layout> layouts;
    std::map<uint32_t,BindingSet> sets;
    std::map<uint32_t,Pipeline> graphics, compute, mesh;
    std::map<uint32_t,Acceleration> acceleration;
    std::map<uint32_t,ComPtr<ID3D12Fence>> timelines;
    ComPtr<ID3D12CommandSignature> drawSignature, dispatchSignature;
    Surface surface;
    GRHI_DX12Capabilities capabilities{};
    std::string name, error;
    ExecutionStatus execution;
    std::mutex mutex;
    void idle();
    ~State();
};
inline D3D12_COMMAND_LIST_TYPE queueType(uint32_t q) { require(q < 3, "invalid queue"); return q == 0 ? D3D12_COMMAND_LIST_TYPE_DIRECT : q == 1 ? D3D12_COMMAND_LIST_TYPE_COMPUTE : D3D12_COMMAND_LIST_TYPE_COPY; }
void makeHeap(State&, Heap&, D3D12_DESCRIPTOR_HEAP_TYPE, UINT, bool);
Resource makeBuffer(State&, uint64_t, D3D12_HEAP_TYPE, D3D12_RESOURCE_FLAGS = D3D12_RESOURCE_FLAG_NONE, D3D12_RESOURCE_STATES = D3D12_RESOURCE_STATE_COMMON);
void waitFence(ID3D12Fence*, uint64_t);
ComPtr<ID3D12Fence>& timeline(State&, uint32_t);
D3D12_RESOURCE_STATES resourceState(uint32_t);
void transition(GRHI_DX12Encoder&, Resource&, D3D12_RESOURCE_STATES);
// Takes ownership after ExecuteCommandLists; completion fires only after the
// commands retire or the device is removed, including signal/wait failures.
void retireEncoder(GRHI_DX12Encoder*, GRHI_DX12Completion = nullptr, void* = nullptr);
void textureCopy(GRHI_DX12Encoder&, Resource&, uint64_t, uint32_t, Resource&, uint32_t, uint32_t, bool);
void buildAcceleration(GRHI_DX12Encoder&, uint32_t);
void graphicsPipeline(State&, uint32_t, const GRHI_GraphicsDesc&);
}
struct GRHI_DX12Device { std::shared_ptr<grhi::State> state; };
struct GRHI_DX12Encoder {
    std::shared_ptr<grhi::State> state;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList6> list;
    uint32_t queue = 0;
    grhi::Pipeline* pipeline = nullptr;
    bool rendering = false;
    std::vector<ComPtr<ID3D12Resource>> temporaries;
    std::map<grhi::Resource*,D3D12_RESOURCE_STATES> states;
    std::vector<DXGI_FORMAT> colors;
    DXGI_FORMAT depth = DXGI_FORMAT_UNKNOWN;
};
namespace grhi {
template<typename F> int32_t run(GRHI_DX12Device* d, F f) {
    if (!d) return 0;
    std::lock_guard<std::mutex> lock(d->state->mutex);
    try { f(*d->state); return 1; } catch (const std::exception& e) { d->state->error = e.what(); return 0; }
}
template<typename F> int32_t record(GRHI_DX12Encoder* e, F f) {
    if (!e) return 0;
    try { f(*e); return 1; } catch (const std::exception& error) { e->state->error = error.what(); return 0; }
}
}
#endif
