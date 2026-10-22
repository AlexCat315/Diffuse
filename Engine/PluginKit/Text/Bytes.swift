import Swift

// Embedded Swift's string and array initializers copy one byte per loop
// iteration on WebAssembly, while `copyMemory` lowers to one `memory.copy`.
// A guest's fuel is counted in instructions, so bulk text goes through here.

extension String {
    /// A string holding `bytes`, which must be UTF-8; invalid sequences are repaired.
    public init(utf8 bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { self = ""; return }
        self.init(unsafeUninitializedCapacity: bytes.count) { buffer in
            UnsafeMutableRawPointer(buffer.baseAddress!).copyMemory(from: base, byteCount: bytes.count)
            return bytes.count
        }
    }
}

extension Array where Element == String {
    /// The strings back to back, with `separator` between them when given.
    public func joined(separatorByte separator: UInt8? = nil) -> String {
        var count = 0
        for element in self { count += element.utf8.count }
        if separator != nil, !isEmpty { count += self.count - 1 }
        guard count > 0 else { return "" }
        return String(unsafeUninitializedCapacity: count) { buffer in
            var offset = 0
            for (index, element) in enumerated() {
                if let separator, index > 0 {
                    buffer[offset] = separator
                    offset += 1
                }
                var element = element
                element.withUTF8 { bytes in
                    guard let source = bytes.baseAddress else { return }
                    UnsafeMutableRawPointer(buffer.baseAddress! + offset).copyMemory(from: source, byteCount: bytes.count)
                    offset += bytes.count
                }
            }
            return offset
        }
    }
}

/// A growable UTF-8 buffer that copies runs in bulk.
struct ByteWriter {
    private var base: UnsafeMutableRawPointer?
    private var count = 0
    private var capacity = 0

    mutating func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let source = bytes.baseAddress, !bytes.isEmpty else { return }
        reserve(bytes.count)
        (base! + count).copyMemory(from: source, byteCount: bytes.count)
        count += bytes.count
    }

    mutating func append(_ byte: UInt8) {
        reserve(1)
        base!.storeBytes(of: byte, toByteOffset: count, as: UInt8.self)
        count += 1
    }

    mutating func append(_ text: StaticString) {
        append(UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount))
    }

    mutating func append(_ text: String) {
        var text = text
        text.withUTF8 { append($0) }
    }

    private mutating func reserve(_ extra: Int) {
        guard count + extra > capacity else { return }
        let grown = max(capacity * 2, count + extra, 256)
        base = cabiRealloc(base, count, 1, grown)
        capacity = grown
    }

    /// The text written so far; the buffer is released.
    mutating func finish() -> String {
        defer {
            deallocate(base)
            base = nil
            count = 0
            capacity = 0
        }
        guard let base else { return "" }
        return String(utf8: UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: count))
    }
}
