import Foundation

extension RopeNode {
    func utf8Offset(characterIndex index: Int) -> Int {
        switch storage {
        case .leaf(let leaf): return leaf.characterBoundaries[index]
        case .branch(let b):
            if index < b.left.metrics.characterCount { return b.left.utf8Offset(characterIndex: index) }
            return b.left.metrics.utf8Length + b.right.utf8Offset(characterIndex: index - b.left.metrics.characterCount)
        }
    }
    func characterIndex(utf8Offset offset: Int) -> Int {
        switch storage {
        case .leaf(let leaf): return Self.lowerBound(leaf.characterBoundaries, offset)
        case .branch(let b):
            if offset < b.left.metrics.utf8Length { return b.left.characterIndex(utf8Offset: offset) }
            return b.left.metrics.characterCount + b.right.characterIndex(utf8Offset: offset - b.left.metrics.utf8Length)
        }
    }
    func utf16Offset(characterIndex index: Int) -> Int {
        switch storage {
        case .leaf(let leaf): return String(decoding: leaf.bytes[..<leaf.characterBoundaries[index]], as: UTF8.self).utf16.count
        case .branch(let b):
            if index < b.left.metrics.characterCount { return b.left.utf16Offset(characterIndex: index) }
            return b.left.metrics.utf16Length + b.right.utf16Offset(characterIndex: index - b.left.metrics.characterCount)
        }
    }
    func newlineCharacterIndex(ordinal: Int) -> Int {
        switch storage {
        case .leaf(let leaf): return leaf.newlineCharacters[ordinal]
        case .branch(let b):
            if ordinal < b.left.metrics.newlineCount { return b.left.newlineCharacterIndex(ordinal: ordinal) }
            return b.left.metrics.characterCount + b.right.newlineCharacterIndex(ordinal: ordinal - b.left.metrics.newlineCount)
        }
    }
    func newlines(beforeCharacter index: Int) -> Int {
        switch storage {
        case .leaf(let leaf): return Self.lowerBound(leaf.newlineCharacters, index)
        case .branch(let b):
            if index < b.left.metrics.characterCount { return b.left.newlines(beforeCharacter: index) }
            return b.left.metrics.newlineCount + b.right.newlines(beforeCharacter: index - b.left.metrics.characterCount)
        }
    }
    func lineFeeds(beforeByte offset: Int) -> Int {
        switch storage {
        case .leaf(let leaf): return Self.lowerBound(leaf.lineFeedBytes, offset)
        case .branch(let b):
            if offset < b.left.metrics.utf8Length { return b.left.lineFeeds(beforeByte: offset) }
            return b.left.metrics.lineFeedCount + b.right.lineFeeds(beforeByte: offset - b.left.metrics.utf8Length)
        }
    }
    func lineFeedByteIndex(ordinal: Int) -> Int {
        switch storage {
        case .leaf(let leaf): return leaf.lineFeedBytes[ordinal]
        case .branch(let b):
            if ordinal < b.left.metrics.lineFeedCount { return b.left.lineFeedByteIndex(ordinal: ordinal) }
            return b.left.metrics.utf8Length + b.right.lineFeedByteIndex(ordinal: ordinal - b.left.metrics.lineFeedCount)
        }
    }
    func utf8Offset(utf16Offset offset: Int) -> Int {
        switch storage {
        case .leaf(let leaf):
            var byte = 0, codeUnit = 0
            for scalar in leaf.text.unicodeScalars {
                if codeUnit >= offset { return byte }
                byte += scalar.utf8.count; codeUnit += scalar.utf16.count
            }
            return byte
        case .branch(let b):
            if offset < b.left.metrics.utf16Length { return b.left.utf8Offset(utf16Offset: offset) }
            return b.left.metrics.utf8Length + b.right.utf8Offset(utf16Offset: offset - b.left.metrics.utf16Length)
        }
    }
    func utf16Offset(utf8Offset offset: Int) -> Int {
        switch storage {
        case .leaf(let leaf):
            var byte = 0, codeUnit = 0
            for scalar in leaf.text.unicodeScalars {
                if byte >= offset { return codeUnit }
                byte += scalar.utf8.count; codeUnit += scalar.utf16.count
            }
            return codeUnit
        case .branch(let b):
            if offset < b.left.metrics.utf8Length { return b.left.utf16Offset(utf8Offset: offset) }
            return b.left.metrics.utf16Length + b.right.utf16Offset(utf8Offset: offset - b.left.metrics.utf8Length)
        }
    }
    static func lowerBound(_ array: [Int], _ target: Int) -> Int {
        var lower = 0, upper = array.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if array[middle] < target { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
    func leaves(in range: Range<Int>) -> [RopeLeaf] {
        if range.isEmpty { return [] }
        switch storage {
        case .leaf(let leaf): return [leaf]
        case .branch(let b):
            let split = b.left.metrics.utf8Length
            var result: [RopeLeaf] = []
            if range.lowerBound < split { result.append(contentsOf: b.left.leaves(in: range.lowerBound..<min(split, range.upperBound))) }
            if range.upperBound > split { result.append(contentsOf: b.right.leaves(in: max(0, range.lowerBound - split)..<(range.upperBound - split))) }
            return result
        }
    }
    func appendBytes(in range: Range<Int>, to result: inout [UInt8]) {
        if range.isEmpty { return }
        switch storage {
        case .leaf(let leaf): result.append(contentsOf: leaf.bytes[range])
        case .branch(let b):
            let split = b.left.metrics.utf8Length
            if range.lowerBound < split { b.left.appendBytes(in: range.lowerBound..<min(split, range.upperBound), to: &result) }
            if range.upperBound > split { b.right.appendBytes(in: max(0, range.lowerBound - split)..<(range.upperBound - split), to: &result) }
        }
    }
    func chunk(at offset: Int, base: Int) -> RopeChunk {
        switch storage {
        case .leaf(let leaf): return RopeChunk(leaf: leaf, utf8Offset: base, startIndex: offset)
        case .branch(let b):
            let split = b.left.metrics.utf8Length
            return offset < split ? b.left.chunk(at: offset, base: base) : b.right.chunk(at: offset - split, base: base + split)
        }
    }
}
