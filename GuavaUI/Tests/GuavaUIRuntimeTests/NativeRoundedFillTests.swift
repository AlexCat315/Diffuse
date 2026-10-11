#if os(macOS)
import Foundation
import Testing
@testable import GuavaUIRuntime

@Suite("Rounded fill pixel coverage", .serialized)
struct NativeRoundedFillTests {
    @Test("Single-sample rounded fills have smooth corners, no halo and no alpha accumulation at each density")
    func coverage() throws {
        let context = try NativeUIDrawTestContext()
        for scale: Float in [1, 1.5, 2, 3] {
            let side = Int(64 * scale)
            let list = DrawList()
            list.pixelScale = scale
            list.addRect(UIRect(x: 0, y: 0, width: 64, height: 64), color: .black)
            list.addRoundedRect(UIRect(x: 8, y: 8, width: 48, height: 40), radius: 8,
                                color: Color(red: 255, green: 255, blue: 255, alpha: 128))
            let (image, _) = try context.nativeImage(list: list, format: NativeUITestFormat.cases[0], samples: 1,
                viewport: NativeUIViewport(pixels: SIMD2(side, side), logical: SIMD2(64, 64)))
            func red(_ x: Int, _ y: Int) -> UInt8 { image[(y * side + x) * 4] }
            #expect(red(Int(32 * scale), Int(28 * scale)) == 128)
            #expect(red(Int(32 * scale), Int(8 * scale) - 1) == 0)
            #expect(red(Int(32 * scale), Int(8 * scale)) == 128)
            let reds = stride(from: 0, to: image.count, by: 4).map { image[$0] }
            #expect(reds.allSatisfy { $0 <= 128 })
            #expect(reds.contains { $0 > 0 && $0 < 128 })
            let coveredArea = reds.reduce(Float.zero) { $0 + Float($1) / 128 }
            let expectedArea = (48 * 40 - (4 - Float.pi) * 8 * 8) * scale * scale
            #expect(abs(coveredArea - expectedArea) < 3 * scale * scale)
        }
    }
}
#endif
