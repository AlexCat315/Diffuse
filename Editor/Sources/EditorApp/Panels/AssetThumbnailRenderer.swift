import Foundation
import AssetPipeline
import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import SIMDCompat

/// One shaded triangle of a mesh thumbnail, in normalized `[0,1]²` thumbnail
/// space (y points down). Scaled into the tile rect at draw time.
struct ThumbnailTriangle {
    var ax: Float; var ay: Float
    var bx: Float; var by: Float
    var cx: Float; var cy: Float
    var color: Color
}

/// Software renderer that turns a registered mesh into a small set of
/// flat-shaded, pre-projected triangles for the asset browser. A full GPU
/// render-to-texture path would mean re-entrantly driving the engine's
/// monolithic scene renderer (shared pipeline/uniform state) — far riskier than
/// this self-contained CPU rasterizer, which is plenty for a thumbnail:
/// cluster-decimate dense meshes, project from a fixed 3/4 studio camera,
/// flat-shade against a fixed light, and painter-sort. Results are cached per
/// asset id; the projection is view-independent so a cached entry is reusable
/// for any tile size.
enum AssetThumbnailRasterizer {
    private static let lock = NSLock()
    // Lock-guarded (see `lock`); the unsafe annotation matches the codebase's
    // other synchronized statics (e.g. `EditorViewportDropTarget`).
    nonisolated(unsafe) private static var cache: [String: [ThumbnailTriangle]] = [:]

    /// Triangles for `assetID`, rasterizing (and caching) on first request.
    /// Returns `nil` when the mesh can't be resolved or is empty.
    static func triangles(assetID: String, meshIndex: Int) -> [ThumbnailTriangle]? {
        lock.lock()
        if let cached = cache[assetID] {
            lock.unlock()
            return cached.isEmpty ? nil : cached
        }
        lock.unlock()

        let tris = rasterize(meshIndex: meshIndex) ?? []

        lock.lock()
        cache[assetID] = tris
        lock.unlock()
        return tris.isEmpty ? nil : tris
    }

    static func invalidate() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    // MARK: - Rasterization

    /// Dense meshes above this triangle count are cluster-decimated; smaller
    /// meshes are projected verbatim (clustering would crush their silhouette).
    private static let decimationThreshold = 3000

    private static func rasterize(meshIndex: Int) -> [ThumbnailTriangle]? {
        guard let mesh = AssetRegistry.shared.meshAsset(for: meshIndex) else { return nil }
        let stride = MeshAsset.vertexFloatCount
        let v = mesh.vertices
        let idx = mesh.indices
        guard v.count >= stride, idx.count >= 3 else { return nil }
        let vertexCount = v.count / stride

        func position(_ i: Int) -> SIMD3<Float> {
            let o = i * stride
            return SIMD3<Float>(v[o], v[o + 1], v[o + 2])
        }

        var triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]
        if idx.count / 3 > decimationThreshold {
            triangles = clusterDecimate(vertices: v, stride: stride,
                                        vertexCount: vertexCount, indices: idx)
        } else {
            triangles = []
            triangles.reserveCapacity(idx.count / 3)
            var t = 0
            while t + 2 < idx.count {
                let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
                t += 3
                guard a < vertexCount, b < vertexCount, c < vertexCount else { continue }
                triangles.append((position(a), position(b), position(c)))
            }
        }
        guard !triangles.isEmpty else { return nil }

        return project(triangles)
    }

    /// Vertex-clustering decimation: snap vertices to a coarse grid, collapse
    /// each cell to its centroid, and keep one triangle per unique cell triple.
    /// Bounds the output to roughly the grid's occupied surface — a few hundred
    /// to a couple thousand triangles regardless of source density.
    private static func clusterDecimate(vertices v: [Float],
                                        stride: Int,
                                        vertexCount: Int,
                                        indices idx: [UInt32]) -> [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] {
        var lo = SIMD3<Float>(repeating: .infinity)
        var hi = SIMD3<Float>(repeating: -.infinity)
        for i in 0..<vertexCount {
            let o = i * stride
            let p = SIMD3<Float>(v[o], v[o + 1], v[o + 2])
            lo = SIMD3<Float>(min(lo.x, p.x), min(lo.y, p.y), min(lo.z, p.z))
            hi = SIMD3<Float>(max(hi.x, p.x), max(hi.y, p.y), max(hi.z, p.z))
        }
        let span = max(hi.x - lo.x, max(hi.y - lo.y, hi.z - lo.z))
        let n = 22
        let inv = Float(n) / max(span, 1e-4)
        let cellCount = n * n * n

        func cellIndex(_ p: SIMD3<Float>) -> Int {
            let cx = min(n - 1, max(0, Int((p.x - lo.x) * inv)))
            let cy = min(n - 1, max(0, Int((p.y - lo.y) * inv)))
            let cz = min(n - 1, max(0, Int((p.z - lo.z) * inv)))
            return (cx * n + cy) * n + cz
        }

        var sum = [SIMD3<Float>](repeating: .zero, count: cellCount)
        var count = [Int32](repeating: 0, count: cellCount)
        var cellOfVertex = [Int32](repeating: 0, count: vertexCount)
        for i in 0..<vertexCount {
            let o = i * stride
            let p = SIMD3<Float>(v[o], v[o + 1], v[o + 2])
            let ci = cellIndex(p)
            sum[ci] += p
            count[ci] += 1
            cellOfVertex[i] = Int32(ci)
        }
        var rep = [SIMD3<Float>](repeating: .zero, count: cellCount)
        for c in 0..<cellCount where count[c] > 0 {
            rep[c] = sum[c] / Float(count[c])
        }

        var seen = Set<Int>()
        var out: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        var t = 0
        while t + 2 < idx.count {
            let a = Int(idx[t]), b = Int(idx[t + 1]), c = Int(idx[t + 2])
            t += 3
            guard a < vertexCount, b < vertexCount, c < vertexCount else { continue }
            let ka = Int(cellOfVertex[a]), kb = Int(cellOfVertex[b]), kc = Int(cellOfVertex[c])
            if ka == kb || kb == kc || ka == kc { continue }
            var s0 = ka, s1 = kb, s2 = kc
            if s0 > s1 { swap(&s0, &s1) }
            if s1 > s2 { swap(&s1, &s2) }
            if s0 > s1 { swap(&s0, &s1) }
            let key = (s0 * cellCount + s1) * cellCount + s2
            if !seen.insert(key).inserted { continue }
            out.append((rep[ka], rep[kb], rep[kc]))
        }
        return out
    }

    /// Project model-space triangles through a fixed studio camera, flat-shade
    /// them, and painter-sort back-to-front.
    private static func project(_ triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)]) -> [ThumbnailTriangle] {
        // Fixed 3/4 view basis (camera front-top-right of the origin).
        let camDir = normalize3(SIMD3<Float>(0.55, 0.5, 1.0)) // origin → camera
        let forward = -camDir
        let right = normalize3(cross3(forward, SIMD3<Float>(0, 1, 0)))
        let camUp = cross3(right, forward)
        // Light fixed in view space (upper-left, toward the camera at −z).
        let lightView = normalize3(SIMD3<Float>(-0.35, 0.55, -0.72))
        let clay = SIMD3<Float>(0.80, 0.81, 0.86)
        let ambient: Float = 0.34

        func toView(_ p: SIMD3<Float>) -> SIMD3<Float> {
            SIMD3<Float>(dot3(p, right), dot3(p, camUp), dot3(p, forward))
        }

        let viewTris = triangles.map { (toView($0.0), toView($0.1), toView($0.2)) }

        var minX = Float.infinity, maxX = -Float.infinity
        var minY = Float.infinity, maxY = -Float.infinity
        for (a, b, c) in viewTris {
            for p in [a, b, c] {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
        }
        let margin: Float = 0.12
        let span = max(max(maxX - minX, maxY - minY), 1e-4)
        let scale = (1 - 2 * margin) / span
        let centerX = (minX + maxX) * 0.5
        let centerY = (minY + maxY) * 0.5

        // Back-to-front: largest view depth (farther into the scene) drawn first.
        let order = viewTris.indices.sorted {
            (viewTris[$0].0.z + viewTris[$0].1.z + viewTris[$0].2.z)
                > (viewTris[$1].0.z + viewTris[$1].1.z + viewTris[$1].2.z)
        }

        func screenX(_ p: SIMD3<Float>) -> Float { 0.5 + (p.x - centerX) * scale }
        func screenY(_ p: SIMD3<Float>) -> Float { 0.5 - (p.y - centerY) * scale }

        var result: [ThumbnailTriangle] = []
        result.reserveCapacity(viewTris.count)
        for i in order {
            let (a, b, c) = viewTris[i]
            var normal = normalize3(cross3(b - a, c - a))
            if normal.z > 0 { normal = -normal } // orient toward camera (−z)
            let diffuse = max(0, dot3(normal, lightView))
            let shade = ambient + (1 - ambient) * diffuse
            let rgb = clay * shade
            result.append(ThumbnailTriangle(
                ax: screenX(a), ay: screenY(a),
                bx: screenX(b), by: screenY(b),
                cx: screenX(c), cy: screenY(c),
                color: Color(r: min(rgb.x, 1), g: min(rgb.y, 1), b: min(rgb.z, 1), a: 1)
            ))
        }
        return result
    }
}

// MARK: - Vector helpers

private func dot3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    a.x * b.x + a.y * b.y + a.z * b.z
}

private func cross3(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float> {
    SIMD3<Float>(a.y * b.z - a.z * b.y,
                 a.z * b.x - a.x * b.z,
                 a.x * b.y - a.y * b.x)
}

private func normalize3(_ v: SIMD3<Float>) -> SIMD3<Float> {
    let len = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
    return len > 1e-8 ? v / len : SIMD3<Float>(0, 0, 0)
}

// MARK: - Thumbnail view

/// Paints a registered mesh's shaded thumbnail into its own node bounds via the
/// `DrawList` triangle primitive. Square-fit and centered; draws nothing (the
/// parent backdrop shows through) when the mesh can't be rasterized.
struct MeshThumbnailView: _PrimitiveView {
    let assetID: String
    let meshIndex: Int

    func _makeNode() -> Node {
        let node = Node()
        node.isHitTestable = false
        node.isFocusable = false
        return node
    }

    func _updateNode(_ node: Node) {
        let assetID = self.assetID
        let meshIndex = self.meshIndex
        node.draw = { [weak node] list, origin in
            guard let node else { return }
            let w = Float(node.frame.width)
            let h = Float(node.frame.height)
            guard w > 1, h > 1,
                  let tris = AssetThumbnailRasterizer.triangles(assetID: assetID, meshIndex: meshIndex)
            else { return }
            let side = min(w, h)
            let ox = Float(origin.x) + (w - side) * 0.5
            let oy = Float(origin.y) + (h - side) * 0.5
            for t in tris {
                list.addTriangle(ox + t.ax * side, oy + t.ay * side,
                                 ox + t.bx * side, oy + t.by * side,
                                 ox + t.cx * side, oy + t.cy * side,
                                 color: t.color)
            }
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        LayoutNode()
    }

    var _children: [any View] { [] }
}
