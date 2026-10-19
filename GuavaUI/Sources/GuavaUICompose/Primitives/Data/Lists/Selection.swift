internal import GuavaUIRuntime


/// The selection a collection writes to: one optional ID or a set of IDs.
/// Callers never see this type; they pass the matching binding to the
/// collection's initializer, as with SwiftUI's `List(selection:)`.
struct CollectionSelection<ID: Hashable> {
    private enum Storage {
        case single(Binding<ID?>)
        case multiple(Binding<Set<ID>>)
    }
    private let storage: Storage

    static func single(_ binding: Binding<ID?>) -> Self { Self(storage: .single(binding)) }
    static func multiple(_ binding: Binding<Set<ID>>) -> Self { Self(storage: .multiple(binding)) }

    /// Multiple selection enables Shift ranges, Cmd/Ctrl toggles, Space and select-all.
    var allowsMultiple: Bool {
        if case .multiple = storage { return true }
        return false
    }

    func contains(_ id: ID) -> Bool {
        switch storage {
        case .single(let binding): return binding.wrappedValue == id
        case .multiple(let binding): return binding.wrappedValue.contains(id)
        }
    }

    /// The single selected ID, or any member of a multiple selection.
    var first: ID? {
        switch storage {
        case .single(let binding): return binding.wrappedValue
        case .multiple(let binding): return binding.wrappedValue.first
        }
    }

    func replace(with ids: some Sequence<ID>) {
        switch storage {
        case .single(let binding):
            var last: ID?
            for id in ids { last = id }
            if binding.wrappedValue != last { binding.wrappedValue = last }
        case .multiple(let binding):
            let next = Set(ids)
            if binding.wrappedValue != next { binding.wrappedValue = next }
        }
    }

    func toggle(_ id: ID) {
        switch storage {
        case .single(let binding): binding.wrappedValue = id
        case .multiple(let binding):
            var next = binding.wrappedValue
            if next.remove(id) == nil { next.insert(id) }
            binding.wrappedValue = next
        }
    }
}
