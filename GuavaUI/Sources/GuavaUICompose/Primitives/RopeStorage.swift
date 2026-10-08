import Foundation

/// Valid UTF-8, cut only at extended grapheme boundaries. A single grapheme can
/// exceed the nominal chunk size (for example a long sequence of combining marks);
/// preserving that grapheme takes precedence over the 1024-byte packing target.
public final class RopeLeaf: Sendable {
    public let bytes: [UInt8]
    let text: String
    let characterBoundaries: [Int]
    let newlineCharacters: [Int]
    let utf16Length: Int
    let lineFeedBytes: [Int]

    init(_ text: String) {
        self.text = text; bytes = Array(text.utf8); utf16Length = text.utf16.count
        var boundaries = [0], newlines: [Int] = [], byte = 0
        for (index, character) in text.enumerated() {
            if character.isNewline { newlines.append(index) }
            byte += character.utf8.count; boundaries.append(byte)
        }
        characterBoundaries = boundaries; newlineCharacters = newlines
        lineFeedBytes = Array(text.utf8).enumerated().compactMap { $0.element == 10 ? $0.offset : nil }
    }
    var characterCount: Int { characterBoundaries.count - 1 }
}

/// A parser can read from the requested byte without materializing the document.
public struct RopeChunk: Sendable {
    public let leaf: RopeLeaf
    public let utf8Offset: Int
    public let startIndex: Int
    public var bytes: ArraySlice<UInt8> { leaf.bytes[startIndex...] }
}
struct RopeMetrics: Sendable {
    let utf8Length: Int
    let characterCount: Int
    let newlineCount: Int
    let lineFeedCount: Int
    let utf16Length: Int
    let height: Int
}
struct RopeBranch: Sendable {
    let left: RopeNode
    let right: RopeNode
}
enum RopeStorage: Sendable {
    case leaf(RopeLeaf)
    case branch(RopeBranch)
}
final class RopeNode: Sendable {
    static let maxLeafBytes = 1024
    static let empty = RopeNode(leaf: RopeLeaf(""))
    let storage: RopeStorage
    let metrics: RopeMetrics
    init(leaf: RopeLeaf) {
        storage = .leaf(leaf)
        metrics = RopeMetrics(utf8Length: leaf.bytes.count, characterCount: leaf.characterCount, newlineCount: leaf.newlineCharacters.count, lineFeedCount: leaf.lineFeedBytes.count,
                              utf16Length: leaf.utf16Length, height: leaf.bytes.isEmpty ? 0 : 1)
    }
    init(_ left: RopeNode, _ right: RopeNode) {
        storage = .branch(RopeBranch(left: left, right: right))
        metrics = RopeMetrics(utf8Length: left.metrics.utf8Length + right.metrics.utf8Length,
                              characterCount: left.metrics.characterCount + right.metrics.characterCount,
                              newlineCount: left.metrics.newlineCount + right.metrics.newlineCount,
                              lineFeedCount: left.metrics.lineFeedCount + right.metrics.lineFeedCount,
                              utf16Length: left.metrics.utf16Length + right.metrics.utf16Length,
                              height: max(left.metrics.height, right.metrics.height) + 1)
    }
    var firstLeaf: RopeLeaf {
        switch storage { case .leaf(let leaf): return leaf; case .branch(let branch): return branch.left.firstLeaf }
    }
    var lastLeaf: RopeLeaf {
        switch storage { case .leaf(let leaf): return leaf; case .branch(let branch): return branch.right.lastLeaf }
    }
    static func build(_ string: String) -> RopeNode {
        var leaves: [RopeNode] = [], text = "", byteCount = 0
        for character in string {
            let size = character.utf8.count
            if byteCount > 0, byteCount + size > maxLeafBytes {
                leaves.append(RopeNode(leaf: RopeLeaf(text))); text = ""; byteCount = 0
            }
            text.append(character); byteCount += size
        }
        if !text.isEmpty { leaves.append(RopeNode(leaf: RopeLeaf(text))) }
        return balanced(leaves[...])
    }
    private static func balanced(_ leaves: ArraySlice<RopeNode>) -> RopeNode {
        if leaves.isEmpty { return .empty }
        if leaves.count == 1 { return leaves.first! }
        let middle = leaves.index(leaves.startIndex, offsetBy: leaves.count / 2)
        return RopeNode(balanced(leaves[..<middle]), balanced(leaves[middle...]))
    }
}
