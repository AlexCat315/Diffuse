import AssetPipeline
import NativeRHI

enum NativeMeshVertexLayout {
    static var descriptor: VertexLayoutDescriptor {
        return VertexLayoutDescriptor(attributes: [
            VertexAttribute(location: 0, format: .float3, offset: MeshAsset.positionOffset),
            VertexAttribute(location: 1, format: .float3, offset: MeshAsset.normalOffset),
            VertexAttribute(location: 2, format: .float3, offset: MeshAsset.colorOffset),
            VertexAttribute(location: 3, format: .float2, offset: MeshAsset.uvOffset),
            VertexAttribute(location: 4, format: .float4, offset: MeshAsset.tangentOffset),
            VertexAttribute(location: 5, format: .float4, offset: MeshAsset.jointsOffset),
            VertexAttribute(location: 6, format: .float4, offset: MeshAsset.weightsOffset)
        ], bufferLayouts: [VertexBufferLayout(stride: MeshAsset.vertexStride)])
    }
}
