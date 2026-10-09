import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    public var roots: [EditorSceneNode] {
        scene.roots().map(buildNode)
    }

    @discardableResult
    public func moveEntity(_ entityID: UInt64,
                           to parentID: UInt64?,
                           at index: Int) -> TransactionApplyResult? {
        applySceneTransaction(intentVerb: "scene.move_entity",
                              summary: "Move entity in hierarchy",
                              targetRawIDs: [entityID] + (parentID.map { [$0] } ?? []),
                              mutations: [.moveEntity(entityID: entityID,
                                                      parentID: parentID,
                                                      index: index)])
    }

    /// Moves the top-level members of a hierarchy selection to the scene root
    /// as one undoable transaction. Selected descendants are intentionally
    /// omitted because moving their selected ancestor already preserves them.
    @discardableResult
    public func moveEntitiesToRoot(_ entityIDs: Set<UInt64>) -> Bool {
        let existingIDs = Set(entityIDs.filter { rawID in
            entity(from: rawID).map(scene.contains) == true
        })
        guard existingIDs.count == entityIDs.count, !existingIDs.isEmpty else { return false }

        // Preserve the hierarchy's visible depth-first order. Sorting entity
        // IDs is not a stable proxy for scene order after the user has
        // reordered siblings or moved entities between parents.
        var nestedIDs: [UInt64] = []
        func collect(_ entity: EntityID, hasSelectedAncestor: Bool) {
            let rawID = entity.rawValue
            let isSelected = existingIDs.contains(rawID)
            if isSelected, !hasSelectedAncestor, scene.parent(of: entity) != nil {
                nestedIDs.append(rawID)
            }
            for child in scene.children(of: entity) {
                collect(child, hasSelectedAncestor: hasSelectedAncestor || isSelected)
            }
        }
        for root in scene.roots() {
            collect(root, hasSelectedAncestor: false)
        }
        guard !nestedIDs.isEmpty else { return false }
        let startIndex = scene.roots().count
        let mutations = nestedIDs.enumerated().map { offset, rawID in
            SceneMutation.moveEntity(entityID: rawID,
                                     parentID: nil,
                                     index: startIndex + offset)
        }
        return applySceneTransaction(intentVerb: "scene.move_entities_to_root",
                                     summary: nestedIDs.count == 1
                                        ? "Move entity to root"
                                        : "Move entities to root",
                                     targetRawIDs: nestedIDs,
                                     mutations: mutations) != nil
    }

    /// Renames one entity through the same transactional path used by the
    /// Inspector. Empty names are rejected so inline rename can keep the draft
    /// visible and explain the error instead of silently substituting a name.
    @discardableResult
    public func renameEntity(_ rawID: UInt64, to proposedName: String) -> Bool {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let entity = entity(from: rawID),
              scene.contains(entity) else { return false }
        let current = scene.component(SceneNameComponent.self, for: entity)?.value
            ?? fallbackName(for: entity)
        guard current != trimmed else { return true }
        return applySceneTransaction(intentVerb: "scene.set_name",
                                     summary: "Rename entity",
                                     targetRawIDs: [rawID],
                                     mutations: [.setSceneName(entityID: rawID, value: trimmed)]) != nil
    }

    @discardableResult
    public func setHierarchyVisibility(_ isVisible: Bool,
                                       for entityIDs: Set<UInt64>) -> Bool {
        var renderableIDs = Set<UInt64>()
        func collect(_ entity: EntityID) {
            if scene.hasComponent(RenderMeshComponent.self, for: entity) {
                renderableIDs.insert(entity.rawValue)
            }
            for child in scene.children(of: entity) {
                collect(child)
            }
        }
        for rawID in entityIDs {
            guard let entity = entity(from: rawID), scene.contains(entity) else { continue }
            collect(entity)
        }
        let mutations = renderableIDs.sorted().compactMap { rawID -> SceneMutation? in
            guard let entity = entity(from: rawID),
                  let mesh = scene.component(RenderMeshComponent.self, for: entity),
                  mesh.isVisible != isVisible else { return nil }
            return .componentFields(entityID: rawID, typeID: "renderMesh", fields: ["isVisible": (isVisible)])
        }
        guard !mutations.isEmpty else { return false }
        return applySceneTransaction(intentVerb: "scene.set_hierarchy_visibility",
                                     summary: isVisible ? "Show hierarchy entities" : "Hide hierarchy entities",
                                     targetRawIDs: renderableIDs.sorted(),
                                     mutations: mutations) != nil
    }

    public func isHierarchyVisible(_ rawID: UInt64) -> Bool {
        guard let root = entity(from: rawID), scene.contains(root) else { return true }
        var visibility: [Bool] = []
        func collect(_ entity: EntityID) {
            if let mesh = scene.component(RenderMeshComponent.self, for: entity) {
                visibility.append(mesh.isVisible)
            }
            for child in scene.children(of: entity) {
                collect(child)
            }
        }
        collect(root)
        return visibility.allSatisfy { $0 }
    }

    public func hierarchyHasRenderableContent(_ rawID: UInt64) -> Bool {
        guard let root = entity(from: rawID), scene.contains(root) else { return false }
        func containsRenderable(_ entity: EntityID) -> Bool {
            if scene.hasComponent(RenderMeshComponent.self, for: entity) { return true }
            return scene.children(of: entity).contains(where: containsRenderable)
        }
        return containsRenderable(root)
    }

    public func setEntityLocked(_ isLocked: Bool, entityIDs: Set<UInt64>) {
        guard isAuthoringEnabled else {
            onTransactionError?("Stop simulation before changing hierarchy locks")
            return
        }
        var changed = false
        for rawID in entityIDs.sorted() {
            guard let entity = entity(from: rawID), scene.contains(entity) else { continue }
            let wasLocked = scene.hasComponent(EditorHierarchyLockComponent.self, for: entity)
            guard wasLocked != isLocked else { continue }
            if isLocked {
                changed = scene.setComponent(EditorHierarchyLockComponent(), for: entity) || changed
            } else {
                changed = scene.removeComponent(EditorHierarchyLockComponent.self, from: entity) != nil || changed
            }
        }
        if changed {
            notifyRevisionChanged()
        }
    }

    public func isEntityLocked(_ rawID: UInt64) -> Bool {
        guard let entity = entity(from: rawID), scene.contains(entity) else { return false }
        return scene.hasComponent(EditorHierarchyLockComponent.self, for: entity)
    }

    private func buildNode(_ entity: EntityID) -> EditorSceneNode {
        EditorSceneNode(
            id: entity.rawValue,
            name: displayName(for: entity),
            kind: displayKind(for: entity),
            children: scene.children(of: entity).map(buildNode)
        )
    }
}
