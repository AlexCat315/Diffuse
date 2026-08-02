import AssetPipeline
import CinematicRenderer
import SceneRuntime
import SIMDCompat

/// Immutable CPU geometry snapshot used by the offline path tracer. The editor
/// builds it from the same `RenderScene` handed to the realtime backend, so the
/// Render Pipeline panel no longer renders an unrelated demo scene.
struct RenderScenePathTraceGeometry: SceneGeometry {
    private struct Triangle: Sendable {
        var a: SIMD3<Float>
        var b: SIMD3<Float>
        var c: SIMD3<Float>
        var normal: SIMD3<Float>
        var albedo: SIMD3<Float>
        var emission: SIMD3<Float>
        var roughness: Float
        var metallic: Float

        var minimum: SIMD3<Float> { simd_min(a, simd_min(b, c)) }
        var maximum: SIMD3<Float> { simd_max(a, simd_max(b, c)) }
        var centroid: SIMD3<Float> { (a + b + c) / 3 }
    }

    private struct BVHNode: Sendable {
        var minimum: SIMD3<Float>
        var maximum: SIMD3<Float>
        var left: Int
        var right: Int
        var start: Int
        var count: Int

        var isLeaf: Bool { count > 0 }
    }

    private let triangles: [Triangle]
    private let orderedTriangleIndices: [Int]
    private let nodes: [BVHNode]
    private let sceneMinimum: SIMD3<Float>
    private let sceneMaximum: SIMD3<Float>

    init(scene: RenderScene) {
        var triangles: [Triangle] = []
        let deformableByEntity = Dictionary(uniqueKeysWithValues: scene.deformableMeshes.map {
            ($0.entity.rawValue, $0)
        })

        for instance in scene.instances {
            let source: (positions: [SIMD3<Float>], indices: [UInt32], mesh: MeshAsset?)
            if let entityID = instance.entity?.rawValue,
               let deformable = deformableByEntity[entityID] {
                source = (deformable.positions, deformable.triangleIndices, nil)
            } else {
                let mesh = Self.meshAsset(for: instance.meshIndex)
                let positions = (0..<mesh.vertexCount).compactMap { mesh.position(at: $0) }
                source = (positions, mesh.indices, mesh)
            }
            Self.appendTriangles(source: source,
                                 instance: instance,
                                 into: &triangles)
        }

        self.triangles = triangles
        if triangles.isEmpty {
            self.orderedTriangleIndices = []
            self.nodes = []
            self.sceneMinimum = .zero
            self.sceneMaximum = .zero
        } else {
            var ordered = Array(triangles.indices)
            var nodes: [BVHNode] = []
            _ = Self.buildNode(start: 0,
                               end: ordered.count,
                               triangles: triangles,
                               ordered: &ordered,
                               nodes: &nodes)
            self.orderedTriangleIndices = ordered
            self.nodes = nodes
            self.sceneMinimum = nodes[0].minimum
            self.sceneMaximum = nodes[0].maximum
        }
    }

    var triangleCount: Int { triangles.count }

    func bounds() -> (min: SIMD3<Float>, max: SIMD3<Float>) {
        (sceneMinimum, sceneMaximum)
    }

    func intersect(ray: Ray) -> HitResult? {
        guard !nodes.isEmpty else { return nil }
        var closestT = Float.infinity
        var closest: HitResult?
        var stack = [0]

        while let nodeIndex = stack.popLast() {
            let node = nodes[nodeIndex]
            guard Self.intersectsBounds(ray: ray,
                                        minimum: node.minimum,
                                        maximum: node.maximum,
                                        maximumT: closestT) else { continue }
            if node.isLeaf {
                for offset in node.start..<(node.start + node.count) {
                    let triangle = triangles[orderedTriangleIndices[offset]]
                    guard let hit = Self.intersect(ray: ray, triangle: triangle),
                          hit.t < closestT else { continue }
                    closestT = hit.t
                    closest = hit
                }
            } else {
                if node.left >= 0 { stack.append(node.left) }
                if node.right >= 0 { stack.append(node.right) }
            }
        }
        return closest
    }

    private static func meshAsset(for meshIndex: Int) -> MeshAsset {
        if let mesh = AssetRegistry.shared.meshAsset(for: meshIndex) {
            return mesh
        }
        // Built-in realtime mesh indices are backend-owned and therefore not
        // present in the project AssetRegistry. Both editor defaults are cube-
        // compatible, which is a substantially safer fallback than omitting
        // visible scene instances from the offline render.
        return BuiltinMesh.cube()
    }

    private static func appendTriangles(
        source: (positions: [SIMD3<Float>], indices: [UInt32], mesh: MeshAsset?),
        instance: RenderInstance,
        into triangles: inout [Triangle]
    ) {
        guard source.indices.count >= 3 else { return }
        let isWorldSpace = source.mesh == nil
        var index = 0
        while index + 2 < source.indices.count {
            let ia = Int(source.indices[index])
            let ib = Int(source.indices[index + 1])
            let ic = Int(source.indices[index + 2])
            index += 3
            guard source.positions.indices.contains(ia),
                  source.positions.indices.contains(ib),
                  source.positions.indices.contains(ic) else { continue }

            let a = isWorldSpace ? source.positions[ia]
                : transform(source.positions[ia], by: instance.transform)
            let b = isWorldSpace ? source.positions[ib]
                : transform(source.positions[ib], by: instance.transform)
            let c = isWorldSpace ? source.positions[ic]
                : transform(source.positions[ic], by: instance.transform)
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            guard length > 0.000_001 else { continue }

            let material = resolvedMaterial(instance: instance,
                                            mesh: source.mesh,
                                            vertexIndex: ia)
            triangles.append(Triangle(
                a: a,
                b: b,
                c: c,
                normal: cross / length,
                albedo: simd_clamp(
                    SIMD3<Float>(material.baseColorFactor.x,
                                 material.baseColorFactor.y,
                                 material.baseColorFactor.z) * instance.colorTint,
                    SIMD3<Float>(repeating: 0),
                    SIMD3<Float>(repeating: 1)
                ),
                emission: material.emissiveFactor,
                roughness: material.roughnessFactor,
                metallic: material.metallicFactor
            ))
        }
    }

    private static func resolvedMaterial(instance: RenderInstance,
                                         mesh: MeshAsset?,
                                         vertexIndex: Int) -> RenderMaterial {
        guard instance.material == .fallback,
              let mesh,
              vertexIndex >= 0,
              vertexIndex < mesh.vertexCount else {
            return instance.material
        }
        let materialOffset = vertexIndex * MeshAsset.vertexFloatCount
            + MeshAsset.materialIndexFloatOffset
        let materialIndex = materialOffset < mesh.vertices.count
            ? Int(mesh.vertices[materialOffset])
            : 0
        guard mesh.materials.indices.contains(materialIndex) else { return instance.material }
        let material = mesh.materials[materialIndex]
        return RenderMaterial(baseColorFactor: material.baseColorFactor,
                              baseColorTextureIndex: material.baseColorTextureIndex,
                              normalTextureIndex: material.normalTextureIndex,
                              metallicFactor: material.metallicFactor,
                              roughnessFactor: material.roughnessFactor)
    }

    private static func transform(_ position: SIMD3<Float>,
                                  by matrix: simd_float4x4) -> SIMD3<Float> {
        let transformed = matrix * SIMD4<Float>(position.x, position.y, position.z, 1)
        if abs(transformed.w) > 0.000_001, transformed.w != 1 {
            return SIMD3<Float>(transformed.x, transformed.y, transformed.z) / transformed.w
        }
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    private static func buildNode(start: Int,
                                  end: Int,
                                  triangles: [Triangle],
                                  ordered: inout [Int],
                                  nodes: inout [BVHNode]) -> Int {
        var minimum = SIMD3<Float>(repeating: Float.infinity)
        var maximum = SIMD3<Float>(repeating: -Float.infinity)
        var centroidMinimum = minimum
        var centroidMaximum = maximum
        for offset in start..<end {
            let triangle = triangles[ordered[offset]]
            minimum = simd_min(minimum, triangle.minimum)
            maximum = simd_max(maximum, triangle.maximum)
            centroidMinimum = simd_min(centroidMinimum, triangle.centroid)
            centroidMaximum = simd_max(centroidMaximum, triangle.centroid)
        }

        let nodeIndex = nodes.count
        nodes.append(BVHNode(minimum: minimum,
                             maximum: maximum,
                             left: -1,
                             right: -1,
                             start: start,
                             count: end - start))
        guard end - start > 8 else { return nodeIndex }

        let extent = centroidMaximum - centroidMinimum
        let axis: Int
        if extent.x >= extent.y, extent.x >= extent.z {
            axis = 0
        } else if extent.y >= extent.z {
            axis = 1
        } else {
            axis = 2
        }
        guard extent[axis] > 0.000_001 else { return nodeIndex }

        let sorted = ordered[start..<end].sorted {
            triangles[$0].centroid[axis] < triangles[$1].centroid[axis]
        }
        ordered.replaceSubrange(start..<end, with: sorted)
        let midpoint = start + (end - start) / 2
        let left = buildNode(start: start,
                             end: midpoint,
                             triangles: triangles,
                             ordered: &ordered,
                             nodes: &nodes)
        let right = buildNode(start: midpoint,
                              end: end,
                              triangles: triangles,
                              ordered: &ordered,
                              nodes: &nodes)
        nodes[nodeIndex].left = left
        nodes[nodeIndex].right = right
        nodes[nodeIndex].count = 0
        return nodeIndex
    }

    private static func intersectsBounds(ray: Ray,
                                         minimum: SIMD3<Float>,
                                         maximum: SIMD3<Float>,
                                         maximumT: Float) -> Bool {
        var lower: Float = 0.000_1
        var upper = maximumT
        for axis in 0..<3 {
            var t0 = (minimum[axis] - ray.origin[axis]) * ray.invDirection[axis]
            var t1 = (maximum[axis] - ray.origin[axis]) * ray.invDirection[axis]
            if t0 > t1 { swap(&t0, &t1) }
            lower = max(lower, t0)
            upper = min(upper, t1)
            if upper < lower { return false }
        }
        return true
    }

    private static func intersect(ray: Ray, triangle: Triangle) -> HitResult? {
        let edge1 = triangle.b - triangle.a
        let edge2 = triangle.c - triangle.a
        let p = simd_cross(ray.direction, edge2)
        let determinant = simd_dot(edge1, p)
        guard abs(determinant) > 0.000_001 else { return nil }
        let inverse = 1 / determinant
        let tVector = ray.origin - triangle.a
        let u = simd_dot(tVector, p) * inverse
        guard u >= 0, u <= 1 else { return nil }
        let q = simd_cross(tVector, edge1)
        let v = simd_dot(ray.direction, q) * inverse
        guard v >= 0, u + v <= 1 else { return nil }
        let t = simd_dot(edge2, q) * inverse
        guard t > 0.000_1 else { return nil }
        let normal = simd_dot(triangle.normal, ray.direction) > 0
            ? -triangle.normal
            : triangle.normal
        return HitResult(t: t,
                         position: ray.point(at: t),
                         normal: normal,
                         albedo: triangle.albedo,
                         emission: triangle.emission,
                         roughness: triangle.roughness,
                         metallic: triangle.metallic)
    }
}
