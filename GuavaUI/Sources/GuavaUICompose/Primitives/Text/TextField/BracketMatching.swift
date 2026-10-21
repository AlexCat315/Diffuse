import GuavaUIRuntime

/// Retains only one buffer revision and caret result. Blink and scroll redraws
/// reuse the pair; ordinary text never triggers a lexical-window scan.
final class TextBracketMatching: NodeResource {
    private var buffer: TextBuffer?
    private var caret = -1
    private var result: [Int] = []
    private(set) var scannedUTF8Count = 0

    func mount(node: Node) {}
    func unmount(node: Node) { buffer = nil; caret = -1; result = [] }

    func pair(in source: TextBuffer, caretIndex: Int) -> [Int] {
        let index = min(source.characterCount, max(0, caretIndex))
        if buffer == source, caret == index { return result }
        buffer = source; caret = index; result = []
        let byte = source.utf8Offset(forCharacterIndex: index)
        let neighbors = source.utf8Bytes(inUTF8Range: max(0, byte - 1)..<min(source.utf8Length, byte + 1))
        guard neighbors.contains(where: Self.isBracket) else { return result }
        let start = max(0, byte - 65_536), end = min(source.utf8Length, byte + 65_536)
        let bytes = source.utf8Bytes(inUTF8Range: start..<end)
        scannedUTF8Count += bytes.count
        let code = Self.codeMask(bytes)
        let local = byte - start
        let target: Int
        if local < bytes.count, code[local], Self.isBracket(bytes[local]) { target = local }
        else if local > 0, code[local - 1], Self.isBracket(bytes[local - 1]) { target = local - 1 }
        else { return result }
        guard let match = Self.matchingBracket(in: bytes, code: code, at: target) else { return result }
        result = [start + target, start + match]
        return result
    }

    private static func isBracket(_ byte: UInt8) -> Bool {
        byte == 40 || byte == 41 || byte == 91 || byte == 93 || byte == 123 || byte == 125
    }

    private static func codeMask(_ bytes: [UInt8]) -> [Bool] {
        var mask = Array(repeating: true, count: bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 47 {
                while index < bytes.count, bytes[index] != 10 {
                    mask[index] = false
                    index += 1
                }
                continue
            }
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 42 {
                mask[index] = false; mask[index + 1] = false
                index += 2
                while index < bytes.count {
                    mask[index] = false
                    if bytes[index] == 42, index + 1 < bytes.count, bytes[index + 1] == 47 {
                        index += 1
                        mask[index] = false
                        index += 1
                        break
                    }
                    index += 1
                }
                continue
            }
            if byte == 34 {
                mask[index] = false
                index += 1
                while index < bytes.count {
                    mask[index] = false
                    if bytes[index] == 92 {
                        index += 1
                        if index < bytes.count { mask[index] = false }
                    } else if bytes[index] == 34 {
                        index += 1
                        break
                    }
                    index += 1
                }
                continue
            }
            index += 1
        }
        return mask
    }

    private static func matchingBracket(in bytes: [UInt8], code: [Bool], at index: Int) -> Int? {
        let openers: [UInt8: UInt8] = [40: 41, 91: 93, 123: 125]
        let closers: [UInt8: UInt8] = [41: 40, 93: 91, 125: 123]
        let byte = bytes[index]
        if let close = openers[byte] {
            var stack: [UInt8] = [close]
            var cursor = index + 1
            while cursor < bytes.count {
                guard code[cursor] else { cursor += 1; continue }
                let next = bytes[cursor]
                if openers[next] != nil {
                    stack.append(openers[next]!)
                } else if closers[next] != nil {
                    guard stack.last == next else { return nil }
                    stack.removeLast()
                    if stack.isEmpty { return cursor }
                }
                cursor += 1
            }
            return nil
        }
        if let open = closers[byte] {
            var stack: [UInt8] = [open]
            var cursor = index - 1
            while cursor >= 0 {
                guard code[cursor] else { cursor -= 1; continue }
                let next = bytes[cursor]
                if closers[next] != nil {
                    stack.append(closers[next]!)
                } else if openers[next] != nil {
                    guard stack.last == next else { return nil }
                    stack.removeLast()
                    if stack.isEmpty { return cursor }
                }
                cursor -= 1
            }
        }
        return nil
    }

}
