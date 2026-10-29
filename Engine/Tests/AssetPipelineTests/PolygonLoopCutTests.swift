import AssetPipeline
import SIMDCompat
import Testing

@Suite("Loop cut and slide")
struct PolygonLoopCutTests {
    @Test("closed quad rings share vertices, retain old positions and produce evenly spaced selectable loops")
    func closedRing() throws {
        let original = try GeometryPrimitives.box()
        var mesh = original
        let selected = try mesh.loopCut(startingAt: .init(0,1),cuts: 3)
        #expect(mesh.positions.count == 20 && mesh.faces.count == 18 && selected.count == 12)
        #expect(Array(mesh.positions.prefix(8)) == original.positions)
        #expect(edgeCounts(mesh).values.allSatisfy { $0 == 2 })
        #expect(Set(mesh.positions.dropFirst(8).map(\.x)) == [-0.25,0,0.25])
        #expect(selected.allSatisfy { mesh.positions[$0.a].x == mesh.positions[$0.b].x })
        #expect(abs(try volume(mesh)-1) < 1e-5)
        _ = try mesh.bake(name: "loops")
        try mesh.loopCut(startingAt: .init(0,3),cuts: 2,slide: 0.25)
        #expect(mesh.faces.allSatisfy { $0.vertices.count == 4 })
        #expect(edgeCounts(mesh).values.allSatisfy { $0 == 2 })
        #expect(abs(try volume(mesh)-1) < 1e-5)
    }

    @Test("open strips preserve UV seams and material slots while slide moves every cut consistently")
    func strip() throws {
        var mesh = try GeometryPrimitives.grid(size: SIMD2(2,3),segments: SIMD2(1,3))
        mesh.faces[1].materialIndex = 1
        mesh.faces[1].uvs = mesh.faces[1].uvs?.map { $0+SIMD2(2,3) }
        let old = mesh
        let selected = try mesh.loopCut(startingAt: .init(0,1),cuts: 2,slide: -0.5)
        #expect(mesh.positions.count == 16 && mesh.faces.count == 9 && selected.count == 6)
        #expect(mesh.faces.filter { $0.materialIndex == 1 }.count == 3)
        for face in mesh.faces {
            for (i,index) in face.vertices.enumerated() {
                let p = mesh.positions[index], uv = face.uvs![i], offset: SIMD2<Float> = face.materialIndex == 1 ? SIMD2(2,3) : .zero
                #expect(simd_distance(uv-offset,SIMD2((p.x+1)/2,(p.z+1.5)/3)) < 1e-5)
            }
        }
        #expect(Array(mesh.positions.prefix(old.positions.count)) == old.positions)
        _ = try mesh.bake(name: "strip",materials: [.fallback,.fallback])
    }

    @Test("non-quads stop propagation and acquire edge points without T-junctions")
    func terminal() throws {
        var mesh = try GeometryPrimitives.box()
        try mesh.triangulateFaces([1])
        let source = mesh
        let loops = try mesh.loopCut(startingAt: .init(0,1))
        #expect(loops.count == 3 && mesh.positions.count == 12 && mesh.faces.count == 10)
        #expect(edgeCounts(mesh).values.allSatisfy { $0 == 2 })
        #expect(abs(try volume(mesh)-volume(source)) < 1e-5)
        _ = try mesh.bake(name: "terminated")
    }

    @Test("invalid counts, slide, geometry, UV mappings and budgets leave the asset intact")
    func rejection() throws {
        let original = try GeometryPrimitives.box()
        for count in [0,-1,65] {
            var mesh = original
            #expect(throws: GeometryError.self) { try mesh.loopCut(startingAt: .init(0,1),cuts: count) }
            #expect(mesh == original)
        }
        for slide: Float in [-1,1,.nan,.infinity] {
            var mesh = original
            #expect(throws: GeometryError.self) { try mesh.loopCut(startingAt: .init(0,1),slide: slide) }
            #expect(mesh == original)
        }
        var nonplanar = original; nonplanar.positions[0].z += 0.1
        var uv = original; uv.faces[0].uvs?[1].x += 0.25
        var triangles = original; try triangles.triangulateFaces(Set(triangles.faces.indices))
        for source in [nonplanar,uv,triangles] {
            var mesh = source
            #expect(throws: GeometryError.self) { try mesh.loopCut(startingAt: .init(0,1)) }
            #expect(mesh == source)
        }
        var mesh = original
        #expect(throws: GeometryError.self) { try mesh.loopCut(startingAt: .init(0,7)) }
        #expect(throws: GeometryError.self) { try mesh.loopCut(startingAt: .init(0,1),limits: .init(maxVertices: 8,maxFaceCorners: 24)) }
        #expect(mesh == original)
    }

    private func edgeCounts(_ mesh: PolygonMesh) -> [PolygonMeshEdge: Int] {
        var counts: [PolygonMeshEdge: Int] = [:]
        for face in mesh.faces { for i in face.vertices.indices { counts[.init(face.vertices[i],face.vertices[(i+1)%face.vertices.count]),default: 0] += 1 } }
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
