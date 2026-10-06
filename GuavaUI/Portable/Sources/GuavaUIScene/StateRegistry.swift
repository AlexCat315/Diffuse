import Foundation

/// Scene-thread registry. Values are evaluated only for explicitly watched IDs.
/// Registration exposes a read-only summary and never installs a write handler.
public final class StateRegistry {
    public struct Descriptor: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var valueType: String
        public var scopeID: String?
    }
    public struct Value: Codable, Equatable, Sendable {
        public var id: String
        public var summary: String
        public var truncated: Bool
    }
    private struct Entry {
        var descriptor: Descriptor
        var read: () -> String
    }
    private var entries: [String: Entry] = [:]
    private var nextID: UInt64 = 0
    public init() {}

    /// Returns a token that must be unregistered when the provider is removed.
    /// Compose automatically handles this lifecycle for exposed @State fields.
    @discardableResult
    public func register(id stableID: String? = nil, name: String, valueType: String, scopeID: String? = nil,
                         read: @escaping () -> String) -> String? {
        if let stableID { guard !stableID.isEmpty, stableID.utf8.count <= 256 else { return nil } }
        guard entries.count < 512 || stableID.map({ entries[$0] != nil }) == true else { return nil }
        nextID &+= 1
        let id = stableID ?? "provider.\(nextID)"
        entries[id] = Entry(descriptor: Descriptor(id: id, name: String(name.prefix(160)),
            valueType: String(valueType.prefix(160)), scopeID: scopeID), read: read)
        return id
    }
    public func unregister(_ id: String) { entries.removeValue(forKey: id) }
    public var descriptors: [Descriptor] {
        entries.values.map(\.descriptor).sorted { $0.id < $1.id }
    }
    public func values(for ids: [String]) -> [Value] {
        var seen = Set<String>()
        return ids.prefix(128).compactMap { id in
            guard seen.insert(id).inserted, let entry = entries[id] else { return nil }
            let text = entry.read()
            return Value(id: id, summary: String(text.prefix(1024)), truncated: text.count > 1024)
        }
    }
}
