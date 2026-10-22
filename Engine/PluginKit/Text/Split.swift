import Swift

extension String {
    /// Splits on one ASCII byte without grapheme analysis, which keeps
    /// parsing tool output cheap inside a fuel-limited guest.
    public func split(byte separator: UInt8, maxSplits: Int = Int.max, omittingEmpty: Bool = true) -> [String] {
        var result: [String] = []
        var text = self
        text.withUTF8 { bytes in
            var start = 0, index = 0
            while index < bytes.count {
                if bytes[index] == separator, result.count < maxSplits {
                    if !omittingEmpty || index > start {
                        result.append(String(utf8: UnsafeBufferPointer(rebasing: bytes[start..<index])))
                    }
                    start = index + 1
                }
                index += 1
            }
            if !omittingEmpty || bytes.count > start {
                result.append(String(utf8: UnsafeBufferPointer(rebasing: bytes[start...])))
            }
        }
        return result
    }

    /// Whether the text starts with `prefix`, compared byte for byte.
    public func hasBytePrefix(_ prefix: StaticString) -> Bool {
        let count = prefix.utf8CodeUnitCount
        var text = self
        return text.withUTF8 { bytes in
            guard bytes.count >= count else { return false }
            for index in 0..<count where bytes[index] != prefix.utf8Start[index] { return false }
            return true
        }
    }
}
