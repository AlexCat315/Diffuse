#if os(macOS)
import Foundation
import NativeRHI
import Testing
@testable import GuavaUIRuntime

@Suite("Draw batch clipping and coalescing", .serialized)
struct DrawBatchCoalescingTests {
    @Test("clip classification checks every edge and preserves its tolerance")
    func clipClassification() throws {
        let geometry = DrawList()
        geometry.pushClip(UIRect(x: 0, y: 0, width: 10, height: 10))
        geometry.addRect(UIRect(x: 0, y: 0, width: 10, height: 10), color: .white)
        let batch = try #require(geometry.batches.first)
        let cases: [(SIMD2<Float>, Bool)] = [
            (SIMD2(5, 5), false),
            (SIMD2(-0.009, 5), false), (SIMD2(-0.011, 5), true),
            (SIMD2(5, -0.009), false), (SIMD2(5, -0.011), true),
            (SIMD2(10.009, 5), false), (SIMD2(10.011, 5), true),
            (SIMD2(5, 10.009), false), (SIMD2(5, 10.011), true)
        ]
        for (position, expected) in cases {
            for vertexIndex in [0, geometry.vertices.count - 1] {
                var vertices = geometry.vertices
                vertices[vertexIndex].posX = position.x; vertices[vertexIndex].posY = position.y
                let list = DrawList()
                list.load(vertices: vertices, indices: geometry.indices, batches: [batch])
                #expect(NativeUIGeometry.reliesOnScissorClip(list: list, batch: batch) == expected)
            }
        }
        var unrestricted = batch; unrestricted.scissor = nil
        #expect(!NativeUIGeometry.reliesOnScissorClip(list: geometry, batch: unrestricted))
        var empty = batch; empty.indexCount = 0
        #expect(!NativeUIGeometry.reliesOnScissorClip(list: geometry, batch: empty))
    }

    @Test("merged draws preserve real clips and skipped index gaps")
    func renderedClips() throws {
        let context = try NativeUIDrawTestContext()
        let viewport = NativeUIViewport(pixels: SIMD2(32, 24), logical: SIMD2(32, 24))
        let format = NativeUITestFormat.cases[1]
        let reference = try context.nativeImage(list: DrawList(), format: format, samples: 1, viewport: viewport).0
        for variant in 0..<3 {
            let list = DrawList()
            list.pushClip(UIRect(x: 0, y: 0, width: 8, height: 8))
            list.addRect(UIRect(x: 0, y: 0, width: variant == 1 ? 16 : 8, height: 8), color: Color(r: 1, g: 0, b: 0))
            list.popClip()
            if variant == 2 {
                list.pushClip(UIRect(x: 8, y: 0, width: 0, height: 8))
                list.addRect(UIRect(x: 8, y: 0, width: 8, height: 8), color: Color(r: 0, g: 0, b: 1))
                list.popClip()
            }
            list.pushClip(UIRect(x: 16, y: 0, width: 8, height: 8))
            list.addRect(UIRect(x: 16, y: 0, width: 8, height: 8), color: Color(r: 0, g: 1, b: 0))
            list.popClip()
            let (pixels, statistics) = try context.nativeImage(list: list, format: format, samples: 1, viewport: viewport)
            #expect(statistics.drawCalls == (variant == 0 ? 1 : 2))
            let red = (4 * 32 + 4) * 4, gap = (4 * 32 + 12) * 4, green = (4 * 32 + 20) * 4
            #expect(pixels[red..<red + 4] == Data([0, 0, 255, 255]))
            #expect(pixels[gap..<gap + 4] == reference[gap..<gap + 4])
            #expect(pixels[green..<green + 4] == Data([0, 255, 0, 255]))
        }
    }
}
#endif
