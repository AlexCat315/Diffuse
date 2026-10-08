#include "DX12Internal.hpp"
#ifdef _WIN32
using namespace grhi;
void grhi::textureCopy(GRHI_DX12Encoder& e, Resource& buffer, uint64_t offset, uint32_t rowBytes, Resource& texture, uint32_t width, uint32_t height, bool upload) {
    auto& t = texture.texture; require(width && height && width <= t.width && height <= t.height && t.format < GRHI_FORMAT_DEPTH24 && t.samples == 1, "invalid color texture transfer extent");
    uint64_t rowSize = uint64_t(width)*pixelBytes(t.format); require(rowBytes >= rowSize && offset <= buffer.size && uint64_t(height-1)*rowBytes+rowSize <= buffer.size-offset, "texture transfer exceeds buffer");
    uint32_t pitch = UINT((rowSize+255)&~uint64_t(255)); auto scratch = makeBuffer(*e.state,uint64_t(pitch)*height,D3D12_HEAP_TYPE_DEFAULT);
    transition(e,texture,upload ? D3D12_RESOURCE_STATE_COPY_DEST : D3D12_RESOURCE_STATE_COPY_SOURCE);
    transition(e,buffer,upload ? D3D12_RESOURCE_STATE_COPY_SOURCE : D3D12_RESOURCE_STATE_COPY_DEST);
    transition(e,scratch,upload ? D3D12_RESOURCE_STATE_COPY_DEST : D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION image{}; image.pResource = texture.native.Get(); image.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
    D3D12_TEXTURE_COPY_LOCATION bytes{}; bytes.pResource = scratch.native.Get(); bytes.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
    bytes.PlacedFootprint.Footprint = {format(t.format),width,height,1,pitch}; D3D12_BOX box{0,0,0,width,height,1};
    if (upload) {
        for (UINT row = 0; row < height; ++row) e.list->CopyBufferRegion(scratch.native.Get(),uint64_t(row)*pitch,buffer.native.Get(),offset+uint64_t(row)*rowBytes,rowSize);
        transition(e,scratch,D3D12_RESOURCE_STATE_COPY_SOURCE); e.list->CopyTextureRegion(&image,0,0,0,&bytes,&box);
    } else {
        transition(e,scratch,D3D12_RESOURCE_STATE_COPY_DEST); e.list->CopyTextureRegion(&bytes,0,0,0,&image,&box); transition(e,scratch,D3D12_RESOURCE_STATE_COPY_SOURCE);
        for (UINT row = 0; row < height; ++row) e.list->CopyBufferRegion(buffer.native.Get(),offset+uint64_t(row)*rowBytes,scratch.native.Get(),uint64_t(row)*pitch,rowSize);
    }
    e.states.erase(&scratch); e.temporaries.push_back(scratch.native);
}
static void finishImmediate(GRHI_DX12Encoder* e) {
    auto& q = e->state->queues[0]; check(e->list->Close(), "Close immediate command list"); ID3D12CommandList* lists[] = {e->list.Get()}; q.native->ExecuteCommandLists(1,lists);
    for (auto state : e->states) state.first->state = state.second; uint64_t value = ++q.value; check(q.native->Signal(q.fence.Get(),value), "immediate signal"); waitFence(q.fence.Get(),value);
}
int32_t grhi_dx12_upload_buffer(GRHI_DX12Device* d, uint32_t id, uint64_t offset, const void* bytes, size_t count) { return run(d, [&](State& s) {
    auto& target = s.buffers.at(id); require(offset <= target.size && count <= target.size-offset, "buffer upload bounds"); if (!count) return;
    if (target.upload) { void* pointer = nullptr; D3D12_RANGE read{0,0}; check(target.native->Map(0,&read,&pointer), "Map upload buffer"); memcpy((char*)pointer+offset,bytes,count); D3D12_RANGE written{SIZE_T(offset),SIZE_T(offset+count)}; target.native->Unmap(0,&written); return; }
    auto staging = makeBuffer(s,count,D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_GENERIC_READ); void* pointer = nullptr; D3D12_RANGE read{0,0}; check(staging.native->Map(0,&read,&pointer), "Map staging"); memcpy(pointer,bytes,count); staging.native->Unmap(0,nullptr);
    std::unique_ptr<GRHI_DX12Encoder> e(grhi_dx12_begin(d,0)); require(bool(e), "begin upload failed"); auto previous = target.state; transition(*e,target,D3D12_RESOURCE_STATE_COPY_DEST); e->list->CopyBufferRegion(target.native.Get(),offset,staging.native.Get(),0,count); transition(*e,target,previous); finishImmediate(e.get()); }); }
int32_t grhi_dx12_read_buffer(GRHI_DX12Device* d, uint32_t id, uint64_t offset, void* data, size_t count) { return run(d, [&](State& s) {
    auto& source = s.buffers.at(id); require(offset <= source.size && count <= source.size-offset, "buffer readback bounds"); if (!count) return;
    require(data != nullptr, "missing buffer readback destination");
    auto staging = makeBuffer(s,count,D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_COPY_DEST);
    std::unique_ptr<GRHI_DX12Encoder> e(grhi_dx12_begin(d,0)); require(bool(e), "begin buffer readback failed");
    auto previous = source.state; transition(*e,source,D3D12_RESOURCE_STATE_COPY_SOURCE);
    e->list->CopyBufferRegion(staging.native.Get(),0,source.native.Get(),offset,count); transition(*e,source,previous); finishImmediate(e.get());
    void* pointer = nullptr; D3D12_RANGE read{0,SIZE_T(count)}; check(staging.native->Map(0,&read,&pointer), "Map buffer readback"); memcpy(data,pointer,count);
    D3D12_RANGE written{0,0}; staging.native->Unmap(0,&written);
}); }
int32_t grhi_dx12_transfer_texture(GRHI_DX12Device* d, uint32_t id, uint32_t width, uint32_t height, uint32_t rowBytes, uint32_t mip, uint32_t layer, void* data, size_t count, uint32_t upload) { return run(d, [&](State& s) {
    auto& texture = s.textures.at(id); auto& t = texture.texture; uint64_t rowSize = uint64_t(width)*pixelBytes(t.format);
    auto desc = texture.native->GetDesc();
    require(desc.SampleDesc.Count == 1 && mip < desc.MipLevels && layer < (desc.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE3D ? 1u : desc.DepthOrArraySize), "texture subresource bounds");
    require(data && width && height && width <= std::max(1u,t.width >> mip) && height <= std::max(1u,t.height >> mip) && rowBytes >= rowSize && uint64_t(height-1)*rowBytes+rowSize <= count && t.format < GRHI_FORMAT_DEPTH24, "texture transfer bounds");
    UINT pitch = UINT((rowSize+255)&~uint64_t(255)); auto staging = makeBuffer(s,uint64_t(pitch)*height,upload ? D3D12_HEAP_TYPE_UPLOAD : D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_FLAG_NONE,upload ? D3D12_RESOURCE_STATE_GENERIC_READ : D3D12_RESOURCE_STATE_COPY_DEST);
    if (upload) { void* pointer = nullptr; D3D12_RANGE read{0,0}; check(staging.native->Map(0,&read,&pointer), "Map texture upload"); for (UINT row = 0; row < height; ++row) memcpy((char*)pointer+size_t(row)*pitch,(char*)data+size_t(row)*rowBytes,size_t(rowSize)); staging.native->Unmap(0,nullptr); }
    std::unique_ptr<GRHI_DX12Encoder> e(grhi_dx12_begin(d,0)); require(bool(e), "begin texture transfer failed"); auto previous = texture.state; transition(*e,texture,upload ? D3D12_RESOURCE_STATE_COPY_DEST : D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION image{}; image.pResource = texture.native.Get(); image.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX; image.SubresourceIndex = mip + layer * desc.MipLevels; D3D12_TEXTURE_COPY_LOCATION buffer{}; buffer.pResource = staging.native.Get(); buffer.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT; buffer.PlacedFootprint.Footprint = {format(t.format),width,height,1,pitch}; D3D12_BOX box{0,0,0,width,height,1};
    if (upload) e->list->CopyTextureRegion(&image,0,0,0,&buffer,&box); else e->list->CopyTextureRegion(&buffer,0,0,0,&image,&box);
    transition(*e,texture,previous); finishImmediate(e.get());
    if (!upload) { void* pointer = nullptr; D3D12_RANGE read{0,SIZE_T(uint64_t(pitch)*height)}; check(staging.native->Map(0,&read,&pointer), "Map readback"); for (UINT row = 0; row < height; ++row) memcpy((char*)data+size_t(row)*rowBytes,(char*)pointer+size_t(row)*pitch,size_t(rowSize)); D3D12_RANGE written{0,0}; staging.native->Unmap(0,&written); }
}); }
#endif
