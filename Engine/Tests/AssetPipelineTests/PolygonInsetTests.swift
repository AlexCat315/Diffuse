import AssetPipeline
import SIMDCompat
import Testing

@Suite("Polygon face inset")
struct PolygonInsetTests {
    @Test("equal-width borders preserve original boundaries, cap indices and affine corner attributes")
    func border() throws {
        var mesh = try GeometryPrimitives.grid(size: SIMD2(2,2),segments: SIMD2(1,1))
        mesh.faces[0].materialIndex = 3
        let original = mesh
        try mesh.inset(faces: [0],by: 0.25)
        #expect(Array(mesh.positions.prefix(4)) == original.positions)
        #expect(mesh.positions.count == 8 && mesh.faces.count == 5)
        #expect(mesh.faces.allSatisfy { $0.materialIndex == 3 && $0.uvs?.count == 4 })
        for (index,vertex) in mesh.faces[0].vertices.enumerated() {
            let p = mesh.positions[vertex], uv = mesh.faces[0].uvs![index]
            #expect(abs(abs(p.x)-0.75) < 1e-6 && abs(abs(p.z)-0.75) < 1e-6)
            #expect(abs(abs(uv.x-0.5)-0.375) < 1e-6 && abs(abs(uv.y-0.5)-0.375) < 1e-6)
        }
        _ = try mesh.bake(name: "border",materials: Array(repeating: .fallback,count: 4))
    }

    @Test("adjacent faces inset independently without breaking a closed manifold or its UV seams")
    func closed() throws {
        var mesh = try GeometryPrimitives.box(), original = mesh
        original.faces[1].uvs = original.faces[1].uvs?.map { $0+SIMD2(2,3) }
        mesh = original
        try mesh.inset(faces: Set(mesh.faces.indices),by: 0.1)
        #expect(mesh.positions.count == 32 && mesh.faces.count == 30)
        #expect(Array(mesh.positions.prefix(8)) == original.positions)
        #expect(edgeCounts(mesh).values.allSatisfy { $0 == 2 })
        #expect(mesh.faces[1].uvs!.allSatisfy { $0.x > 2 && $0.y > 3 })
        #expect(abs(try volume(mesh)-1) < 1e-5)
    }

    @Test("inset then inward region extrusion forms a watertight recessed panel")
    func recess() throws {
        var mesh = try GeometryPrimitives.box()
        // Box face 1 points along +Z.
        try mesh.inset(faces: [1],by: 0.1)
        try mesh.extrude(faces: [1],by: SIMD3(0,0,-0.2))
        #expect(mesh.positions.count == 16 && mesh.faces.count == 14)
        #expect(edgeCounts(mesh).values.allSatisfy { $0 == 2 })
        #expect(abs(try volume(mesh)-0.872) < 1e-5)
    }

    @Test("small faces get a usable default and collinear boundary vertices remain supported")
    func defaults() throws {
        var mesh = PolygonMesh(positions: [SIMD3(0,0,0),SIMD3(0.001,0,0),SIMD3(0.002,0,0),SIMD3(0.002,0.001,0),SIMD3(0,0.001,0)],
                               faces: [.init([0,1,2,3,4])])
        let width = try mesh.suggestedInsetDistance(faces: [0])
        #expect(width > 0 && width < 0.0005)
        try mesh.inset(faces: [0],by: width)
        #expect(mesh.positions.count == 10 && mesh.faces.count == 6)
        _ = try mesh.bake(name: "tiny")
        var chamfer = PolygonMesh(positions: [SIMD3(0,0,0),SIMD3(1,0,0),SIMD3(1,0.99,0),SIMD3(0.99,1,0),SIMD3(0,1,0)],faces: [.init([0,1,2,3,4])])
        try chamfer.inset(faces: [0],by: chamfer.suggestedInsetDistance(faces: [0]))
        _ = try chamfer.bake(name: "chamfer")
    }

    @Test("invalid widths, unsupported surfaces and growth limits leave the source untouched")
    func rejection() throws {
        let source = try GeometryPrimitives.box()
        for width: Float in [0,-1,.nan,.infinity,0.5,0.6] {
            var mesh = source
            #expect(throws: GeometryError.self) { try mesh.inset(faces: [0],by: width) }
            #expect(mesh == source)
        }
        var folded = source; folded.positions[0].z += 0.1
        var uv = source; uv.faces[0].uvs?[1].x += 0.1
        let concave = PolygonMesh(positions: [SIMD3(0,0,0),SIMD3(2,0,0),SIMD3(1,1,0),SIMD3(2,2,0),SIMD3(0,2,0)],faces: [.init([0,1,2,3,4])])
        for original in [folded,uv,concave] {
            var mesh = original
            #expect(throws: GeometryError.self) { try mesh.inset(faces: [0],by: 0.1) }
            #expect(mesh == original)
        }
        var mesh = source
        #expect(throws: GeometryError.self) { try mesh.inset(faces: [99],by: 0.1) }
        #expect(throws: GeometryError.self) { try mesh.inset(faces: [0],by: 0.1,limits: .init(maxVertices: 8,maxFaceCorners: 24)) }
        #expect(mesh == source)
    }

    private func edgeCounts(_ mesh: PolygonMesh) -> [PolygonMeshEdge: Int] {
        var counts: [PolygonMeshEdge: Int] = [:]
        for face in mesh.faces { for i in face.vertices.indices {
            counts[.init(face.vertices[i],face.vertices[(i+1)%face.vertices.count]),default: 0] += 1
        } }
        return counts
    }
    private func volume(_ mesh: PolygonMesh) throws -> Float {
        let baked = try mesh.bake(name: "volume").mesh
        return abs(stride(from: 0,to: baked.indices.count,by: 3).reduce(Float(0)) { result,i in
            let a = baked.position(at: Int(baked.indices[i]))!, b = baked.position(at: Int(baked.indices[i+1]))!, c = baked.position(at: Int(baked.indices[i+2]))!
            return result+simd_dot(a,simd_cross(b,c))/6
        })
    }
}
