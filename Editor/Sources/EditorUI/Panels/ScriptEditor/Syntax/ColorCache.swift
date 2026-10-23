/// A bounded cache for the current syntax snapshot, shared by source glyphs
/// and the minimap. Plain text positions are cached as well as colored tokens.
final class ScriptSyntaxColorCache {
    private enum Entry { case plain, token(SwiftSyntaxTokenKind) }
    private var entries: [Int: Entry] = [:]
    private let capacity = 8_192

    func kind(at offset: Int, resolve: () -> SwiftSyntaxTokenKind?) -> SwiftSyntaxTokenKind? {
        if let entry = entries[offset] {
            if case .token(let kind) = entry { return kind }
            return nil
        }
        let kind = resolve()
        if entries.count >= capacity { entries.removeAll(keepingCapacity: true) }
        entries[offset] = kind.map(Entry.token) ?? .plain
        return kind
    }

    func invalidate() { entries.removeAll(keepingCapacity: true) }
}
