#include "DX12Internal.hpp"
#ifdef _WIN32
using namespace grhi;
int32_t grhi_dx12_acceleration_structure(GRHI_DX12Device* d, uint32_t id, const GRHI_Triangle* triangles, size_t triangleCount, const GRHI_Instance* instances, size_t instanceCount) { return run(d, [&](State& s) {
    require(s.capabilities.ray_tier && ((triangleCount > 0) != (instanceCount > 0)), "AS requires nonempty BLAS or TLAS inputs and DXR support");
    Acceleration result; result.top = instanceCount > 0;
    D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_INPUTS input{}; input.Type = result.top ? D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL : D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL; input.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE; input.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
    if (!result.top) { require(triangleCount <= UINT_MAX, "too many geometries"); for (size_t i = 0; i < triangleCount; ++i) { auto t = triangles[i]; auto& buffer = s.buffers.at(t.buffer);
        require(t.triangles && t.triangles <= UINT_MAX/3 && t.stride >= 12 && t.offset <= buffer.size && uint64_t(t.triangles*3-1)*t.stride+12 <= buffer.size-t.offset, "BLAS vertex range invalid");
        D3D12_RAYTRACING_GEOMETRY_DESC geometry{}; geometry.Type = D3D12_RAYTRACING_GEOMETRY_TYPE_TRIANGLES; geometry.Flags = D3D12_RAYTRACING_GEOMETRY_FLAG_OPAQUE;
        geometry.Triangles.VertexFormat = DXGI_FORMAT_R32G32B32_FLOAT; geometry.Triangles.VertexCount = t.triangles*3; geometry.Triangles.VertexBuffer = {buffer.native->GetGPUVirtualAddress()+t.offset,t.stride}; result.geometry.push_back(geometry); }
        input.NumDescs = UINT(result.geometry.size()); input.pGeometryDescs = result.geometry.data();
    } else { require(instanceCount <= (1u << 24), "too many instances"); result.authored.assign(instances,instances+instanceCount);
        result.instances = makeBuffer(s,instanceCount*sizeof(D3D12_RAYTRACING_INSTANCE_DESC),D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_FLAG_NONE,D3D12_RESOURCE_STATE_GENERIC_READ); result.instances.upload = true;
        void* pointer = nullptr; D3D12_RANGE read{0,0}; check(result.instances.native->Map(0,&read,&pointer), "Map TLAS instances"); auto packed = (D3D12_RAYTRACING_INSTANCE_DESC*)pointer;
        for (size_t i = 0; i < instanceCount; ++i) { auto instance = instances[i]; auto& blas = s.acceleration.at(instance.blas); require(!blas.top && instance.mask <= 255, "TLAS references invalid BLAS or mask"); D3D12_RAYTRACING_INSTANCE_DESC native{};
            memcpy(native.Transform,instance.transform,sizeof(native.Transform)); native.InstanceID = UINT(i); native.InstanceMask = instance.mask; native.AccelerationStructure = blas.result.native->GetGPUVirtualAddress(); packed[i] = native; }
        result.instances.native->Unmap(0,nullptr); input.NumDescs = UINT(instanceCount); input.InstanceDescs = result.instances.native->GetGPUVirtualAddress();
    }
    D3D12_RAYTRACING_ACCELERATION_STRUCTURE_PREBUILD_INFO sizes{}; s.device->GetRaytracingAccelerationStructurePrebuildInfo(&input,&sizes); require(sizes.ResultDataMaxSizeInBytes && sizes.ScratchDataSizeInBytes, "AS prebuild returned empty sizes");
    result.result = makeBuffer(s,sizes.ResultDataMaxSizeInBytes,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE);
    result.scratch = makeBuffer(s,sizes.ScratchDataSizeInBytes,D3D12_HEAP_TYPE_DEFAULT,D3D12_RESOURCE_FLAG_ALLOW_UNORDERED_ACCESS,D3D12_RESOURCE_STATE_UNORDERED_ACCESS); s.acceleration.emplace(id,std::move(result));
}); }
void grhi::buildAcceleration(GRHI_DX12Encoder& e, uint32_t id) {
    auto& structure = e.state->acceleration.at(id); D3D12_BUILD_RAYTRACING_ACCELERATION_STRUCTURE_DESC desc{};
    desc.Inputs.Type = structure.top ? D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL : D3D12_RAYTRACING_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL;
    desc.Inputs.Flags = D3D12_RAYTRACING_ACCELERATION_STRUCTURE_BUILD_FLAG_PREFER_FAST_TRACE; desc.Inputs.DescsLayout = D3D12_ELEMENTS_LAYOUT_ARRAY;
    if (structure.top) { desc.Inputs.NumDescs = UINT(structure.authored.size()); desc.Inputs.InstanceDescs = structure.instances.native->GetGPUVirtualAddress(); }
    else { desc.Inputs.NumDescs = UINT(structure.geometry.size()); desc.Inputs.pGeometryDescs = structure.geometry.data(); }
    desc.DestAccelerationStructureData = structure.result.native->GetGPUVirtualAddress(); desc.ScratchAccelerationStructureData = structure.scratch.native->GetGPUVirtualAddress();
    transition(e,structure.scratch,D3D12_RESOURCE_STATE_UNORDERED_ACCESS); e.list->BuildRaytracingAccelerationStructure(&desc,0,nullptr); transition(e,structure.result,D3D12_RESOURCE_STATE_RAYTRACING_ACCELERATION_STRUCTURE);
}
#endif
