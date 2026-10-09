import Foundation
import NativeRHI
import RenderBackend

public enum GridImage {
    public static func readback(device: Device, texture: Texture, size: RenderDrawableSize) throws -> Data {
        try device.waitUntilIdle()
        var data = Data(count: Int(size.width) * Int(size.height) * 4)
        try data.withUnsafeMutableBytes {
            try device.readTextureData(texture, width: Int(size.width), height: Int(size.height),
                bytesPerRow: Int(size.width) * 4, into: $0)
        }
        return data
    }
    public static func writePPM(_ bgra: Data, size: RenderDrawableSize, to url: URL) throws {
        var data = Data("P6\n\(size.width) \(size.height)\n255\n".utf8)
        for index in stride(from: 0, to: bgra.count, by: 4) { data.append(bgra[index + 2]); data.append(bgra[index + 1]); data.append(bgra[index]) }
        try data.write(to: url)
    }
    public static func difference(_ lhs: Data, _ rhs: Data) throws -> GridImageDifference {
        guard lhs.count == rhs.count, !lhs.isEmpty, lhs.count % 4 == 0 else { throw RHIError.invalidArgument("grid image extents differ") }
        var absolute = 0, maximum = 0, outliers = 0
        for pixel in stride(from: 0, to: lhs.count, by: 4) {
            var delta = 0
            for channel in 0..<3 { let d = abs(Int(lhs[pixel + channel]) - Int(rhs[pixel + channel])); absolute += d; maximum = max(maximum, d); delta = max(delta, d) }
            if delta > 3 { outliers += 1 }
        }
        return GridImageDifference(meanAbsoluteChannelError: Double(absolute) / Double(lhs.count / 4 * 3),
            maximumChannelError: maximum, pixelsOverThree: outliers, pixelCount: lhs.count / 4)
    }
}
public struct GridImageDifference: Codable {
    public let meanAbsoluteChannelError: Double
    public let maximumChannelError: Int
    public let pixelsOverThree: Int
    public let pixelCount: Int
}
