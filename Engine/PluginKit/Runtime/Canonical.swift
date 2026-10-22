import Swift

/// Moves capability inputs and results across the Component Model's
/// canonical ABI. Generated exports call these; plugin code sees `String`s.
public enum CanonicalABI {
    /// A lifted `string` argument: UTF-8 bytes at `pointer`.
    public static func string(_ pointer: UnsafeRawPointer?, _ length: Int) -> String {
        guard let pointer, length > 0 else { return "" }
        return String(utf8: UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: length))
    }

    /// A lifted `list<string>` argument: `count` (pointer, length) pairs.
    public static func strings(_ pointer: UnsafeRawPointer?, _ count: Int) -> [String] {
        guard let pointer, count > 0 else { return [] }
        let pairs = pointer.assumingMemoryBound(to: UInt32.self)
        var result: [String] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            result.append(string(UnsafeRawPointer(bitPattern: UInt(pairs[index * 2])), Int(pairs[index * 2 + 1])))
        }
        return result
    }

    /// A `string` result: the returned area holds the bytes' pointer and length.
    public static func result(_ value: String) -> UnsafeMutableRawPointer {
        let area = cabiRealloc(nil, 0, 4, 8).assumingMemoryBound(to: UInt32.self)
        var value = value
        value.withUTF8 { bytes in
            let copy = cabiRealloc(nil, 0, 1, bytes.count)
            if let base = bytes.baseAddress { copy.copyMemory(from: base, byteCount: bytes.count) }
            area[0] = UInt32(UInt(bitPattern: copy))
            area[1] = UInt32(bytes.count)
        }
        return UnsafeMutableRawPointer(area)
    }
}
