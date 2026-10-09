#if os(macOS)
/// Owns immutable native bindings and invalidates only sets that reference a
/// retired resource. Called under the frontend's device/frame synchronization.
final class MetalBindingRegistry {
    private var sets: [UInt32: MetalBindingSet] = [:]
    private var users: [UInt32: Set<UInt32>] = [:]

    subscript(id: UInt32) -> MetalBindingSet? {
        get { sets[id] }
        set {
            remove(id)
            guard let newValue else { return }
            sets[id] = newValue
            for entry in newValue.entries { users[entry.resource.id, default: []].insert(id) }
        }
    }

    private func remove(_ id: UInt32) {
        guard let old = sets.removeValue(forKey: id) else { return }
        for entry in old.entries {
            let resource = entry.resource.id
            users[resource]?.remove(id)
            if users[resource]?.isEmpty == true { users[resource] = nil }
        }
    }

    /// Retirement has already waited for every frame that could use these sets.
    func removeAll(referencing resource: UInt32) {
        guard let dependents = users[resource] else { return }
        for id in dependents { remove(id) }
    }
}
#endif
