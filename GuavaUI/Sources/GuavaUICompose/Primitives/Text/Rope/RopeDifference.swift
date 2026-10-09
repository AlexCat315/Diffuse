/// Compares boundary paths, skipping identical persistent subtrees in O(1).
/// Byte comparisons are confined to changed leaves and non-shared input text.
enum RopeDifference {
    private struct Cursor {
        var nodes: [RopeNode]
        var byteOffset = 0
        let fromEnd: Bool
        init(_ root: RopeNode, fromEnd: Bool) { nodes = [root]; self.fromEnd = fromEnd }
        mutating func expand() {
            guard let node = nodes.last, case .branch(let b) = node.storage else { return }
            nodes.removeLast()
            if fromEnd { nodes.append(b.left); nodes.append(b.right) }
            else { nodes.append(b.right); nodes.append(b.left) }
        }
        mutating func consume(_ count: Int) {
            byteOffset += count
            if let node = nodes.last, byteOffset == node.metrics.utf8Length { nodes.removeLast(); byteOffset = 0 }
        }
    }
    static func commonBytes(_ previous: RopeNode, _ current: RopeNode, fromEnd: Bool, limit: Int) -> Int {
        var a = Cursor(previous, fromEnd: fromEnd), b = Cursor(current, fromEnd: fromEnd), matched = 0
        while matched < limit, let left = a.nodes.last, let right = b.nodes.last {
            if left === right, a.byteOffset == 0, b.byteOffset == 0 {
                let count = min(left.metrics.utf8Length, limit - matched)
                a.consume(count); b.consume(count); matched += count
                continue
            }
            if left.metrics.height > 1 || right.metrics.height > 1 {
                if left.metrics.height >= right.metrics.height { a.expand() }
                if right.metrics.height >= left.metrics.height { b.expand() }
                continue
            }
            guard case .leaf(let la) = left.storage, case .leaf(let lb) = right.storage else { break }
            let count = min(la.bytes.count - a.byteOffset, lb.bytes.count - b.byteOffset, limit - matched)
            if count == 0 { return matched }
            for index in 0..<count {
                let ai = fromEnd ? la.bytes.count - 1 - a.byteOffset - index : a.byteOffset + index
                let bi = fromEnd ? lb.bytes.count - 1 - b.byteOffset - index : b.byteOffset + index
                if la.bytes[ai] != lb.bytes[bi] { return matched + index }
            }
            a.consume(count); b.consume(count); matched += count
        }
        return matched
    }
}
