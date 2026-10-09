import AssetPipeline
import Foundation
import NativeRHI
import SceneRuntime

struct NativeDeformableResource {
    let geometry: NativeMeshGeometry
    let revision: UInt64
    let topologyRevision: UInt64
    let vertexCount: Int
    let triangleCount: Int
}

/// Owns new allocations until command submission succeeds. Recording a copy
/// alone must not advance resident revisions or retire the previous geometry.
final class NativeDeformableUpdate {
    let device: Device
    var resources: [EntityID: NativeDeformableResource] = [:]
    var allocated: Set<Buffer> = []
    var report = DeformableMeshUploadReport()
    private var committed = false

    init(device: Device) { self.device = device }
    deinit { if !committed { allocated.forEach { device.destroy($0) } } }
    var buffers: Set<Buffer> { Set(resources.values.flatMap { [$0.geometry.vertices,$0.geometry.indices] }) }
    var geometries: [EntityID: NativeMeshGeometry] { resources.mapValues(\.geometry) }
    func commit(retiring: Set<Buffer>) {
        retiring.subtracting(buffers).forEach { device.destroy($0) }
        committed = true
    }
}

final class NativeDeformableMeshes {
    private let device: Device
    private var resources: [EntityID: NativeDeformableResource] = [:]
    init(device: Device) { self.device = device }
    deinit { resources.values.forEach { $0.geometry.destroy(device: device) } }

    func prepare(_ meshes: [RenderDeformableMesh], into commands: CommandBuffer) throws -> NativeDeformableUpdate {
        let update = NativeDeformableUpdate(device: device)
        for mesh in meshes.sorted(by: { $0.entity.rawValue < $1.entity.rawValue }) {
            guard update.resources[mesh.entity] == nil, mesh.isValid else {
                update.report.rejectedMeshCount += 1; continue
            }
            update.report.meshCount += 1; update.report.vertexCount += mesh.vertexCount
            update.report.triangleCount += mesh.triangleCount
            let previous = resources[mesh.entity]
            let verticesChanged = previous?.revision != mesh.revision || previous?.vertexCount != mesh.vertexCount
            let topologyChanged = previous?.topologyRevision != mesh.topologyRevision || previous?.triangleCount != mesh.triangleCount
            if !verticesChanged && !topologyChanged, let previous {
                update.resources[mesh.entity] = previous; continue
            }
            guard let stream = DeformableMeshVertexStream(mesh) else { continue }
            let vertexSize = Int(stream.vertexBufferSize), indexSize = Int(stream.indexBufferSize)
            let vertices = try buffer(previous?.geometry.vertices, capacity: previous?.geometry.vertexCapacity ?? 0,
                size: vertexSize, usage: .vertex, update: update)
            let indices = try buffer(previous?.geometry.indices, capacity: previous?.geometry.indexCapacity ?? 0,
                size: indexSize, usage: .index, update: update)
            if verticesChanged || vertices != previous?.geometry.vertices {
                try copy(stream.vertices.withUnsafeBytes { Data($0) }, to: vertices, into: commands)
                update.report.uploadedBytes += stream.vertexBufferSize
            }
            if topologyChanged || indices != previous?.geometry.indices {
                try copy(stream.indices.withUnsafeBytes { Data($0) }, to: indices, into: commands)
                update.report.uploadedBytes += stream.indexBufferSize
            }
            let geometry = NativeMeshGeometry(vertices: vertices, indices: indices,
                vertexCapacity: max(vertexSize, previous?.geometry.vertexCapacity ?? 0),
                indexCapacity: max(indexSize, previous?.geometry.indexCapacity ?? 0),
                submeshes: [MeshSubmesh(indexStart: 0,indexCount: UInt32(stream.indices.count),materialIndex: 0)], bounds: mesh.worldBounds)
            update.resources[mesh.entity] = NativeDeformableResource(geometry: geometry, revision: mesh.revision,
                topologyRevision: mesh.topologyRevision, vertexCount: mesh.vertexCount, triangleCount: mesh.triangleCount)
        }
        return update
    }
    func commit(_ update: NativeDeformableUpdate) {
        update.commit(retiring: Set(resources.values.flatMap { [$0.geometry.vertices,$0.geometry.indices] }))
        resources = update.resources
    }
    private func buffer(_ previous: Buffer?, capacity: Int, size: Int, usage: BufferUsage,
                        update: NativeDeformableUpdate) throws -> Buffer {
        if let previous, capacity >= size { return previous }
        let result = try device.makeBuffer(BufferDescriptor(size: size, usage: [usage,.transferDestination]))
        update.allocated.insert(result); return result
    }
    private func copy(_ data: Data, to buffer: Buffer, into commands: CommandBuffer) throws {
        let upload = try device.uploadTransient(data)
        commands.copyPass { $0.copyBuffer(src: upload.buffer, srcOffset: upload.offset, dst: buffer, size: data.count) }
    }
}
