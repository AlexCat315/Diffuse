import Foundation
import CoreGraphics
import ImageIO

// Sample the starter's content area, excluding status bars and safe areas.
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fatalError("Simulator screenshot could not be decoded")
}
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let colors: Set<UInt32> = pixels.withUnsafeMutableBytes { bytes in
    let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else {
        fatalError("Screenshot pixel buffer could not be created")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    var values = Set<UInt32>()
    for y in stride(from: height / 10, to: height / 3, by: 5) {
        for x in stride(from: width / 10, to: width * 9 / 10, by: 5) {
            let offset = (y * width + x) * 4
            values.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
        }
    }
    return values
}
guard colors.count > 16 else { fatalError("iOS rendered an empty frame (\(colors.count) colors)") }
print("PASS iOS frame contains rendered controls (\(colors.count) colors)")
