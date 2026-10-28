import AssetPipeline
import Foundation
import SIMDCompat
import Testing

@Suite("Geometry authoring")
struct GeometryTests {
    @Test("Catmull-Clark uses shared control vertices and preserves its source")
    func subdivision() throws {
        let source = try GeometryPrimitives.box()
        let result = try GeometryModifier.subdivision(levels: 1).apply(to: source)
        #expect(source.positions.count == 8 && source.faces.count == 6)
        #expect(result.positions.count == 26 && result.faces.count == 24)
        #expect(simd_length(result.positions[0] - SIMD3<Float>(repeating: -5.0/18.0)) < 1e-6)
        let second = try GeometryModifier.subdivision(levels: 1).apply(to: result)
        #expect(second.positions.count == 98 && second.faces.count == 96)
        expectClosed(second)
        let baked = try second.bake(name: "rounded", shading: .smooth)
        #expect(baked.mesh.triangleCount == 192)
        expectFrames(baked.mesh)
    }

    @Test("open subdivision uses the boundary rule and interpolates corner UVs")
    func boundarySubdivision() throws {
        let grid = try GeometryPrimitives.grid(size: SIMD2(1,1), segments: SIMD2(1,1))
        let result = try GeometryModifier.subdivision(levels: 1).apply(to: grid)
        #expect(result.positions[0] == SIMD3(-0.375,0,-0.375))
        #expect(result.faces.count == 4)
        #expect(result.faces[0].uvs == [SIMD2(0,0), SIMD2(0,0.5), SIMD2(0.5,0.5), SIMD2(0.5,0)])
        _ = try result.bake(name: "patch")
    }

    @Test("solidify closes every boundary and has the expected volume")
    func shell() throws {
        let grid = try GeometryPrimitives.grid(size: SIMD2(2,2), segments: SIMD2(2,2))
        let result = try GeometryModifier.solidify(thickness: 0.2).apply(to: grid)
        expectClosed(result)
        let baked = try result.bake(name: "shell")
        #expect(abs(signedVolume(baked.mesh) - 0.8) < 1e-5)
        #expect(baked.mesh.localBounds.min.y == -0.1)
        #expect(baked.mesh.localBounds.max.y == 0.1)
    }

    @Test("mirror welds only the plane seam and reverses face winding")
    func mirror() throws {
        let half = PolygonMesh(positions: [SIMD3(0,0,-1), SIMD3(0,0,1), SIMD3(1,0,1), SIMD3(1,0,-1)],
                               faces: [PolygonFace([0,1,2,3])])
        let result = try GeometryModifier.mirror(axis: .x, offset: 0, weldDistance: 1e-5).apply(to: half)
        #expect(result.positions.count == 6 && result.faces.count == 2)
        let baked = try result.bake(name: "symmetric")
        for i in 0..<baked.mesh.vertexCount {
            #expect(baked.mesh.vertices[i * MeshAsset.vertexFloatCount + MeshAsset.normalFloatOffset + 1] > 0.99)
        }
        let shell = try GeometryModifier.solidify(thickness: 0.2).apply(to: result)
        expectClosed(shell)
    }

    @Test("array keeps material slots and uses absolute scene offsets")
    func array() throws {
        var box = try GeometryPrimitives.box()
        box.faces[1].materialIndex = 1
        let result = try GeometryModifier.array(count: 3, offset: SIMD3(2,0,0)).apply(to: box)
        let baked = try result.bake(name: "row", materials: [.fallback, .fallback])
        #expect(baked.mesh.localBounds.min.x == -0.5)
        #expect(baked.mesh.localBounds.max.x == 4.5)
        #expect(result.faces.filter { $0.materialIndex == 1 }.count == 3)
        #expect(baked.mesh.submeshes.contains { $0.materialIndex == 1 })
        expectClosed(result)
    }

    @Test("face extrusion and vertex edits are transactional")
    func editing() throws {
        var box = try GeometryPrimitives.box()
        try box.extrude(face: 3, by: SIMD3(0,1,0))
        #expect(box.positions.count == 12 && box.faces.count == 10)
        expectClosed(box)
        #expect(abs(signedVolume(try box.bake(name: "extruded").mesh) - 2) < 1e-6)
        let previous = box
        #expect(throws: GeometryError.self) { try box.translate(vertices: [0,999], by: SIMD3(1,0,0)) }
        #expect(box == previous)
        #expect(throws: GeometryError.self) { try box.extrude(face: 0, by: SIMD3(0,1,0), limits: .init(maxVertices: 12)) }
        #expect(box == previous)
        try box.translate(vertices: [0], by: SIMD3(0.1,0,0))
        #expect(box.positions[0].x == previous.positions[0].x + 0.1)
    }

    @Test("concave polygons triangulate without filling their cutout")
    func concavePolygon() throws {
        let shape = PolygonMesh(positions: [SIMD3(0,0,0), SIMD3(2,0,0), SIMD3(2,1,0),
            SIMD3(1,1,0), SIMD3(1,2,0), SIMD3(0,2,0)], faces: [PolygonFace([0,1,2,3,4,5])])
        let result = try shape.bake(name: "L")
        var area: Float = 0
        for i in stride(from: 0, to: result.mesh.indices.count, by: 3) {
            let a = result.mesh.position(at: Int(result.mesh.indices[i]))!
            let b = result.mesh.position(at: Int(result.mesh.indices[i+1]))!
            let c = result.mesh.position(at: Int(result.mesh.indices[i+2]))!
            area += simd_cross(b-a,c-a).z * 0.5
            let center = (a+b+c)/3
            #expect(center.x <= 1 || center.y <= 1)
        }
        #expect(result.mesh.triangleCount == 4)
        #expect(abs(area - 3) < 1e-6)
    }

    @Test("invalid topology, parameters, versions and growth fail predictably")
    func validation() throws {
        let box = try GeometryPrimitives.box()
        #expect(throws: GeometryError.budgetExceeded) {
            try GeometryModifier.array(count: Int.max, offset: .zero).apply(to: box)
        }
        #expect(throws: GeometryError.budgetExceeded) {
            try GeometryModifier.subdivision(levels: 3).apply(to: box, limits: .init(maxVertices: 100))
        }
        #expect(throws: GeometryError.self) { try GeometryModifier.solidify(thickness: .nan).apply(to: box) }
        var bad = box
        bad.positions[0].x = .infinity
        #expect(throws: GeometryError.self) { try bad.bake(name: "bad") }
        bad = box; bad.faces[0].vertices[0] = -1
        #expect(throws: GeometryError.self) { try bad.bake(name: "bad") }
        bad = box; bad.faces.append(bad.faces[0])
        #expect(throws: GeometryError.self) { try GeometryModifier.subdivision(levels: 1).apply(to: bad) }
        let bowTieVertex = PolygonMesh(positions: [SIMD3(0,0,0), SIMD3(1,0,0), SIMD3(0,1,0),
            SIMD3(-1,0,0), SIMD3(0,-1,0)], faces: [PolygonFace([0,1,2]), PolygonFace([0,3,4])])
        #expect(throws: GeometryError.self) { try GeometryModifier.subdivision(levels: 1).apply(to: bowTieVertex) }
        #expect(throws: GeometryError.self) { try GeometryModifier.solidify(thickness: 1).apply(to: bowTieVertex) }
        var document = GeometryDocument(name: "future", source: .box(size: .one))
        document.version = 999
        #expect(throws: GeometryError.unsupportedVersion(999)) { try document.evaluate() }
        let bowTie = PolygonMesh(positions: [SIMD3(0,0,0), SIMD3(1,1,0), SIMD3(0,1,0), SIMD3(1,0,0)],
                                faces: [PolygonFace([0,1,2,3])])
        #expect(throws: GeometryError.self) { try bowTie.bake(name: "crossing") }
    }

    @Test("bake retains a map between welded topology and split GPU corners")
    func topologyMap() throws {
        let result = try GeometryPrimitives.box().bake(name: "cube")
        #expect(result.mesh.vertexCount == 24)
        #expect(result.topologySlice.positions.count == 8)
        let remap = try #require(result.topologySlice.indexRemap)
        #expect(remap.count == result.mesh.vertexCount)
        for i in remap.indices { #expect(result.mesh.position(at: i) == result.topologySlice.positions[Int(remap[i])]) }
        for i in result.mesh.indices.indices {
            #expect(result.mesh.indices[i] == result.topologySlice.triangleIndices[i])
        }
        expectFrames(result.mesh)
    }

    @Test("Bezier tube has outward winding, caps and stable frames")
    func tube() throws {
        let spline = straightSpline()
        #expect(try spline.position(segment: 0, t: 0.5) == SIMD3(0,0,1))
        let result = try spline.tube(radius: 0.25, radialSegments: 8, samplesPerSegment: 4)
        #expect(result.positions.count == 40 && result.faces.count == 34)
        expectClosed(result)
        let baked = try result.bake(name: "pipe", shading: .smooth)
        #expect(abs(signedVolume(baked.mesh) - 0.3535534) < 1e-5)
        expectFrames(baked.mesh)
        #expect(throws: GeometryError.budgetExceeded) {
            try spline.tube(radius: 1, radialSegments: 256, samplesPerSegment: 4096, limits: .init(maxVertices: 100))
        }
        let vertical = BezierSpline(points: [
            .init(position: .zero, handleIn: .zero, handleOut: SIMD3(0,1,0)),
            .init(position: SIMD3(0,3,0), handleIn: SIMD3(0,2,0), handleOut: SIMD3(0,3,0))])
        expectFrames(try vertical.tube(radius: 0.2).bake(name: "vertical", shading: .smooth).mesh)
    }

    @Test("closed spline sweep connects its last ring without caps")
    func closedTube() throws {
        let k: Float = 0.5522848
        let spline = BezierSpline(points: [
            .init(position: SIMD3(1,0,0), handleIn: SIMD3(1,-k,0), handleOut: SIMD3(1,k,0)),
            .init(position: SIMD3(0,1,0), handleIn: SIMD3(k,1,0), handleOut: SIMD3(-k,1,0)),
            .init(position: SIMD3(-1,0,0), handleIn: SIMD3(-1,k,0), handleOut: SIMD3(-1,-k,0)),
            .init(position: SIMD3(0,-1,0), handleIn: SIMD3(-k,-1,0), handleOut: SIMD3(k,-1,0))], closed: true)
        let mesh = try spline.tube(radius: 0.1, radialSegments: 8, samplesPerSegment: 8)
        #expect(mesh.positions.count == 256 && mesh.faces.count == 256)
        expectClosed(mesh)
        let baked = try mesh.bake(name: "ring", shading: .smooth)
        #expect(signedVolume(baked.mesh) > 0)
        expectFrames(baked.mesh)
    }

    @Test("document round trip retains source, stack order, disabled entries and materials")
    func document() throws {
        let document = GeometryDocument(name: "tiles", source: .box(size: SIMD3(2,1,1)), modifiers: [
            .init(.subdivision(levels: 1)), .init(.array(count: 2, offset: SIMD3(3,0,0))),
            .init(.solidify(thickness: -1), enabled: false)], shading: .smooth,
            materials: [.init(baseColor: SIMD4(0.2,0.4,0.8,1), metallic: 0.25, roughness: 0.3)])
        let encoded = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(GeometryDocument.self, from: encoded)
        #expect(decoded == document)
        let result = try decoded.evaluate()
        #expect(result.controlMesh.faces.count == 48)
        #expect(result.mesh.materials[0].roughnessFactor == 0.3)
        #expect(document.source == .box(size: SIMD3(2,1,1)))
        #expect(try decoded.evaluate().mesh.vertices == result.mesh.vertices)
    }

    private func straightSpline() -> BezierSpline {
        BezierSpline(points: [
            .init(position: .zero, handleIn: .zero, handleOut: SIMD3(0,0,2.0/3.0)),
            .init(position: SIMD3(0,0,2), handleIn: SIMD3(0,0,4.0/3.0), handleOut: SIMD3(0,0,2))])
    }

    private func expectClosed(_ mesh: PolygonMesh) {
        var edges: [String: (count: Int, direction: Int)] = [:]
        for face in mesh.faces {
            for i in face.vertices.indices {
                let a = face.vertices[i], b = face.vertices[(i+1)%face.vertices.count]
                let key = "\(min(a,b)):\(max(a,b))"
                let old = edges[key] ?? (0,0)
                edges[key] = (old.count+1,old.direction + (a < b ? 1 : -1))
            }
        }
        #expect(edges.values.allSatisfy { $0.count == 2 && $0.direction == 0 })
    }

    private func signedVolume(_ mesh: MeshAsset) -> Float {
        stride(from: 0, to: mesh.indices.count, by: 3).reduce(0) { sum, i in
            let a = mesh.position(at: Int(mesh.indices[i]))!
            let b = mesh.position(at: Int(mesh.indices[i+1]))!
            let c = mesh.position(at: Int(mesh.indices[i+2]))!
            return sum + simd_dot(a,simd_cross(b,c))/6
        }
    }

    private func expectFrames(_ mesh: MeshAsset) {
        #expect(mesh.vertices.allSatisfy { $0.isFinite })
        for i in 0..<mesh.vertexCount {
            let base = i * MeshAsset.vertexFloatCount
            let n = SIMD3(mesh.vertices[base+3],mesh.vertices[base+4],mesh.vertices[base+5])
            let t = SIMD3(mesh.vertices[base+11],mesh.vertices[base+12],mesh.vertices[base+13])
            #expect(abs(simd_length(n)-1) < 1e-5)
            #expect(abs(simd_length(t)-1) < 1e-5)
            #expect(abs(simd_dot(n,t)) < 1e-5)
        }
    }
}
