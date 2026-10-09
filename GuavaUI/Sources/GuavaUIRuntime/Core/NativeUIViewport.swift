import Foundation
import NativeRHI

public struct NativeUIViewport: Sendable {
    public let pixels: SIMD2<Int>
    public let logical: SIMD2<Float>
    public init(pixels: SIMD2<Int>, logical: SIMD2<Float>) { self.pixels = pixels; self.logical = logical }

    func validate() throws {
        guard pixels.x > 0 && pixels.y > 0 && pixels.x <= Int(Int32.max) && pixels.y <= Int(Int32.max)
            && logical.x.isFinite && logical.y.isFinite && logical.x > 0 && logical.y > 0 else {
            throw RHIError.invalidArgument("invalid UI viewport dimensions")
        }
    }

    func scissor(_ rect: UIRect?) throws -> ScissorRect? {
        guard let rect else { return ScissorRect(width: pixels.x, height: pixels.y) }
        guard [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) else {
            throw RHIError.invalidArgument("non-finite UI scissor")
        }
        guard rect.width > 0 && rect.height > 0 else { return nil }
        let minX = pixelBoundary(rect.minX, extent: pixels.x, logical: logical.x, upper: false)
        let minY = pixelBoundary(rect.minY, extent: pixels.y, logical: logical.y, upper: false)
        let maxX = pixelBoundary(rect.maxX, extent: pixels.x, logical: logical.x, upper: true)
        let maxY = pixelBoundary(rect.maxY, extent: pixels.y, logical: logical.y, upper: true)
        guard maxX > minX && maxY > minY else { return nil }
        return ScissorRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func pixelBoundary(_ coordinate: Float, extent: Int, logical: Float, upper: Bool) -> Int {
        // Match DrawListRenderer's Float scaling at fractional pixel boundaries.
        // Use Double only when Float arithmetic overflows, and clamp before Int.
        let scaled = coordinate * (Float(extent) / logical)
        let value = scaled.isFinite ? Double(scaled) : Double(coordinate) * Double(extent) / Double(logical)
        return Int(max(0, min(Double(extent), upper ? ceil(value) : floor(value))))
    }
}
