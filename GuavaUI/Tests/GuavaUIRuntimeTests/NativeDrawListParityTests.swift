#if os(macOS)
import Foundation
import NativeRHI
import Testing
@testable import GuavaUIRuntime

@Suite("Native draw list GPU parity", .serialized)
struct NativeDrawListParityTests {
    @Test("fractional scissor boundaries preserve Float rounding on both axes")
    func fractionalBoundaryRounding() throws {
        let context = try NativeUIDrawTestContext()
        let format = NativeUITestFormat.cases[1]
        let viewport = NativeUIViewport(pixels: SIMD2(240, 180), logical: SIMD2(160, 120))
        for edge in [Float(2) / 3, Float(4) / 3, Float(10) / 3, Float(20) / 3] {
            for axis in 0..<2 { for upper in [false, true] {
                let clip: UIRect
                if axis == 0 { clip = UIRect(x: upper ? 0 : edge, y: 0, width: upper ? edge : 100, height: 100) }
                else { clip = UIRect(x: 0, y: upper ? 0 : edge, width: 100, height: upper ? edge : 100) }
                let list = DrawList(); list.pushClip(clip)
                list.addRect(UIRect(x: 0, y: 0, width: 160, height: 120), color: .white); list.popClip()
                for samples in [1, 4] {
                    let (native, _) = try context.nativeImage(list: list, format: format, samples: samples, viewport: viewport)
                    let reference = try context.referenceImage(list: list, format: format, samples: samples, viewport: viewport)
                    try expectNativeUIParity(native, reference, format: format, label: "scissor/\(edge)/\(axis)/\(upper)/\(samples)x")
                }
            } }
        }
    }

    @Test("real fonts, color glyphs, patches, sentinel modes, scissor and MSAA match WGPU")
    func formatsAndScales() throws {
        let context = try NativeUIDrawTestContext()
        let list = try nativeUIScene(context)
        #expect(MemoryLayout<UIVertex>.stride == 20)
        #expect(MemoryLayout<UIVertex>.offset(of: \.color) == 16)
        for format in NativeUITestFormat.cases {
            for samples in [1, 4] {
                for size in [SIMD2(160, 120), SIMD2(320, 240), SIMD2(240, 120)] {
                    let viewport = NativeUIViewport(pixels: size, logical: SIMD2(160, 120))
                    let (native, stats) = try context.nativeImage(list: list, format: format, samples: samples, viewport: viewport)
                    let reference = try context.referenceImage(list: list, format: format, samples: samples, viewport: viewport)
                    let label = "\(format.native)/\(samples)x/\(size)"
                    try expectNativeUIParity(native, reference, format: format, label: label)
                    #expect(stats.vertices == list.vertices.count && stats.indices == list.indices.count)
                    #expect(stats.drawCalls == list.batches.filter { $0.indexCount > 0 && $0.scissor?.width != 0 }.count)
                    if format.native == .bgra8UnormSRGB && samples == 4 && size == SIMD2(320, 240) {
                        var ppm = Data("P6\n320 240\n255\n".utf8)
                        for i in stride(from: 0, to: native.count, by: 4) { ppm.append(contentsOf: [native[i+2], native[i+1], native[i]]) }
                        try ppm.write(to: URL(fileURLWithPath: "/tmp/guava-native-ui-parity.ppm"))
                    }
                }
            }
        }
        let (_, clean) = try context.nativeImage(list: list, format: NativeUITestFormat.cases[0], samples: 1,
            viewport: NativeUIViewport(pixels: SIMD2(160, 120), logical: SIMD2(160, 120)))
        #expect(clean.textureUploads == 0 && clean.textureUploadBytes == 0)
    }
}
#endif
