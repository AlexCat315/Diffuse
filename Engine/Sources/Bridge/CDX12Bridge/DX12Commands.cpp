#include "DX12Internal.hpp"
#ifdef _WIN32
using namespace grhi;
D3D12_RESOURCE_STATES grhi::resourceState(uint32_t state) {
    if (state & (1 << 5)) return D3D12_RESOURCE_STATE_UNORDERED_ACCESS;
    if (state & ((1 << 12) | (1 << 13))) return D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE;
    D3D12_RESOURCE_STATES result = D3D12_RESOURCE_STATE_COMMON;
    if (state & 3) result |= D3D12_RESOURCE_STATE_VERTEX_AND_CONSTANT_BUFFER;
    if (state & (1 << 2)) result |= D3D12_RESOURCE_STATE_INDEX_BUFFER;
    if (state & (1 << 3)) result |= D3D12_RESOURCE_STATE_INDIRECT_ARGUMENT;
    if (state & (1 << 4)) result |= D3D12_RESOURCE_STATE_NON_PIXEL_SHADER_RESOURCE | D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE;
    if (state & (1 << 6)) result |= D3D12_RESOURCE_STATE_RENDER_TARGET;
    if (state & (1 << 7)) result |= D3D12_RESOURCE_STATE_DEPTH_WRITE;
    if (state & (1 << 8)) result |= D3D12_RESOURCE_STATE_DEPTH_READ;
    if (state & (1 << 9)) result |= D3D12_RESOURCE_STATE_COPY_DEST;
    if (state & (1 << 10)) result |= D3D12_RESOURCE_STATE_COPY_SOURCE;
    if (state & (1 << 14)) result |= D3D12_RESOURCE_STATE_RESOLVE_DEST;
    if (state & (1 << 15)) result |= D3D12_RESOURCE_STATE_RESOLVE_SOURCE;
    return result;
}
void grhi::transition(GRHI_DX12Encoder& e, Resource& r, D3D12_RESOURCE_STATES to) {
    if (r.upload) { require((to & ~D3D12_RESOURCE_STATE_GENERIC_READ) == 0, "upload buffers are read only"); return; }
    if (e.queue == 1) to = D3D12_RESOURCE_STATES(to & ~D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    auto i = e.states.find(&r); auto from = i == e.states.end() ? r.state : i->second;
    D3D12_RESOURCE_BARRIER barrier{};
    if (from == to) { if (to != D3D12_RESOURCE_STATE_UNORDERED_ACCESS && to != D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE) return;
        barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV; barrier.UAV.pResource = r.native.Get();
    } else { barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION; barrier.Transition = {r.native.Get(), D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES, from, to}; }
    e.list->ResourceBarrier(1, &barrier); e.states[&r] = to;
}
GRHI_DX12Encoder* grhi_dx12_begin(GRHI_DX12Device* device, uint32_t queue) {
    if (!device) return nullptr;
    try { auto e = std::make_unique<GRHI_DX12Encoder>(); e->state = device->state; e->queue = queue;
        require(!e->state->execution.failed, "D3D12 execution failed; recreate the device");
        check(e->state->device->CreateCommandAllocator(queueType(queue), IID_PPV_ARGS(&e->allocator)), "CreateCommandAllocator");
        check(e->state->device->CreateCommandList(0, queueType(queue), e->allocator.Get(), nullptr, IID_PPV_ARGS(&e->list)), "CreateCommandList");
        if (queue != 2) { ID3D12DescriptorHeap* heaps[] = {e->state->views.native.Get(),e->state->samplers.native.Get()}; e->list->SetDescriptorHeaps(2, heaps); }
        return e.release();
    } catch (const std::exception& error) { device->state->error = error.what(); return nullptr; }
}
static void pipeline(GRHI_DX12Encoder& e, Pipeline& p) {
    require(p.compute ? e.queue != 2 && !e.rendering : e.queue == 0 && e.rendering, "pipeline used outside its pass");
    if (!p.compute) require(p.colors == e.colors && p.depth == e.depth && p.samples == e.samples, "pipeline attachment formats or samples differ from render pass");
    e.pipeline = &p; auto& layout = e.state->layouts.at(p.layout); e.list->SetPipelineState(p.native.Get());
    if (p.compute) e.list->SetComputeRootSignature(layout.native.Get()); else { e.list->SetGraphicsRootSignature(layout.native.Get());
        static const D3D_PRIMITIVE_TOPOLOGY topologies[] = {D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST,D3D_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP,D3D_PRIMITIVE_TOPOLOGY_LINELIST,D3D_PRIMITIVE_TOPOLOGY_LINESTRIP,D3D_PRIMITIVE_TOPOLOGY_POINTLIST}; require(p.raster.primitive < 5, "invalid primitive"); if (!p.mesh) e.list->IASetPrimitiveTopology(topologies[p.raster.primitive]); }
}
int32_t grhi_dx12_render(GRHI_DX12Encoder* encoder, const GRHI_RenderColor* colors, size_t count, const GRHI_RenderDepth* depth) { return record(encoder, [&](GRHI_DX12Encoder& e) {
    require(e.queue == 0 && !e.rendering && count <= 8 && (count || depth), "invalid render pass"); e.colors.clear(); e.depth = DXGI_FORMAT_UNKNOWN; e.pipeline = nullptr;
    e.renderColors.clear(); e.discardDepth = depth && !depth->store ? depth->texture : 0;
    std::vector<uint32_t> attachments;
    auto distinct = [&](uint32_t id) { require(std::find(attachments.begin(), attachments.end(), id) == attachments.end(), "render attachments and resolve targets must be distinct"); attachments.push_back(id); };
    for (size_t i = 0; i < count; ++i) { distinct(colors[i].texture); if (colors[i].resolve) distinct(colors[i].resolve); }
    if (depth) distinct(depth->texture);
    std::vector<D3D12_CPU_DESCRIPTOR_HANDLE> views; UINT width = 0, height = 0;
    auto dimensions = [&](Resource& r) { require(r.texture.dimension == 0 && r.texture.layers == 1, "render targets currently require 2D single layer textures"); if (width) require(width == r.texture.width && height == r.texture.height && e.samples == r.texture.samples, "render target extent or sample count mismatch"); width = r.texture.width; height = r.texture.height; e.samples = r.texture.samples; };
    for (size_t i = 0; i < count; ++i) { auto c = colors[i]; auto& r = e.state->textures.at(c.texture); dimensions(r); require((r.usage & (1 << 1)) && r.view != UINT_MAX, "texture is not a color target");
        if (c.resolve) {
            auto& destination = e.state->textures.at(c.resolve); auto& a = r.texture; auto& b = destination.texture;
            require(a.samples > 1 && b.samples == 1 && a.format == b.format && a.width == b.width && a.height == b.height
                && b.dimension == 0 && b.layers == 1 && (destination.usage & (1 << 1)), "invalid color resolve target");
            D3D12_FEATURE_DATA_FORMAT_SUPPORT support{format(a.format), D3D12_FORMAT_SUPPORT1_NONE, D3D12_FORMAT_SUPPORT2_NONE};
            check(e.state->device->CheckFeatureSupport(D3D12_FEATURE_FORMAT_SUPPORT, &support, sizeof(support)), "CheckFeatureSupport resolve");
            require(support.Support1 & D3D12_FORMAT_SUPPORT1_MULTISAMPLE_RESOLVE, "color format does not support multisample resolve");
        }
        e.renderColors.push_back(c);
        transition(e, r, D3D12_RESOURCE_STATE_RENDER_TARGET); auto view = e.state->rtvs.cpu(r.view); views.push_back(view); e.colors.push_back(format(r.texture.format));
        if (c.load == 1) e.list->ClearRenderTargetView(view, c.clear, 0, nullptr); else if (c.load == 2) e.list->DiscardResource(r.native.Get(), nullptr);
    }
    D3D12_CPU_DESCRIPTOR_HANDLE dsv{};
    if (depth) { auto& r = e.state->textures.at(depth->texture); dimensions(r); require((r.usage & (1 << 2)) && r.view != UINT_MAX, "texture is not a depth target"); transition(e, r, D3D12_RESOURCE_STATE_DEPTH_WRITE); dsv = e.state->dsvs.cpu(r.view); e.depth = format(r.texture.format);
        if (depth->load == 1) e.list->ClearDepthStencilView(dsv, D3D12_CLEAR_FLAG_DEPTH, depth->clear, 0, 0, nullptr); else if (depth->load == 2) e.list->DiscardResource(r.native.Get(), nullptr); }
    e.list->OMSetRenderTargets(UINT(count), views.data(), FALSE, depth ? &dsv : nullptr);
    D3D12_VIEWPORT viewport{0,0,float(width),float(height),0,1}; D3D12_RECT scissor{0,0,LONG(width),LONG(height)}; e.list->RSSetViewports(1,&viewport); e.list->RSSetScissorRects(1,&scissor); e.rendering = true;
}); }
static void endRender(GRHI_DX12Encoder& e) {
    require(e.rendering, "no active render pass to end");
    e.list->OMSetRenderTargets(0, nullptr, FALSE, nullptr);
    for (auto color : e.renderColors) {
        auto& source = e.state->textures.at(color.texture);
        if (color.resolve) {
            auto& destination = e.state->textures.at(color.resolve);
            transition(e, source, D3D12_RESOURCE_STATE_RESOLVE_SOURCE);
            transition(e, destination, D3D12_RESOURCE_STATE_RESOLVE_DEST);
            e.list->ResolveSubresource(destination.native.Get(), 0, source.native.Get(), 0, format(source.texture.format));
        }
        if (!color.store) {
            transition(e, source, D3D12_RESOURCE_STATE_RENDER_TARGET);
            e.list->DiscardResource(source.native.Get(), nullptr);
        }
    }
    if (e.discardDepth) e.list->DiscardResource(e.state->textures.at(e.discardDepth).native.Get(), nullptr);
    e.renderColors.clear(); e.discardDepth = 0; e.rendering = false; e.pipeline = nullptr;
}
static void bindSet(GRHI_DX12Encoder& e, uint32_t slot, uint32_t id) {
    require(e.pipeline != nullptr, "bind a pipeline before binding resources"); auto& layout = e.state->layouts.at(e.pipeline->layout); auto& set = e.state->sets.at(id);
    require(slot < layout.sets.size() && layout.sets[slot] == set.layout, "binding set layout mismatch"); bool compute = e.pipeline->compute;
    for (auto v : set.values) { auto root = layout.roots.at({slot,v.slot});
        if (root.type == D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE) { auto address = (v.type == GRHI_BIND_SAMPLER ? e.state->samplers : e.state->views).gpu(set.descriptors.at(v.slot));
            if (compute) e.list->SetComputeRootDescriptorTable(root.index,address); else e.list->SetGraphicsRootDescriptorTable(root.index,address);
        } else { auto address = v.type == GRHI_BIND_AS ? e.state->acceleration.at(v.resource).result.native->GetGPUVirtualAddress() : e.state->buffers.at(v.resource).native->GetGPUVirtualAddress() + v.offset;
            if (root.type == D3D12_ROOT_PARAMETER_TYPE_CBV) { if (compute) e.list->SetComputeRootConstantBufferView(root.index,address); else e.list->SetGraphicsRootConstantBufferView(root.index,address); }
            else if (root.type == D3D12_ROOT_PARAMETER_TYPE_UAV) { if (compute) e.list->SetComputeRootUnorderedAccessView(root.index,address); else e.list->SetGraphicsRootUnorderedAccessView(root.index,address); }
            else { if (compute) e.list->SetComputeRootShaderResourceView(root.index,address); else e.list->SetGraphicsRootShaderResourceView(root.index,address); }
        }
    }
}
static void uavDependency(GRHI_DX12Encoder& e) { D3D12_RESOURCE_BARRIER barrier{}; barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_UAV; e.list->ResourceBarrier(1,&barrier); }
int32_t grhi_dx12_encode(GRHI_DX12Encoder* encoder, const GRHI_DX12Command* command) { return record(encoder, [&](GRHI_DX12Encoder& e) {
    auto c = *command; auto& s = *e.state;
    switch (c.kind) {
    case GRHI_CMD_GRAPHICS_PIPELINE: pipeline(e,s.graphics.at(c.resource)); break;
    case GRHI_CMD_COMPUTE_PIPELINE: pipeline(e,s.compute.at(c.resource)); break;
    case GRHI_CMD_MESH_PIPELINE: pipeline(e,s.mesh.at(c.resource)); break;
    case GRHI_CMD_BIND_SET: bindSet(e,c.slot,c.resource); break;
    case GRHI_CMD_VERTEX_BUFFER: { require(e.pipeline && !e.pipeline->compute && !e.pipeline->mesh && c.slot < e.pipeline->strides.size(), "vertex buffer requires a graphics pipeline layout"); auto& r = s.buffers.at(c.resource); require(c.a < r.size && r.size - c.a <= UINT_MAX, "vertex buffer range invalid");
        D3D12_VERTEX_BUFFER_VIEW view{r.native->GetGPUVirtualAddress()+c.a,UINT(r.size-c.a),e.pipeline->strides[c.slot]}; e.list->IASetVertexBuffers(c.slot,1,&view); break; }
    case GRHI_CMD_INDEX_BUFFER: { auto& r = s.buffers.at(c.resource); require(c.a < r.size && r.size-c.a <= UINT_MAX && c.a % (c.b ? 4 : 2) == 0, "invalid index range"); D3D12_INDEX_BUFFER_VIEW view{r.native->GetGPUVirtualAddress()+c.a,UINT(r.size-c.a),c.b ? DXGI_FORMAT_R32_UINT : DXGI_FORMAT_R16_UINT}; e.list->IASetIndexBuffer(&view); break; }
    case GRHI_CMD_CONSTANTS: { require(e.pipeline, "constants require a pipeline"); auto range = s.layouts.at(e.pipeline->layout).constants.at(c.slot); require(c.bytes && c.bytes % 4 == 0 && c.bytes <= range.second && range.first.stage == c.stage, "push constant range mismatch");
        if (e.pipeline->compute) e.list->SetComputeRoot32BitConstants(range.first.index,UINT(c.bytes/4),c.data,0); else e.list->SetGraphicsRoot32BitConstants(range.first.index,UINT(c.bytes/4),c.data,0); break; }
    case GRHI_CMD_VIEWPORT: require(c.bytes == sizeof(D3D12_VIEWPORT), "invalid viewport"); e.list->RSSetViewports(1,(const D3D12_VIEWPORT*)c.data); break;
    case GRHI_CMD_SCISSOR: { D3D12_RECT rect{LONG(c.a),LONG(c.b),LONG(c.a+c.c),LONG(c.b+c.d)}; e.list->RSSetScissorRects(1,&rect); break; }
    case GRHI_CMD_DRAW: require(e.pipeline && !e.pipeline->compute && !e.pipeline->mesh && e.rendering, "draw requires graphics pipeline"); e.list->DrawInstanced(UINT(c.a),UINT(c.b),UINT(c.c),UINT(c.d)); uavDependency(e); break;
    case GRHI_CMD_DRAW_INDEXED: require(e.pipeline && !e.pipeline->compute && !e.pipeline->mesh && e.rendering, "indexed draw requires graphics pipeline"); e.list->DrawIndexedInstanced(UINT(c.a),UINT(c.b),UINT(c.c),INT(int64_t(c.d)),c.slot); uavDependency(e); break;
    case GRHI_CMD_DRAW_INDIRECT: { require(e.pipeline && !e.pipeline->compute && !e.pipeline->mesh && e.rendering, "indirect draw requires graphics pipeline"); auto& r = s.buffers.at(c.resource); require(c.a <= r.size && c.b <= (r.size-c.a)/16 && c.a % 4 == 0, "indirect draw range invalid"); e.list->ExecuteIndirect(s.drawSignature.Get(),UINT(c.b),r.native.Get(),c.a,nullptr,0); uavDependency(e); break; }
    case GRHI_CMD_DISPATCH: require(e.pipeline && e.pipeline->compute && c.a <= 65535 && c.b <= 65535 && c.c <= 65535, "invalid compute dispatch"); e.list->Dispatch(UINT(c.a),UINT(c.b),UINT(c.c)); uavDependency(e); break;
    case GRHI_CMD_DISPATCH_INDIRECT: { require(e.pipeline && e.pipeline->compute, "indirect dispatch requires compute pipeline"); auto& r = s.buffers.at(c.resource); require(c.a <= r.size && r.size-c.a >= 12 && c.a % 4 == 0, "indirect dispatch range invalid"); e.list->ExecuteIndirect(s.dispatchSignature.Get(),1,r.native.Get(),c.a,nullptr,0); uavDependency(e); break; }
    case GRHI_CMD_MESH_DISPATCH: require(e.pipeline && e.pipeline->mesh && e.rendering && c.a <= 65535 && c.b <= 65535 && c.c <= 65535 && c.a*c.b*c.c <= (1u << 22), "invalid mesh dispatch"); e.list->DispatchMesh(UINT(c.a),UINT(c.b),UINT(c.c)); uavDependency(e); break;
    case GRHI_CMD_COPY_BUFFER: { auto& src = s.buffers.at(c.resource); auto& dst = s.buffers.at(c.slot); require(c.a <= src.size && c.c <= src.size-c.a && c.b <= dst.size && c.c <= dst.size-c.b && &src != &dst, "buffer copy bounds or overlap invalid"); transition(e,src,D3D12_RESOURCE_STATE_COPY_SOURCE); transition(e,dst,D3D12_RESOURCE_STATE_COPY_DEST); e.list->CopyBufferRegion(dst.native.Get(),c.b,src.native.Get(),c.a,c.c); break; }
    case GRHI_CMD_BUFFER_TO_TEXTURE: case GRHI_CMD_TEXTURE_TO_BUFFER: textureCopy(e,s.buffers.at(c.resource),c.a,uint32_t(c.b),s.textures.at(c.slot),uint32_t(c.c),uint32_t(c.d),c.kind == GRHI_CMD_BUFFER_TO_TEXTURE); break;
    case GRHI_CMD_COPY_TEXTURE: {
        auto& src = s.textures.at(c.resource); auto& dst = s.textures.at(c.slot);
        auto a = src.native->GetDesc(), b = dst.native->GetDesc();
        require(&src != &dst && a.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE2D && b.Dimension == a.Dimension
            && a.DepthOrArraySize == 1 && b.DepthOrArraySize == 1 && a.SampleDesc.Count == 1 && b.SampleDesc.Count == 1
            && src.texture.format == dst.texture.format && src.texture.format < GRHI_FORMAT_DEPTH24
            && c.a && c.b && c.a <= std::min(a.Width,b.Width) && c.b <= std::min(a.Height,b.Height), "invalid 2D color texture copy");
        transition(e,src,D3D12_RESOURCE_STATE_COPY_SOURCE); transition(e,dst,D3D12_RESOURCE_STATE_COPY_DEST);
        D3D12_TEXTURE_COPY_LOCATION source{}, destination{};
        source.pResource = src.native.Get(); source.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        destination.pResource = dst.native.Get(); destination.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        D3D12_BOX box{0,0,0,UINT(c.a),UINT(c.b),1}; e.list->CopyTextureRegion(&destination,0,0,0,&source,&box); break;
    }
    case GRHI_CMD_BARRIER: { Resource* r = c.slot == 0 ? &s.buffers.at(c.resource) : c.slot == 1 ? &s.textures.at(c.resource) : &s.acceleration.at(c.resource).result;
        auto state = resourceState(uint32_t(c.a)); if (c.b == 2 && c.slot != 2) state = D3D12_RESOURCE_STATE_COMMON; transition(e,*r,state); break; }
    case GRHI_CMD_AS_BUILD: require(e.queue != 2, "AS builds require graphics or compute queue"); buildAcceleration(e,c.resource); break;
    case GRHI_CMD_END_RENDER: endRender(e); break;
    default: throw std::runtime_error("unknown native command");
    }
}); }
static void executionFailure(const std::shared_ptr<State>& s, const std::exception& error) {
    std::lock_guard<std::mutex> lock(s->execution.mutex); s->execution.error = error.what(); s->execution.failed = true;
}
void grhi::retireEncoder(GRHI_DX12Encoder* e, GRHI_DX12Completion completion, void* context) {
    auto s = e->state; auto& q = s->queues[e->queue]; auto fence = q.fence; auto queue = q.native;
    uint64_t value = ++q.value; HRESULT signal = queue->Signal(fence.Get(), value);
    auto finish = [e,s,fence,queue,value,signal,completion,context] () mutable {
        try {
            // A failed signal or OS event must never release an in-flight
            // allocator. Retry retirement while the device is still alive.
            if (FAILED(signal)) { check(signal, "completion signal"); }
            waitFence(fence.Get(), value);
        } catch (const std::exception& error) {
            executionFailure(s, error);
            while (SUCCEEDED(s->device->GetDeviceRemovedReason())) {
                if (FAILED(signal)) signal = queue->Signal(fence.Get(), value);
                if (SUCCEEDED(signal) && fence->GetCompletedValue() >= value) break;
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }
        delete e; if (completion) completion(context);
    };
    try { std::thread(finish).detach(); }
    catch (const std::exception&) { finish(); }
}
int32_t grhi_dx12_submit(GRHI_DX12Encoder* e, const GRHI_Timeline* waits, size_t waitCount, const GRHI_Timeline* signals, size_t signalCount, GRHI_DX12Completion completion, void* context) {
    return record(e, [&](GRHI_DX12Encoder& encoder) {
        require(!encoder.rendering, "unterminated render pass"); auto s = encoder.state; auto& q = s->queues[encoder.queue];
        std::vector<ComPtr<ID3D12Fence>> waitFences, signalFences; for (size_t i = 0; i < waitCount; ++i) waitFences.push_back(timeline(*s,waits[i].id)); for (size_t i = 0; i < signalCount; ++i) signalFences.push_back(timeline(*s,signals[i].id));
        check(encoder.list->Close(), "Close command list");
        for (size_t i = 0; i < waitCount; ++i) check(q.native->Wait(waitFences[i].Get(),waits[i].value), "queue timeline wait");
        ID3D12CommandList* lists[] = {encoder.list.Get()}; q.native->ExecuteCommandLists(1,lists);
        for (auto state : encoder.states) state.first->state = state.second;
        // Once queued, ownership belongs to native retirement. Errors are
        // surfaced by wait_idle and must not make Swift abort this encoder.
        try { for (size_t i = 0; i < signalCount; ++i) check(q.native->Signal(signalFences[i].Get(),signals[i].value), "queue timeline signal"); }
        catch (const std::exception& error) { executionFailure(s,error); }
        retireEncoder(e, completion, context);
    });
}
void grhi_dx12_abort(GRHI_DX12Encoder* e) { delete e; }
#endif
