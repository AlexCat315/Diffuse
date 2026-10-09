import Foundation

extension RopeNode {
    /// Height-aware AVL join visits only the taller tree's boundary path.
    static func join(_ left: RopeNode, _ right: RopeNode) -> RopeNode {
        if left.metrics.utf8Length == 0 { return right }
        if right.metrics.utf8Length == 0 { return left }
        if left.metrics.height > right.metrics.height + 1, case .branch(let branch) = left.storage {
            return balance(branch.left, join(branch.right, right))
        }
        if right.metrics.height > left.metrics.height + 1, case .branch(let branch) = right.storage {
            return balance(join(left, branch.left), branch.right)
        }
        if case .leaf(let a) = left.storage, case .leaf(let b) = right.storage, a.bytes.count + b.bytes.count <= maxLeafBytes {
            return RopeNode(leaf: RopeLeaf(a.text + b.text))
        }
        return RopeNode(left, right)
    }
    private static func balance(_ left: RopeNode, _ right: RopeNode) -> RopeNode {
        if left.metrics.height > right.metrics.height + 1, case .branch(let a) = left.storage {
            if a.left.metrics.height >= a.right.metrics.height { return RopeNode(a.left, RopeNode(a.right, right)) }
            if case .branch(let b) = a.right.storage { return RopeNode(RopeNode(a.left, b.left), RopeNode(b.right, right)) }
        }
        if right.metrics.height > left.metrics.height + 1, case .branch(let a) = right.storage {
            if a.right.metrics.height >= a.left.metrics.height { return RopeNode(RopeNode(left, a.left), a.right) }
            if case .branch(let b) = a.left.storage { return RopeNode(RopeNode(left, b.left), RopeNode(b.right, a.right)) }
        }
        return RopeNode(left, right)
    }
    /// An insertion/deletion can merge graphemes across the edited seam. Repair
    /// its edge leaves, including a regional-indicator run whose pairing changes.
    static func concatenate(_ left: RopeNode, _ right: RopeNode) -> RopeNode {
        if left.metrics.utf8Length == 0 { return right }
        if right.metrics.utf8Length == 0 { return left }
        if stableBoundary(left.lastLeaf.text, right.firstLeaf.text) { return join(left, right) }
        let edge = left.lastLeaf
        let (prefix, _) = left.split(atCharacter: left.metrics.characterCount - edge.characterCount)
        var text = edge.text, tail = right
        repeat {
            let leaf = tail.firstLeaf
            text.append(contentsOf: leaf.text)
            tail = tail.split(atCharacter: leaf.characterCount).1
        } while tail.metrics.utf8Length > 0 && !stableBoundary(text, tail.firstLeaf.text)
        return join(join(prefix, build(text)), tail)
    }
    private static func stableBoundary(_ left: String, _ right: String) -> Bool {
        guard let last = left.last, let first = right.first else { return true }
        // Counting alone misses RI re-pairing (three indicators still form two
        // characters). The first cluster's exact bytes must remain unchanged.
        let boundary = String(last) + String(first)
        return boundary.first.map { Array($0.utf8) == Array(last.utf8) } ?? true
    }
    func split(atCharacter index: Int) -> (RopeNode, RopeNode) {
        if index <= 0 { return (.empty, self) }
        if index >= metrics.characterCount { return (self, .empty) }
        switch storage {
        case .leaf(let leaf):
            let byte = leaf.characterBoundaries[index]
            return (RopeNode(leaf: RopeLeaf(String(decoding: leaf.bytes[..<byte], as: UTF8.self))),
                    RopeNode(leaf: RopeLeaf(String(decoding: leaf.bytes[byte...], as: UTF8.self))))
        case .branch(let branch):
            if index < branch.left.metrics.characterCount {
                let (a, b) = branch.left.split(atCharacter: index)
                return (a, Self.join(b, branch.right))
            }
            let (a, b) = branch.right.split(atCharacter: index - branch.left.metrics.characterCount)
            return (Self.join(branch.left, a), b)
        }
    }
}
