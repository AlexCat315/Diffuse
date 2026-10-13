#if os(macOS)
import Foundation
import Testing
@testable import GuavaUIRuntime

@Suite("Shadow alpha quantization", .serialized)
struct ShadowQuantizationTests {
    private let rect = UIRect(x: 16, y: 16, width: 96, height: 64)
    private let color = Color(red: 42, green: 20, blue: 11, alpha: 20)

    @Test("Positive shadow alpha that packs to zero emits no geometry")
    func transparentStepsAreOmitted() {
        for opacity: Float in [0, 0.001, 1] {
            let list = DrawList()
            list.pixelScale = 2
            list.addShadow(SurfaceShadow(color: Color(r: 0.2, g: 0.1, b: 0.05, a: 0.001),
                                         offsetY: 2, blur: 8),
                           rect: rect, cornerRadius: 16, opacity: opacity)
            #expect(list.vertices.isEmpty && list.indices.isEmpty && list.batches.isEmpty)
        }
    }

    @Test("Visible shadow steps retain compositing when zero-alpha meshes are removed")
    func compositingIsPreserved() throws {
        let context = try NativeUIDrawTestContext()
        let viewport = NativeUIViewport(pixels: SIMD2(256, 192), logical: SIMD2(128, 96))
        for frosted in [false, true] {
            for backgroundAlpha: Float in [1, 0.6] {
                let original = scene(optimized: false, frosted: frosted, backgroundAlpha: backgroundAlpha)
                let optimized = scene(optimized: true, frosted: frosted, backgroundAlpha: backgroundAlpha)
                // The dashboard's faint 8pt shadow previously spent most of its
                // geometry on invisible steps, despite their positive Float alpha.
                #expect(optimized.vertices < original.vertices / 3)
                #expect(optimized.indices < original.indices / 3)
                #expect(transparentTriangleCount(original.list) > 0)
                #expect(transparentTriangleCount(optimized.list) == 0)
                for samples in [1, 4] {
                    let format = NativeUITestFormat.cases[3]
                    let expected = try context.nativeImage(list: original.list, format: format, samples: samples, viewport: viewport).0
                    let actual = try context.nativeImage(list: optimized.list, format: format, samples: samples, viewport: viewport).0
                    #expect(actual == expected)
                }
            }
        }
    }

    private func scene(optimized: Bool, frosted: Bool, backgroundAlpha: Float) -> (list: DrawList, vertices: Int, indices: Int) {
        let list = DrawList()
        list.pixelScale = 2
        list.addRect(UIRect(x: 0, y: 0, width: 128, height: 96), color: Color(r: 0.7, g: 0.9, b: 0.8, a: backgroundAlpha))
        list.addRect(UIRect(x: 0, y: 32, width: 128, height: 32), color: Color(r: 0.9, g: 0.4, b: 0.2, a: 0.5))
        let firstVertex = list.vertices.count, firstIndex = list.indices.count
        if optimized {
            list.addShadow(SurfaceShadow(color: color, offsetY: 2, blur: 8),
                           rect: rect, cornerRadius: 16, frostedRect: frosted ? rect : nil)
        } else {
            // Preserve the original 33-step blur algorithm as an independent
            // image reference, including every step that packs to alpha zero.
            for step in 0..<33 {
                let t = Float(step) / 32
                let expansion = 8 * (1 - t)
                let weight = (t + 0.15) * (t + 0.15)
                let stepColor = Color(r: color.r, g: color.g, b: color.b, a: color.a * weight / 33)
                let stepRect = UIRect(x: rect.x - expansion, y: rect.y + 2 - expansion,
                                      width: rect.width + 2 * expansion, height: rect.height + 2 * expansion)
                if frosted {
                    // Independently clip full original quads to the four
                    // nonoverlapping regions outside the panel's hole.
                    for clip in [UIRect(x: 0, y: 0, width: 128, height: 16),
                                 UIRect(x: 0, y: 80, width: 128, height: 16),
                                 UIRect(x: 0, y: 16, width: 16, height: 64),
                                 UIRect(x: 112, y: 16, width: 16, height: 64)] {
                        list.pushClip(clip); list.addRect(stepRect, color: stepColor); list.popClip()
                    }
                } else {
                    list.addRoundedRect(stepRect, radius: 16 + expansion, color: stepColor)
                }
            }
        }
        let shadowVertices = list.vertices.count - firstVertex, shadowIndices = list.indices.count - firstIndex
        // A translucent surface leaves both the exterior and interior shadow
        // visible, exercising RGB and alpha compositing over the background.
        list.addRoundedRect(rect, radius: 16, color: Color(r: 0.9, g: 0.8, b: 0.65, a: 0.65))
        return (list, shadowVertices, shadowIndices)
    }

    private func transparentTriangleCount(_ list: DrawList) -> Int {
        var count = 0
        var index = 0
        while index < list.indices.count {
            let a = list.vertices[Int(list.indices[index])].color >> 24
            let b = list.vertices[Int(list.indices[index + 1])].color >> 24
            let c = list.vertices[Int(list.indices[index + 2])].color >> 24
            if a == 0 && b == 0 && c == 0 { count += 1 }
            index += 3
        }
        return count
    }
}
#endif
