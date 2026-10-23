import Foundation

extension PluginManager {
    func dependents(of id: String) -> [String] {
        let capabilities = lock.withLock { Set(entries[id]?.inspection.contracts.map(\.id) ?? []) }
        return PluginRequirementResolver.dependents(of: id, providing: capabilities, among: enabledManifests)
    }

    func dependentClosure(of id: String) -> [String] {
        var seen = Set<String>(), ordered: [String] = []
        func visit(_ id: String) {
            guard seen.insert(id).inserted else { return }
            for dependent in dependents(of: id) { visit(dependent) }
            ordered.append(id)
        }
        visit(id)
        return ordered
    }

    @MainActor
    func withdraw(_ ids: [String], failure: String?) async throws {
        var firstError: (any Error)?
        let requested = Set(ids)
        var seen = Set<String>()
        let ordered = ids.flatMap { dependentClosure(of: $0) }.filter { requested.contains($0) && seen.insert($0).inserted }
        for id in ordered {
            let removed = lock.withLock { () -> (DisposalScope?, PluginExecutionBinding?, PluginRuntimeDriver?) in
                guard let entry = entries[id] else { return (nil, nil, driver) }
                let previous = (entry.scope, entry.binding, driver)
                entry.scope = nil; entry.binding = nil; entry.failure = failure
                return previous
            }
            do { try removed.0?.dispose() } catch { if firstError == nil { firstError = error } }
            if let binding = removed.1, let driver = removed.2 {
                do { try await driver.deactivate(binding) } catch { if firstError == nil { firstError = error } }
            }
        }
        if let firstError { throw firstError }
    }
}
