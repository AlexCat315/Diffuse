import AssetPipeline
import CoveUICompose
import Foundation
import RenderBackend
import SIMDCompat

public enum EditorMeshSelectionMode: String, CaseIterable, Sendable {
    case object, vertex, edge, face
    public var title: String {
        switch self { case .object: "Object"; case .vertex: "Vertex"; case .edge: "Edge"; case .face: "Face" }
    }
}

public struct EditorMeshElementHit: Sendable {
    public let index: Int
    public let worldPosition: SIMD3<Float>
    public let distance: Float
}

/// Control-mesh picking uses the same camera projection as the viewport. A BVH
/// rejects occluded vertices/edges; faces resolve to the nearest real triangle.
public struct EditorMeshPicker {
    public let mesh: PolygonMesh
    public let positions: [SIMD3<Float>]
    public let edges: [PolygonMeshEdge]
    private let triangles: [UInt32]
    private let faceForTriangle: [Int]
    private let surface: MeshPickingSurface
    private let tolerance: Float
    private let occluderDistance: ((SIMD3<Float>,SIMD3<Float>) -> Float?)?

    public init(mesh: PolygonMesh, worldMatrix: simd_float4x4,
                occluderDistance: ((SIMD3<Float>,SIMD3<Float>) -> Float?)? = nil) throws {
        let topology = try mesh.topologySlice()
        self.mesh = mesh
        self.occluderDistance = occluderDistance
        positions = mesh.positions.map { p in
            let v = worldMatrix * SIMD4(p,1)
            return SIMD3(v.x,v.y,v.z)
        }
        guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            throw GeometryError.invalidParameter("mesh world transform")
        }
        edges = mesh.edges
        triangles = topology.triangleIndices
        faceForTriangle = mesh.faces.enumerated().flatMap { Array(repeating: $0.offset,count: $0.element.vertices.count-2) }
        surface = MeshPickingSurface(positions: positions,indices: triangles)
        let lo = positions.reduce(SIMD3<Float>(repeating: .infinity)) { simd_min($0,$1) }
        let hi = positions.reduce(SIMD3<Float>(repeating: -.infinity)) { simd_max($0,$1) }
        tolerance = positions.isEmpty ? 0.00001 : max(0.00001,simd_length(hi-lo)*0.0001)
    }

    /// Uses the same ear-clipped topology as rendering, including concave faces.
    public func forEachTriangle(_ visit: (Int,SIMD3<UInt32>) -> Void) {
        for i in faceForTriangle.indices { visit(faceForTriangle[i],SIMD3(triangles[i*3],triangles[i*3+1],triangles[i*3+2])) }
    }

    public func isVisible(_ point: SIMD3<Float>, projection: EditorViewportProjection, xray: Bool) -> Bool {
        guard let screen = projection.project(point), projection.frame.contains(x: screen.x,y: screen.y) else { return false }
        if xray { return true }
        let ray = projection.cursorRay(x: screen.x,y: screen.y)
        let depth = simd_dot(point-ray.origin,ray.direction)
        guard depth >= 0 else { return false }
        if let occluder = occluderDistance?(ray.origin,ray.direction), occluder < depth-tolerance { return false }
        guard let hit = surface.hitDistance(origin: ray.origin,direction: ray.direction,maxDistance: depth+tolerance) else { return true }
        return hit >= depth-max(tolerance,depth*0.00001)
    }

    public func pick(x: Float, y: Float, mode: EditorMeshSelectionMode, projection: EditorViewportProjection,
                     xray: Bool = false, radius: Float = 8) -> EditorMeshElementHit? {
        guard projection.frame.contains(x: x,y: y), radius.isFinite, radius >= 0 else { return nil }
        let ray = projection.cursorRay(x: x,y: y)
        if mode == .face {
            guard let hit = faceHit(origin: ray.origin,direction: ray.direction) else { return nil }
            if !xray, let occluder = occluderDistance?(ray.origin,ray.direction), occluder < hit.distance-tolerance { return nil }
            return hit
        }
        var best: EditorMeshElementHit?
        var bestDistance = radius*radius
        func consider(_ point: SIMD3<Float>, index: Int, screen: SIMD2<Float>) {
            let distance = simd_length_squared(screen-SIMD2(x,y))
            let depth = simd_dot(point-ray.origin,ray.direction)
            guard distance <= bestDistance, depth >= 0,
                  isVisible(point,projection: projection,xray: xray) else { return }
            if let best, abs(distance-bestDistance) < 0.25, best.distance < depth { return }
            bestDistance = distance
            best = .init(index: index,worldPosition: point,distance: depth)
        }
        switch mode {
        case .vertex:
            for (i,point) in positions.enumerated() {
                if let p = projection.project(point) { consider(point,index: i,screen: SIMD2(p.x,p.y)) }
            }
        case .edge:
            for (i,edge) in edges.enumerated() {
                let a = positions[edge.a], b = positions[edge.b]
                guard let pa = projection.project(a), let pb = projection.project(b) else { continue }
                let sa = SIMD2(pa.x,pa.y), sb = SIMD2(pb.x,pb.y), delta = sb-sa
                let length = simd_length_squared(delta)
                let t = length > 1e-8 ? min(1,max(0,simd_dot(SIMD2(x,y)-sa,delta)/length)) : 0
                let wa = (projection.viewProjectionMatrix * SIMD4(a,1)).w
                let wb = (projection.viewProjectionMatrix * SIMD4(b,1)).w
                let denominator = (1-t)/wa+t/wb
                guard abs(denominator) > 1e-12 else { continue }
                let point = (a*((1-t)/wa)+b*(t/wb))/denominator
                consider(point,index: i,screen: sa+delta*t)
            }
        case .face, .object: break
        }
        return best
    }

    public func pick(in rect: UIRect, mode: EditorMeshSelectionMode, projection: EditorViewportProjection,
                     xray: Bool = false) -> Set<Int> {
        let centers: [SIMD3<Float>]
        switch mode {
        case .object: return []
        case .vertex: centers = positions
        case .edge: centers = edges.map { (positions[$0.a]+positions[$0.b])*0.5 }
        case .face: centers = mesh.faces.map { face in
            face.vertices.reduce(SIMD3<Float>.zero) { $0+positions[$1]/Float(face.vertices.count) }
        }
        }
        return Set(centers.indices.filter { i in
            guard let point = projection.project(centers[i]) else { return false }
            return point.x >= rect.x && point.y >= rect.y && point.x <= rect.x+rect.width && point.y <= rect.y+rect.height
                && isVisible(centers[i],projection: projection,xray: xray)
        })
    }

    private func faceHit(origin: SIMD3<Float>, direction: SIMD3<Float>) -> EditorMeshElementHit? {
        var best: EditorMeshElementHit?
        for i in stride(from: 0,to: triangles.count,by: 3) {
            let a = positions[Int(triangles[i])], b = positions[Int(triangles[i+1])], c = positions[Int(triangles[i+2])]
            let e1 = b-a, e2 = c-a, p = simd_cross(direction,e2), determinant = simd_dot(e1,p)
            guard abs(determinant) > 1e-10 else { continue }
            let offset = origin-a, u = simd_dot(offset,p)/determinant
            guard u >= -1e-6, u <= 1.000001 else { continue }
            let q = simd_cross(offset,e1), v = simd_dot(direction,q)/determinant
            guard v >= -1e-6, u+v <= 1.000001 else { continue }
            let distance = simd_dot(e2,q)/determinant
            if distance >= 0, distance < (best?.distance ?? .infinity) {
                best = .init(index: faceForTriangle[i/3],worldPosition: origin+direction*distance,distance: distance)
            }
        }
        return best
    }
}
