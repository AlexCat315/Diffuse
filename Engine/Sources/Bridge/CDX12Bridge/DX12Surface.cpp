#include "DX12Internal.hpp"
#ifdef _WIN32
using namespace grhi;
int32_t grhi_dx12_surface(GRHI_DX12Device* d, uint32_t swapchainID, void* hwnd, uint32_t width, uint32_t height, uint32_t f, uint32_t vsync) { return run(d, [&](State& s) {
    require(hwnd && width && height && (f == GRHI_FORMAT_BGRA8 || f == GRHI_FORMAT_RGBA8 || f == GRHI_FORMAT_BGRA8_SRGB || f == GRHI_FORMAT_RGBA8_SRGB), "invalid HWND, extent or swapchain format"); s.idle();
    auto& surface = s.surfaces[swapchainID]; require(surface.acquired == 0, "return the acquired image before resizing"); for (auto id : surface.ids) { auto& r = s.textures.at(id); s.rtvs.free.push_back(r.view); s.textures.erase(id); } surface.ids.clear();
    auto nativeFormat = f == GRHI_FORMAT_BGRA8_SRGB ? DXGI_FORMAT_B8G8R8A8_UNORM : f == GRHI_FORMAT_RGBA8_SRGB ? DXGI_FORMAT_R8G8B8A8_UNORM : format(f);
    if (surface.native && surface.window == (HWND)hwnd) check(surface.native->ResizeBuffers(3,width,height,nativeFormat,0), "ResizeBuffers");
    else { surface.native.Reset(); DXGI_SWAP_CHAIN_DESC1 desc{}; desc.Width = width; desc.Height = height; desc.Format = nativeFormat; desc.SampleDesc.Count = 1; desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; desc.BufferCount = 3; desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
        ComPtr<IDXGISwapChain1> swapchain; check(s.factory->CreateSwapChainForHwnd(s.queues[0].native.Get(),(HWND)hwnd,&desc,nullptr,nullptr,&swapchain), "CreateSwapChainForHwnd"); check(swapchain.As(&surface.native), "swapchain3"); s.factory->MakeWindowAssociation((HWND)hwnd,DXGI_MWA_NO_ALT_ENTER); }
    surface.generation += 1; surface.window = (HWND)hwnd; surface.width = width; surface.height = height; surface.vsync = vsync;
    for (UINT i = 0; i < 3; ++i) { Resource r; check(surface.native->GetBuffer(i,IID_PPV_ARGS(&r.native)), "GetBuffer swapchain"); r.state = D3D12_RESOURCE_STATE_PRESENT; r.texture = {width,height,1,1,1,1,f,(1 << 1)|(1 << 7),0}; r.usage = r.texture.usage; r.view = s.rtvs.allocate();
        D3D12_RENDER_TARGET_VIEW_DESC view{}; view.Format = format(f); view.ViewDimension = D3D12_RTV_DIMENSION_TEXTURE2D; s.device->CreateRenderTargetView(r.native.Get(),&view,s.rtvs.cpu(r.view)); require(s.nextSwapchainTexture < 0xf0000000u, "swapchain texture IDs exhausted"); uint32_t id = s.nextSwapchainTexture++; surface.ids.push_back(id); s.textures.emplace(id,std::move(r)); }
}); }
void grhi_dx12_destroy_surface(GRHI_DX12Device* d, uint32_t swapchainID) { run(d, [&](State& s) {
    auto found = s.surfaces.find(swapchainID); if (found == s.surfaces.end()) return;
    for (auto id : found->second.ids) { auto texture = s.textures.find(id); if (texture == s.textures.end()) continue;
        s.rtvs.free.push_back(texture->second.view); s.textures.erase(texture); }
    s.surfaces.erase(found);
}); }
uint32_t grhi_dx12_acquire(GRHI_DX12Device* d, uint32_t swapchainID, uint32_t* width, uint32_t* height, uint64_t* generation) {
    uint32_t id = 0; run(d, [&](State& s) {
        auto& surface = s.surfaces.at(swapchainID);
        require(bool(surface.native) && surface.acquired == 0, "swapchain is missing or already acquired");
        *width = surface.width; *height = surface.height; *generation = surface.generation;
        id = surface.ids.at(surface.native->GetCurrentBackBufferIndex()); surface.acquired = id;
    }); return id;
}
int32_t grhi_dx12_present(GRHI_DX12Device* d, uint32_t swapchainID, uint32_t texture, GRHI_DX12Completion completion, void* context) {
    return run(d, [&](State& s) {
        auto& surface = s.surfaces.at(swapchainID);
        require(bool(surface.native) && surface.acquired == texture, "present requires this swapchain's acquired image");
        auto& r = s.textures.at(texture);
        std::unique_ptr<GRHI_DX12Encoder> e(grhi_dx12_begin(d,0)); require(bool(e), "begin present transition failed");
        transition(*e,r,D3D12_RESOURCE_STATE_PRESENT); check(e->list->Close(), "Close present transition");
        ID3D12CommandList* lists[] = {e->list.Get()}; auto& q = s.queues[0]; q.native->ExecuteCommandLists(1,lists);
        for (auto state : e->states) state.first->state = state.second;
        auto owned = e->state;
        surface.acquired = 0;
        // Queued work owns completion even when DXGI Present fails afterward.
        HRESULT status = surface.native->Present(surface.vsync ? 1 : 0,0);
        retireEncoder(e.release(), completion, context);
        try { check(status, "Present"); } catch (const std::exception& error) { executionFailure(owned, error); }
    });
}
#endif
