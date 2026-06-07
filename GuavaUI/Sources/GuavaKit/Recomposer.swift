// Tracks whether a recompose is pending. A `@State` write flags this; the host
// drains it once per frame via `ViewGraph.commitIfNeeded`. (Stage 5 re-reconciles
// the whole tree on any change — correct and simple; per-scope incremental
// recompose is a later optimization that this flag set already anticipates.)
public final class Recomposer {
    private var dirtyScopes: Set<ScopePath> = []

    public var hasPending: Bool { !dirtyScopes.isEmpty }

    func markDirty(_ path: ScopePath) { dirtyScopes.insert(path) }
    func drain() -> Set<ScopePath> { defer { dirtyScopes.removeAll() }; return dirtyScopes }
}
