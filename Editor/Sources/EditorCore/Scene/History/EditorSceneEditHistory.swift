import IntentRuntime
import SceneRuntime

/// Owns snapshot history and grouping; the adapter owns scene replacement and
/// revision notifications. A history entry is created only for a changed revision.
final class EditorSceneEditHistory {
    private enum Entry {
        case scene(SceneRuntime)
        case asset(undo: () -> Bool, redo: () -> Bool)
    }
    private let limit: Int
    private var currentScene: SceneRuntime?
    private var undoScenes: [Entry] = []
    private var redoScenes: [Entry] = []
    private var groupDepth = 0
    private var groupStartScene: SceneRuntime?
    private var isInteractiveGroupActive = false
    private var interactiveComponentKeys: Set<SceneComponentKey>?
    private var hasInteractiveRevision = false

    init(limit: Int = 100) {
        self.limit = limit
    }

    var canUndo: Bool { !undoScenes.isEmpty }
    var canRedo: Bool { !redoScenes.isEmpty }

    /// A file relocation changes identities in every snapshot. Undoing a
    /// transform must not bring back a resource path that no longer exists.
    func remapScenes(_ update: (inout SceneRuntime) -> Void) {
        if currentScene != nil { update(&currentScene!) }
        for index in undoScenes.indices {
            if case var .scene(scene) = undoScenes[index] { update(&scene); undoScenes[index] = .scene(scene) }
        }
        for index in redoScenes.indices {
            if case var .scene(scene) = redoScenes[index] { update(&scene); redoScenes[index] = .scene(scene) }
        }
        if groupStartScene != nil { update(&groupStartScene!) }
    }

    func recordRevisionChange(to scene: SceneRuntime, recordHistory: Bool,
                              componentKeys: Set<SceneComponentKey>? = nil) {
        if recordHistory, let previous = currentScene {
            if groupDepth == 0 {
                record(previous, replacingWith: scene)
            } else if isInteractiveGroupActive, groupDepth == 1 {
                if hasInteractiveRevision, interactiveComponentKeys != componentKeys,
                   let start = groupStartScene {
                    record(start, replacingWith: previous)
                    groupStartScene = previous
                }
                interactiveComponentKeys = componentKeys
                hasInteractiveRevision = true
            }
        }
        currentScene = scene
    }

    func beginGroup(in scene: SceneRuntime) {
        if groupDepth == 0 {
            groupStartScene = currentScene ?? scene
        }
        groupDepth += 1
    }

    func endGroup(in scene: SceneRuntime) {
        guard groupDepth > 0 else { return }
        groupDepth -= 1
        if groupDepth == 0 {
            if let previous = groupStartScene {
                record(previous, replacingWith: scene)
            }
            groupStartScene = nil
            currentScene = scene
        }
    }

    func beginInteractiveGroup(in scene: SceneRuntime) {
        guard !isInteractiveGroupActive else { return }
        interactiveComponentKeys = nil
        hasInteractiveRevision = false
        isInteractiveGroupActive = true
        beginGroup(in: scene)
    }

    func endInteractiveGroup(in scene: SceneRuntime) {
        guard isInteractiveGroupActive else { return }
        isInteractiveGroupActive = false
        interactiveComponentKeys = nil
        endGroup(in: scene)
    }

    func cancelInteractiveGroup() -> SceneRuntime? {
        guard isInteractiveGroupActive else { return nil }
        isInteractiveGroupActive = false
        interactiveComponentKeys = nil
        guard groupDepth > 0 else { return nil }
        groupDepth -= 1
        guard groupDepth == 0 else { return nil }
        let previous = groupStartScene
        if let previous {
            currentScene = previous
        }
        groupStartScene = nil
        return previous
    }

    func undo(replacing scene: SceneRuntime) -> SceneRuntime? {
        guard let entry = undoScenes.last else { return nil }
        switch entry {
        case let .scene(previous):
            undoScenes.removeLast()
            redoScenes.append(.scene(scene))
            currentScene = previous
            return previous
        case let .asset(undo, _):
            guard undo() else { return nil }
            undoScenes.removeLast()
            redoScenes.append(entry)
            return currentScene ?? scene
        }
    }

    func redo(replacing scene: SceneRuntime) -> SceneRuntime? {
        guard let entry = redoScenes.last else { return nil }
        switch entry {
        case let .scene(next):
            redoScenes.removeLast()
            undoScenes.append(.scene(scene))
            currentScene = next
            return next
        case let .asset(_, redo):
            guard redo() else { return nil }
            redoScenes.removeLast()
            undoScenes.append(entry)
            return currentScene ?? scene
        }
    }

    /// File-backed authoring edits share chronological ordering with scene edits.
    /// A failed restore keeps the entry available instead of consuming history.
    func recordAssetEdit(undo: @escaping () -> Bool, redo: @escaping () -> Bool) {
        undoScenes.append(.asset(undo: undo, redo: redo))
        trimHistory()
        redoScenes.removeAll(keepingCapacity: true)
    }

    func reset(to scene: SceneRuntime) {
        undoScenes.removeAll(keepingCapacity: true)
        redoScenes.removeAll(keepingCapacity: true)
        groupDepth = 0
        groupStartScene = nil
        isInteractiveGroupActive = false
        interactiveComponentKeys = nil
        currentScene = scene
    }

    private func record(_ previous: SceneRuntime, replacingWith scene: SceneRuntime) {
        guard previous.snapshot.revision != scene.snapshot.revision else { return }
        undoScenes.append(.scene(previous))
        trimHistory()
        redoScenes.removeAll(keepingCapacity: true)
    }

    private func trimHistory() {
        if undoScenes.count > limit {
            undoScenes.removeFirst(undoScenes.count - limit)
        }
    }
}
