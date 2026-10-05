import AssetPipeline
import RHIWGPU
import SceneRuntime
import SIMDCompat

struct MeshDrawKey: Hashable {
    var shadow: Bool
    var mirrored: Bool
    var batchIndex: Int = 0
    var meshIndex: Int
    var firstIndex: UInt32
    var indexCount: UInt32
    var materialIndex: Int
    var alphaMode: MaterialAlphaMode
    var cutoff: Float
    var doubleSided: Bool
    var baseTexture: Int?
    var normalTexture: Int?
    var mrTexture: Int?
    var colorFactor: SIMD4<Float>
    /// Posed/deformable meshes and transparent objects cannot merge with peers.
    var uniqueInstance: Int?
    var paletteEntity: EntityID?
    var paletteMatrixCount: Int
}

struct MeshDrawResources {
    var uniform: GPUBuffer
    var instances: GPUBuffer
    var bindGroup: GPUBindGroup
    var capacity: Int
    var shadowGeneration: UInt64
}
extension MeshDrawResources: @unchecked Sendable {}

struct PreparedMeshDraw {
    var key: MeshDrawKey
    var mesh: GPUMesh
    var resources: MeshDrawResources
    var instanceCount: UInt32
    var distance: Float
}
extension PreparedMeshDraw: @unchecked Sendable {}

extension WGPURenderer {
    func prepareMeshDraws(scene: RenderScene, viewProjection: simd_float4x4, palettes: JointPaletteMap) throws {
        meshVisibility = MeshVisibilityPlan.make(scene: scene, viewProjection: viewProjection,
            settings: activeRenderSettings, skinnedEntities: Set(palettes.palettes.keys),
            meshExists: { self.meshes.indices.contains($0) })
        var activeKeys = Set<MeshDrawKey>()
        cameraMeshDraws = try makeMeshDraws(scene: scene, indices: meshVisibility.visibleIndices,
            viewProjection: viewProjection, palettes: palettes, shadow: false, activeKeys: &activeKeys)
        // Full-detail shadow casters include objects outside the camera frustum.
        shadowMeshDraws = activeRenderSettings.enableShadows
            ? try makeMeshDraws(scene: scene, indices: Array(scene.instances.indices),
                viewProjection: viewProjection, palettes: palettes, shadow: true, activeKeys: &activeKeys) : []
        meshDrawResources = meshDrawResources.filter { activeKeys.contains($0.key) }
    }

    private func makeMeshDraws(scene: RenderScene, indices: [Int], viewProjection: simd_float4x4,
                               palettes: JointPaletteMap, shadow: Bool,
                               activeKeys: inout Set<MeshDrawKey>) throws -> [PreparedMeshDraw] {
        var groups: [MeshDrawKey: [Int]] = [:]
        var order: [MeshDrawKey] = []
        var nextBatch: [MeshDrawKey: Int] = [:]
        for index in indices {
            let instance = scene.instances[index]
            let meshIndex = shadow ? instance.meshIndex : (meshVisibility.meshIndices[index] ?? instance.meshIndex)
            var resolved = instance; resolved.meshIndex = meshIndex
            guard let mesh = resolvedMesh(for: resolved) else { continue }
            let submeshes = mesh.submeshes.isEmpty
                ? [MeshSubmesh(indexStart: 0, indexCount: mesh.indexCount, materialIndex: 0)] : mesh.submeshes
            let materialSet = MeshMaterialRegistry.shared.materials(for: meshIndex)
            let posed = instance.entity.flatMap { palettes.palette(for: $0) } != nil
            let deformable = instance.entity.flatMap { deformableMeshResources[$0] } != nil
            for part in submeshes {
                let imported = materialSet.flatMap { $0.materials.indices.contains(part.materialIndex) ? $0.materials[part.materialIndex] : nil } ?? .fallback
                let mode = instance.material.alphaMode ?? imported.alphaMode
                if shadow && mode == .blend { continue }
                let alpha = instance.material.baseColorFactor.w * imported.baseColorFactor.w
                let factor = SIMD4<Float>(instance.material.baseColorFactor.x, instance.material.baseColorFactor.y,
                                          instance.material.baseColorFactor.z, alpha)
                var key = MeshDrawKey(shadow: shadow, mirrored: simd_determinant(instance.transform) < 0, meshIndex: meshIndex,
                    firstIndex: part.indexStart, indexCount: part.indexCount, materialIndex: part.materialIndex,
                    alphaMode: mode, cutoff: instance.material.alphaCutoff ?? imported.alphaCutoff,
                    doubleSided: instance.material.doubleSided ?? imported.doubleSided,
                    baseTexture: instance.material.baseColorTextureIndex ?? imported.baseColorTextureIndex,
                    normalTexture: instance.material.normalTextureIndex ?? imported.normalTextureIndex,
                    mrTexture: imported.metallicRoughnessTextureIndex, colorFactor: factor,
                    uniqueInstance: !activeRenderSettings.enableMeshInstancing || mode == .blend || posed || deformable ? index : nil,
                    paletteEntity: posed ? instance.entity : nil,
                    paletteMatrixCount: instance.entity.flatMap { palettes.palette(for: $0)?.matrices.count } ?? 0)
                let baseKey = key
                key.batchIndex = nextBatch[baseKey, default: 0]
                if (groups[key]?.count ?? 0) >= 16_384 {
                    key.batchIndex += 1
                    nextBatch[baseKey] = key.batchIndex
                }
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(index)
            }
        }
        var draws: [PreparedMeshDraw] = []
        for key in order {
            let members = groups[key]!
            let first = scene.instances[members[0]]
            var resolved = first; resolved.meshIndex = key.meshIndex
            guard let mesh = resolvedMesh(for: resolved), let layout = meshBindGroupLayout else { continue }
            activeKeys.insert(key)
            var resource = meshDrawResources[key]
            if resource == nil || resource!.capacity < members.count || resource!.shadowGeneration != shadowResourceGeneration {
                let capacity = max(members.count, resource?.capacity ?? 0)
                let uniform = try backend.createBuffer(size: UInt64(MemoryLayout<MeshInstanceUniforms>.stride), usage: [.uniform, .copyDst])
                let instances = try backend.createBuffer(size: UInt64(capacity * MemoryLayout<MeshInstanceUniforms>.stride), usage: [.storage, .copyDst])
                let textures = meshTextureResources[key.meshIndex]
                let entries = try meshBindGroupEntries(instanceUniformBuffer: uniform,
                    baseColorTextureView: key.baseTexture.flatMap { textures?[$0]?.view },
                    normalMapTextureView: key.normalTexture.flatMap { textures?[$0]?.view },
                    metallicRoughnessTextureView: key.mrTexture.flatMap { textures?[$0]?.view },
                    jointPaletteBuffer: key.paletteEntity.flatMap { jointPaletteBuffers[$0] },
                    instanceStorageBuffer: instances)
                resource = MeshDrawResources(uniform: uniform, instances: instances,
                    bindGroup: try backend.createBindGroup(layout: layout, entries: entries),
                    capacity: capacity, shadowGeneration: shadowResourceGeneration)
            }
            guard let resource else { continue }
            let mode: Float = key.alphaMode == .opaque ? 0 : (key.alphaMode == .mask ? 1 : 2)
            let uniforms = members.map { index in
                let instance = scene.instances[index]
                return MeshInstanceUniforms(mvp: viewProjection * instance.transform, model: instance.transform,
                    colorTint: SIMD4<Float>(instance.colorTint * SIMD3<Float>(key.colorFactor.x, key.colorFactor.y, key.colorFactor.z), key.colorFactor.w),
                    material: SIMD4<Float>(mode, key.cutoff, key.doubleSided ? 1 : 0, 0))
            }
            uniforms.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { backend.writeBuffer(resource.instances, data: base, size: bytes.count) }
            }
            var drawUniform = uniforms[0]; drawUniform.material.w = 1
            withUnsafeBytes(of: &drawUniform) { bytes in
                if let base = bytes.baseAddress { backend.writeBuffer(resource.uniform, data: base, size: bytes.count) }
            }
            meshDrawResources[key] = resource
            let position = first.transform.columns.3
            // View-axis depth gives stable back-to-front compositing for panes
            // offset sideways from the camera; Euclidean distance does not.
            let distance = simd_dot(SIMD3<Float>(position.x, position.y, position.z) - scene.camera.eye,
                                    simd_normalize(scene.camera.target - scene.camera.eye))
            draws.append(PreparedMeshDraw(key: key, mesh: mesh, resources: resource,
                                          instanceCount: UInt32(members.count), distance: distance))
        }
        if activeRenderSettings.enableGroupedDrawByMesh {
            return draws.sorted { $0.key.meshIndex < $1.key.meshIndex }
        }
        return draws
    }

    func encodePreparedMeshDraws(pass: GPURenderPassEncoder, draws: [PreparedMeshDraw], kind: RenderPassKind, hdr: Bool) throws -> Int {
        for draw in draws {
            pass.setPipeline(try ensureMaterialMeshPipeline(kind: kind, hdr: hdr, key: draw.key))
            pass.setBindGroup(draw.resources.bindGroup, index: 0, dynamicOffsets: [0])
            pass.setVertexBuffer(draw.mesh.vertexBuffer, slot: 0)
            pass.setIndexBuffer(draw.mesh.indexBuffer, format: .uint32)
            pass.drawIndexed(indexCount: draw.key.indexCount, instanceCount: draw.instanceCount, firstIndex: draw.key.firstIndex)
        }
        return draws.count
    }
}
