import Foundation

/// Minimal, dependency-free PNG (RGBA8) encoder for test fixtures.
///
/// Uses zlib "stored" (uncompressed) deflate blocks so no compression library
/// is needed, and no platform image framework — the native bridge's stb_image
/// decoder reads it back identically on every platform. Pixels round-trip
/// exactly (no filtering, no compression loss).
enum PortablePNG {
    static func encode(pixels: [UInt8], width: Int, height: Int) -> Data {
        precondition(pixels.count == width * height * 4, "pixels must be RGBA8")

        // Filtered raw scanlines: each row prefixed with filter byte 0 (none).
        var raw = [UInt8]()
        raw.reserveCapacity(height * (1 + width * 4))
        for y in 0..<height {
            raw.append(0)
            let rowStart = y * width * 4
            raw.append(contentsOf: pixels[rowStart ..< rowStart + width * 4])
        }

        // zlib stream: header + stored deflate block(s) + adler32 of `raw`.
        var zlib: [UInt8] = [0x78, 0x01]
        var offset = 0
        repeat {
            let blockLen = min(raw.count - offset, 0xFFFF)
            let isLast = (offset + blockLen) >= raw.count
            zlib.append(isLast ? 0x01 : 0x00)
            zlib.append(UInt8(blockLen & 0xFF))
            zlib.append(UInt8((blockLen >> 8) & 0xFF))
            let nlen = ~UInt16(blockLen)
            zlib.append(UInt8(nlen & 0xFF))
            zlib.append(UInt8((nlen >> 8) & 0xFF))
            if blockLen > 0 { zlib.append(contentsOf: raw[offset ..< offset + blockLen]) }
            offset += blockLen
        } while offset < raw.count
        appendBE32(&zlib, adler32(raw))

        // PNG container: signature + IHDR + IDAT + IEND.
        var png: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        var ihdr = [UInt8]()
        appendBE32(&ihdr, UInt32(width))
        appendBE32(&ihdr, UInt32(height))
        ihdr.append(contentsOf: [8, 6, 0, 0, 0]) // bitDepth=8, colorType=6 (RGBA), deflate, filter, no interlace
        appendChunk(&png, type: "IHDR", data: ihdr)
        appendChunk(&png, type: "IDAT", data: zlib)
        appendChunk(&png, type: "IEND", data: [])
        return Data(png)
    }

    private static func appendBE32(_ out: inout [UInt8], _ v: UInt32) {
        out.append(UInt8((v >> 24) & 0xFF))
        out.append(UInt8((v >> 16) & 0xFF))
        out.append(UInt8((v >> 8) & 0xFF))
        out.append(UInt8(v & 0xFF))
    }

    private static func appendChunk(_ out: inout [UInt8], type: String, data: [UInt8]) {
        appendBE32(&out, UInt32(data.count))
        let typeBytes = Array(type.utf8)
        out.append(contentsOf: typeBytes)
        out.append(contentsOf: data)
        appendBE32(&out, crc32(typeBytes + data))
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func adler32(_ bytes: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
