import IntentRuntime
import SceneRuntime

/// Owns snapshot history and grouping; the adapter owns scene replacement and
/// revision notifications. A history entry is created only for a changed revision.
final class EditorSceneEditHistory {
    private let limit: Int
    private var currentScene: SceneRuntime?
    private var undoScenes: [SceneRuntime] = []
    private var redoScenes: [SceneRuntime] = []
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
        for index in undoScenes.indices { update(&undoScenes[index]) }
        for index in redoScenes.indices { update(&redoScenes[index]) }
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
        guard let previous = undoScenes.popLast() else { return nil }
        redoScenes.append(scene)
        currentScene = previous
        return previous
    }

    func redo(replacing scene: SceneRuntime) -> SceneRuntime? {
        guard let next = redoScenes.popLast() else { return nil }
        undoScenes.append(scene)
        currentScene = next
        return next
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
        undoScenes.append(previous)
        if undoScenes.count > limit {
            undoScenes.removeFirst(undoScenes.count - limit)
        }
        redoScenes.removeAll(keepingCapacity: true)
    }
}
