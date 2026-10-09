// Compare quality-1 DevTools JPEG mirrors in a common sRGB pixel space.
// Dynamic status text remains in the result; JPEG comparison supplements the
// lossless component readbacks and does not measure compositor visibility.
import Foundation
import ImageIO
import CoreGraphics

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift compare-editor-captures.swift NATIVE.jpg WGPU.jpg")
}
func pixels(_ path: String) -> (width: Int, height: Int, bytes: [UInt8]) {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fatalError("Cannot decode \(path)") }
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    bytes.withUnsafeMutableBytes { raw in
        let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return (image.width, image.height, bytes)
}
let a = pixels(CommandLine.arguments[1]), b = pixels(CommandLine.arguments[2])
guard a.width == b.width && a.height == b.height else { fatalError("Capture dimensions differ") }
var sum = 0, maximum = 0, outliers = 0
for pixel in 0..<(a.width * a.height) {
    var high = 0
    for channel in 0..<3 {
        let delta = abs(Int(a.bytes[pixel * 4 + channel]) - Int(b.bytes[pixel * 4 + channel]))
        sum += delta; maximum = max(maximum, delta); high = max(high, delta)
    }
    if high > 3 { outliers += 1 }
}
let report: [String: Any] = ["width": a.width, "height": a.height,
    "meanAbsoluteRGBByteError": Double(sum) / Double(a.width * a.height * 3),
    "maxByteError": maximum, "pixelsOverThree": outliers, "pixelCount": a.width * a.height,
    "source": "quality-1 JPEG DevTools mirrors; includes dynamic Editor status text"]
print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
