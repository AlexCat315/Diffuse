import EditorCore
import EngineKernel
import Foundation
import GuavaUICompose
import GuavaUIRuntime

struct HierarchyPanel: View {
    let store: EditorStore
    let scene: EditorSceneAdapter
    private let sessionState: HierarchyPanelSessionState

    @State private var expandedKeys: Set<TreeNodeKey<UInt64>>
    @State private var searchQuery: String
    @State private var renamingEntityID: UInt64?
    @State private var renameDraft: String
    @State private var renameFocusRequestID: UInt64

    init(store: EditorStore, scene: EditorSceneAdapter) {
        self.store = store
        self.scene = scene
        let sessionState = HierarchyPanelSessionRegistry.state(
            for: store,
            defaultExpandedEntityIDs: scene.defaultExpandedEntityIDs
        )
        self.sessionState = sessionState
        _expandedKeys = State(wrappedValue: Self.expandedKeys(
            entityIDs: sessionState.expandedEntityIDs,
            roots: scene.roots
        ))
        _searchQuery = State(wrappedValue: sessionState.searchQuery)
        _renamingEntityID = State(wrappedValue: nil)
        _renameDraft = State(wrappedValue: "")
        _renameFocusRequestID = State(wrappedValue: 0)
    }

    var body: some View {
        StoreScope(store) { store in
            let _ = store.sceneRevision
            let hierarchyRoots = scene.roots
            let parentKeys = Self.parentKeys(in: hierarchyRoots)
            let trimmedSearchQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchingEntityIDs = HierarchyPanelModel.matchingEntityIDs(
                in: hierarchyRoots,
                query: trimmedSearchQuery
            )
            let matchingEntityCount = trimmedSearchQuery.isEmpty
                ? scene.entityCount
                : matchingEntityIDs.count
            let isAuthoringEnabled = EditorSceneAuthoringPolicy.canEditScene(
                during: store.playbackState
            )
            let keysByID = Self.keyIndex(in: hierarchyRoots)
            let currentExpandedKeys = Set(expandedKeys.compactMap { key in
                keysByID[key.id]?.first
            })
            let selectedIDs = store.selectedEntityIDs
            let primaryEntity = scene.entitySummary(id: store.selectedEntityID)
            let containsLockedSelection = selectedIDs.contains { scene.isEntityLocked($0) }
            let containsRenderableSelection = selectedIDs.contains {
                scene.hierarchyHasRenderableContent($0)
            }
            let allSelectionHidden = !selectedIDs.isEmpty && selectedIDs.allSatisfy {
                !scene.isHierarchyVisible($0)
            }
            let allSelectionLocked = !selectedIDs.isEmpty && selectedIDs.allSatisfy {
                scene.isEntityLocked($0)
            }
            let canMoveSelectionToRoot = selectedIDs.contains {
                !HierarchyPanelModel.ancestorIDs(of: $0, in: hierarchyRoots).isEmpty
            }
            let searchTextBinding = Binding<String>(
                get: { searchQuery },
                set: updateSearchQuery
            )
            let expandedKeysBinding = Binding<Set<TreeNodeKey<UInt64>>>(
                get: { currentExpandedKeys },
                set: replaceExpandedKeys
            )
            let selectionKey = Binding<TreeNodeKey<UInt64>?>(
                get: {
                    guard let selected = store.selectedEntityID else { return nil }
                    return keysByID[selected]?.first
                },
                set: { next in
                    let nextID = next?.id
                    if store.selectedEntityID != nextID {
                        store.dispatch(.setPrimarySelectedEntity(nextID))
                    }
                }
            )
            let multiSelectionKeys = Binding<Set<TreeNodeKey<UInt64>>>(
                get: {
                    Set(store.selectedEntityIDs.compactMap { keysByID[$0]?.first })
                },
                set: { next in
                    let nextIDs = Set(next.map(\ .id))
                    if store.selectedEntityIDs != nextIDs {
                        store.dispatch(.setSelectedEntities(nextIDs))
                    }
                }
            )

            Box(direction: .column, alignItems: .stretch) {
                HierarchyPanelHeader(entityCount: scene.entityCount,
                                     selectionCount: store.selectedEntityIDsCount,
                                     isAuthoringEnabled: isAuthoringEnabled,
                                     selectedParent: primaryEntity.flatMap { entity in
                                        scene.isEntityLocked(entity.id) ? nil : entity
                                     },
                                     selectionActions: hierarchyActionEntries(
                                        selectedIDs: selectedIDs,
                                        roots: hierarchyRoots,
                                        isAuthoringEnabled: isAuthoringEnabled,
                                        containsLockedSelection: containsLockedSelection,
                                        containsRenderableSelection: containsRenderableSelection,
                                        allSelectionHidden: allSelectionHidden,
                                        allSelectionLocked: allSelectionLocked,
                                        canMoveSelectionToRoot: canMoveSelectionToRoot
                                     ),
                                     onCreateEntity: { template, parentID in
                        guard isAuthoringEnabled else { return }
                        guard let newID = scene.spawnEntity(template: template,
                                                            parentID: parentID) else {
                            log("Could not create entity", severity: .error,
                                detail: template.displayName)
                            return
                        }
                        store.dispatch(.setSelectedEntity(newID))
                        if let parentID,
                           let parentKey = keysByID[parentID]?.first {
                            insertExpandedKey(parentKey)
                        }
                    })

                Divider()

                EditorPanelSearchBar(
                    L("Search Hierarchy"),
                    text: searchTextBinding,
                    summary: trimmedSearchQuery.isEmpty
                        ? nil
                        : "\(matchingEntityCount) / \(scene.entityCount)",
                    onSubmit: {
                        selectSearchMatch(.next,
                                          matchingIDs: matchingEntityIDs,
                                          roots: hierarchyRoots)
                    },
                    onCancel: {
                        updateSearchQuery("")
                    }
                ) {
                    if !trimmedSearchQuery.isEmpty {
                        EditorPanelIconButton(UICommonIcons.chevronUp,
                                              tooltip: L("Previous Match"),
                                              isEnabled: !matchingEntityIDs.isEmpty) {
                            selectSearchMatch(.previous,
                                              matchingIDs: matchingEntityIDs,
                                              roots: hierarchyRoots)
                        }
                        EditorPanelIconButton(UICommonIcons.chevronDown,
                                              tooltip: L("Next Match"),
                                              isEnabled: !matchingEntityIDs.isEmpty) {
                            selectSearchMatch(.next,
                                              matchingIDs: matchingEntityIDs,
                                              roots: hierarchyRoots)
                        }
                    } else {
                        EditorPanelIconButton(UICommonIcons.chevronDown,
                                              tooltip: L("Expand All"),
                                              isEnabled: !parentKeys.isEmpty) {
                            replaceExpandedKeys(parentKeys)
                        }
                        EditorPanelIconButton(UICommonIcons.chevronRight,
                                              tooltip: L("Collapse All"),
                                              isEnabled: !currentExpandedKeys.isEmpty) {
                            replaceExpandedKeys([])
                        }
                    }
                }

                Divider()

                if hierarchyRoots.isEmpty {
                    EditorPanelEmptyState(
                        L("Scene is empty"),
                        detail: L("Create an entity to begin building the scene.")
                    )
                    .flex()
                } else if !trimmedSearchQuery.isEmpty && matchingEntityCount == 0 {
                    EditorPanelEmptyState(
                        L("No matching entities"),
                        detail: "\"\(trimmedSearchQuery)\""
                    )
                    .flex()
                } else {
                    Tree(hierarchyRoots,
                         children: \.children,
                         selectionKey: selectionKey,
                         multiSelectionKeys: multiSelectionKeys,
                         expandedKeys: expandedKeysBinding,
                         rowHeight: 26,
                         rowSpacing: 0,
                         indentation: 16,
                         disclosureWidth: 18,
                         showsIndentGuides: false,
                         disclosureContent: { isExpanded in
                             AnyView(HierarchyDisclosureIcon(isExpanded: isExpanded))
                         },
                         trailingSlotWidth: 58,
                         trailingContent: { entity, isSelected, _, _, _, _ in
                             AnyView(
                                HierarchyRowTrailingSlots(
                                    isVisible: scene.isHierarchyVisible(entity.id),
                                    isLocked: scene.isEntityLocked(entity.id),
                                    isEnabled: isAuthoringEnabled,
                                    isSelected: isSelected,
                                    onToggleVisibility: {
                                        toggleVisibility(entityID: entity.id,
                                                         selectedIDs: store.selectedEntityIDs)
                                    },
                                    onToggleLock: {
                                        toggleLock(entityID: entity.id,
                                                   selectedIDs: store.selectedEntityIDs)
                                    }
                                )
                             )
                         },
                         searchQuery: searchQuery,
                         searchText: { node in node.name },
                         searchFilterPolicy: .filterAndAutoExpand,
                         onKeyCommand: { event, selectedIDs in
                             handleBatchKey(event: event,
                                            selectedIDs: selectedIDs,
                                            matchingIDs: matchingEntityIDs,
                                            isAuthoringEnabled: isAuthoringEnabled)
                         },
                         canDrop: { source, target, position in
                             isAuthoringEnabled && canDrop(entityID: source.id,
                                     on: target.id,
                                     position: position,
                                     in: hierarchyRoots)
                         },
                         onDrop: { source, target, position in
                             guard isAuthoringEnabled else { return }
                             handleHierarchyDrop(entityID: source.id,
                                                 on: target.id,
                                                 position: position,
                                                 roots: hierarchyRoots)
                         }) { entity, isSelected, _, _ in
                        HierarchyEntityRow(entity: entity,
                                           isSelected: isSelected,
                                           searchQuery: searchQuery,
                                           isRenaming: renamingEntityID == entity.id,
                                           renameDraft: $renameDraft,
                                           focusRequestID: renamingEntityID == entity.id
                                            ? renameFocusRequestID
                                            : nil,
                                           onCommitRename: {
                                               commitRename(entityID: entity.id)
                                           },
                                           onCancelRename: cancelRename)
                    }
                    .padding(horizontal: 4, vertical: 4)
                    .flex()
                    .treeRowStyle(HierarchyTreeRowStyle())
                }
            }
            .frame(minWidth: 220)
        }
    }

    private func updateSearchQuery(_ value: String) {
        sessionState.searchQuery = value
        searchQuery = value
    }

    private func replaceExpandedKeys(_ value: Set<TreeNodeKey<UInt64>>) {
        sessionState.expandedEntityIDs = Set(value.map(\ .id))
        expandedKeys = value
    }

    private func insertExpandedKey(_ key: TreeNodeKey<UInt64>) {
        var next = expandedKeys
        next = Set(next.filter { $0.id != key.id })
        next.insert(key)
        replaceExpandedKeys(next)
    }

    private func hierarchyActionEntries(selectedIDs: Set<UInt64>,
                                        roots: [EditorSceneNode],
                                        isAuthoringEnabled: Bool,
                                        containsLockedSelection: Bool,
                                        containsRenderableSelection: Bool,
                                        allSelectionHidden: Bool,
                                        allSelectionLocked: Bool,
                                        canMoveSelectionToRoot: Bool) -> [MenuEntry] {
        guard !selectedIDs.isEmpty else { return [] }
        let canMutateSelection = isAuthoringEnabled && !containsLockedSelection
        return [
            .item(MenuItem(id: "hierarchy-rename",
                           title: L("Rename"),
                           shortcut: "F2",
                           isEnabled: canMutateSelection && selectedIDs.count == 1,
                           action: {
                               beginRename(entityID: selectedIDs.first,
                                           selectedIDs: selectedIDs,
                                           isAuthoringEnabled: isAuthoringEnabled)
                           })),
            .item(MenuItem(id: "hierarchy-duplicate",
                           title: L("Duplicate"),
                           shortcut: KeyboardShortcut.primary("D").displayString,
                           isEnabled: canMutateSelection,
                           action: { duplicateSelection(selectedIDs) })),
            .item(MenuItem(id: "hierarchy-frame",
                           title: L("Frame Selected"),
                           shortcut: "F",
                           action: framePrimarySelection)),
            .item(MenuItem(id: "hierarchy-select-descendants",
                           title: L("Select Descendants"),
                           isEnabled: !HierarchyPanelModel.descendantIDs(
                            of: selectedIDs,
                            in: roots
                           ).isEmpty,
                           action: {
                               selectDescendants(of: selectedIDs, roots: roots)
                           })),
            .separator("hierarchy-actions-edit"),
            .item(MenuItem(id: "hierarchy-visibility",
                           title: allSelectionHidden ? L("Show") : L("Hide"),
                           shortcut: "V",
                           isEnabled: isAuthoringEnabled && containsRenderableSelection,
                           action: {
                               setSelectionVisibility(allSelectionHidden,
                                                      selectedIDs: selectedIDs)
                           })),
            .item(MenuItem(id: "hierarchy-lock",
                           title: allSelectionLocked ? L("Unlock") : L("Lock"),
                           shortcut: "L",
                           isEnabled: isAuthoringEnabled,
                           action: {
                               scene.setEntityLocked(!allSelectionLocked,
                                                     entityIDs: selectedIDs)
                           })),
            .item(MenuItem(id: "hierarchy-move-root",
                           title: L("Move to Root"),
                           isEnabled: canMutateSelection && canMoveSelectionToRoot,
                           action: { moveSelectionToRoot(selectedIDs) })),
            .separator("hierarchy-actions-delete"),
            .item(MenuItem(id: "hierarchy-delete",
                           title: L("Delete"),
                           shortcut: "Delete",
                           isEnabled: canMutateSelection,
                           role: .destructive,
                           action: { deleteSelection(selectedIDs) })),
        ]
    }

    private func selectSearchMatch(_ direction: HierarchySearchDirection,
                                   matchingIDs: [UInt64],
                                   roots: [EditorSceneNode]) {
        guard let destination = HierarchyPanelModel.searchDestination(
            in: matchingIDs,
            currentID: store.state.selectedEntityID,
            direction: direction
        ) else { return }
        store.dispatch(.setSelectedEntity(destination))
        let keysByID = Self.keyIndex(in: roots)
        for ancestorID in HierarchyPanelModel.ancestorIDs(of: destination, in: roots) {
            if let key = keysByID[ancestorID]?.first {
                insertExpandedKey(key)
            }
        }
    }

    private func beginRename(entityID: UInt64?,
                             selectedIDs: Set<UInt64>,
                             isAuthoringEnabled: Bool) {
        guard isAuthoringEnabled,
              selectedIDs.count == 1,
              let entityID,
              selectedIDs.contains(entityID),
              !scene.isEntityLocked(entityID),
              let entity = scene.entitySummary(id: entityID) else { return }
        renameDraft = entity.name
        renamingEntityID = entityID
        renameFocusRequestID &+= 1
    }

    private func commitRename(entityID: UInt64) {
        guard renamingEntityID == entityID else { return }
        let proposedName = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposedName.isEmpty else {
            renameFocusRequestID &+= 1
            log(L("Entity name cannot be empty"), severity: .warning)
            return
        }
        guard scene.renameEntity(entityID, to: proposedName) else {
            log("Could not rename entity", severity: .error, detail: proposedName)
            return
        }
        renamingEntityID = nil
        renameDraft = ""
    }

    private func cancelRename() {
        renamingEntityID = nil
        renameDraft = ""
    }

    private func duplicateSelection(_ selectedIDs: Set<UInt64>) {
        guard !selectedIDs.isEmpty else { return }
        guard selectedIDs.allSatisfy({ !scene.isEntityLocked($0) }) else {
            log("Cannot duplicate locked entities", severity: .warning)
            return
        }
        let primarySource = store.state.selectedEntityID
        let orderedSources = selectedIDs.sorted()
        guard let duplicatedIDs = scene.duplicateEntities(selectedIDs),
              duplicatedIDs.count == orderedSources.count else {
            log("Could not duplicate selection", severity: .error)
            return
        }
        let duplicatedSelection = Set(duplicatedIDs)
        store.dispatch(.setSelectedEntities(duplicatedSelection))
        if let primarySource,
           let primaryIndex = orderedSources.firstIndex(of: primarySource) {
            store.dispatch(.setPrimarySelectedEntity(duplicatedIDs[primaryIndex]))
        }
    }

    private func deleteSelection(_ selectedIDs: Set<UInt64>) {
        guard !selectedIDs.isEmpty else { return }
        guard selectedIDs.allSatisfy({ !scene.isEntityLocked($0) }) else {
            log("Cannot delete locked entities", severity: .warning)
            return
        }
        guard scene.deleteEntities(selectedIDs) else {
            log("Could not delete selection", severity: .error)
            return
        }
        cancelRename()
        store.dispatch(.setSelectedEntity(nil))
    }

    private func moveSelectionToRoot(_ selectedIDs: Set<UInt64>) {
        guard selectedIDs.allSatisfy({ !scene.isEntityLocked($0) }),
              scene.moveEntitiesToRoot(selectedIDs) else {
            log("Could not move selection to root", severity: .warning)
            return
        }
    }

    private func framePrimarySelection() {
        guard let primaryID = store.state.selectedEntityID else { return }
        scene.frameEntity(primaryID)
    }

    private func selectDescendants(of selectedIDs: Set<UInt64>,
                                   roots: [EditorSceneNode]) {
        let descendants = HierarchyPanelModel.descendantIDs(of: selectedIDs,
                                                            in: roots,
                                                            includesSelection: true)
        guard !descendants.isEmpty else { return }
        store.dispatch(.setSelectedEntities(descendants))
    }

    private func setSelectionVisibility(_ visible: Bool,
                                        selectedIDs: Set<UInt64>) {
        guard scene.setHierarchyVisibility(visible, for: selectedIDs) else {
            log("Could not change hierarchy visibility", severity: .warning)
            return
        }
    }

    private func applyToSelectionOrEntity(_ id: UInt64,
                                          selectedIDs: Set<UInt64>,
                                          action: (Set<UInt64>) -> Void) {
        let targets = selectedIDs.contains(id) && !selectedIDs.isEmpty ? selectedIDs : [id]
        action(targets)
    }

    private func toggleVisibility(entityID: UInt64, selectedIDs: Set<UInt64>) {
        applyToSelectionOrEntity(entityID, selectedIDs: selectedIDs) { targets in
            let allHidden = targets.allSatisfy { !scene.isHierarchyVisible($0) }
            let changed = scene.setHierarchyVisibility(allHidden, for: targets)
            if !changed {
                log("Could not change hierarchy visibility", severity: .warning)
            }
        }
    }

    private func toggleLock(entityID: UInt64, selectedIDs: Set<UInt64>) {
        applyToSelectionOrEntity(entityID, selectedIDs: selectedIDs) { targets in
            let allLocked = targets.allSatisfy { scene.isEntityLocked($0) }
            scene.setEntityLocked(!allLocked, entityIDs: targets)
        }
    }

    private func handleBatchKey(event: KeyEvent,
                                selectedIDs: Set<UInt64>,
                                matchingIDs: [UInt64],
                                isAuthoringEnabled: Bool) -> Bool {
        guard !event.isRepeat else { return false }
        let commandLike = event.modifiers.hasGui || event.modifiers.hasCtrl

        if commandLike && event.scancode == Scancode.a {
            let selection = Set(matchingIDs)
            if !selection.isEmpty {
                store.dispatch(.setSelectedEntities(selection))
            }
            return true
        }

        guard !selectedIDs.isEmpty else { return false }

        if !isAuthoringEnabled {
            let requestsMutation = event.scancode == Scancode.backspace
                || event.scancode == Scancode.delete
                || event.scancode == Scancode.v
                || event.scancode == Scancode.l
                || event.scancode == Scancode.f2
                || (event.scancode == Scancode.d && commandLike)
            if requestsMutation {
                log("Stop simulation before editing the hierarchy", severity: .warning)
                return true
            }
            return false
        }

        switch event.scancode {
        case Scancode.backspace, Scancode.delete:
            guard event.modifiers.isEmpty else { return false }
            deleteSelection(selectedIDs)
            return true
        case Scancode.d:
            guard commandLike else { return false }
            duplicateSelection(selectedIDs)
            return true
        default:
            break
        }

        guard event.modifiers.isEmpty else { return false }
        switch event.scancode {
        case Scancode.f2:
            beginRename(entityID: store.state.selectedEntityID,
                        selectedIDs: selectedIDs,
                        isAuthoringEnabled: isAuthoringEnabled)
            return true
        case Scancode.f:
            framePrimarySelection()
            return true
        case Scancode.v:
            let allHidden = selectedIDs.allSatisfy { !scene.isHierarchyVisible($0) }
            setSelectionVisibility(allHidden, selectedIDs: selectedIDs)
            return true
        case Scancode.l:
            let allLocked = selectedIDs.allSatisfy { scene.isEntityLocked($0) }
            scene.setEntityLocked(!allLocked, entityIDs: selectedIDs)
            return true
        default:
            return false
        }
    }

    private func handleHierarchyDrop(entityID: UInt64,
                                     on targetID: UInt64,
                                     position: TreeDropPosition,
                                     roots: [EditorSceneNode]) {
        guard !scene.isEntityLocked(entityID),
              !scene.isEntityLocked(targetID) else { return }
        guard let destination = hierarchyDropDestination(for: targetID,
                                                         position: position,
                                                         roots: roots) else {
            return
        }
        guard scene.moveEntity(entityID, to: destination.parentID, at: destination.index) != nil else {
            log("Could not move hierarchy entity", severity: .error)
            return
        }
        if position == .inside {
            let keysByID = Self.keyIndex(in: roots)
            if let targetKey = keysByID[targetID]?.first {
                insertExpandedKey(targetKey)
            }
        }
    }

    private func canDrop(entityID sourceID: UInt64,
                         on targetID: UInt64,
                         position: TreeDropPosition,
                         in roots: [EditorSceneNode]) -> Bool {
        guard !scene.isEntityLocked(sourceID),
              !scene.isEntityLocked(targetID),
              sourceID != targetID,
              let destination = hierarchyDropDestination(for: targetID,
                                                         position: position,
                                                         roots: roots),
              let source = locateNode(sourceID, in: roots) else {
            return false
        }
        guard let parentID = destination.parentID else {
            return true
        }
        return !subtreeContains(parentID, in: source.node)
    }

    private func hierarchyDropDestination(for targetID: UInt64,
                                          position: TreeDropPosition,
                                          roots: [EditorSceneNode]) -> HierarchyDropDestination? {
        guard let target = locateNode(targetID, in: roots) else { return nil }
        switch position {
        case .before:
            return HierarchyDropDestination(parentID: target.parentID,
                                            index: target.index)
        case .inside:
            return HierarchyDropDestination(parentID: target.node.id,
                                            index: target.node.children.count)
        case .after:
            return HierarchyDropDestination(parentID: target.parentID,
                                            index: target.index + 1)
        }
    }

    private func locateNode(_ id: UInt64,
                            in nodes: [EditorSceneNode],
                            parentID: UInt64? = nil) -> HierarchyNodeLocation? {
        for (index, node) in nodes.enumerated() {
            if node.id == id {
                return HierarchyNodeLocation(node: node,
                                             parentID: parentID,
                                             index: index)
            }
            if let child = locateNode(id, in: node.children, parentID: node.id) {
                return child
            }
        }
        return nil
    }

    private func subtreeContains(_ id: UInt64,
                                 in node: EditorSceneNode) -> Bool {
        if node.id == id {
            return true
        }
        return node.children.contains { subtreeContains(id, in: $0) }
    }

    private static func keyIndex(in roots: [EditorSceneNode]) -> [UInt64: [TreeNodeKey<UInt64>]] {
        var result: [UInt64: [TreeNodeKey<UInt64>]] = [:]

        func walk(nodes: [EditorSceneNode], pathPrefix: [Int]) {
            for (index, node) in nodes.enumerated() {
                let path = pathPrefix + [index]
                result[node.id, default: []].append(TreeNodeKey(id: node.id, path: path))
                walk(nodes: node.children, pathPrefix: path)
            }
        }

        walk(nodes: roots, pathPrefix: [])
        return result
    }

    private static func expandedKeys(entityIDs: Set<UInt64>,
                                     roots: [EditorSceneNode]) -> Set<TreeNodeKey<UInt64>> {
        let keysByID = keyIndex(in: roots)
        return Set(entityIDs.compactMap { keysByID[$0]?.first })
    }

    private static func parentKeys(in roots: [EditorSceneNode]) -> Set<TreeNodeKey<UInt64>> {
        var result: Set<TreeNodeKey<UInt64>> = []

        func walk(_ nodes: [EditorSceneNode], pathPrefix: [Int]) {
            for (index, node) in nodes.enumerated() {
                let path = pathPrefix + [index]
                if !node.children.isEmpty {
                    result.insert(TreeNodeKey(id: node.id, path: path))
                    walk(node.children, pathPrefix: path)
                }
            }
        }

        walk(roots, pathPrefix: [])
        return result
    }

    private func log(_ message: String,
                     severity: EditorConsoleSeverity,
                     detail: String? = nil) {
        store.dispatch(.appendConsoleMessage(message, severity: severity, detail: detail))
    }
}

/// Dock layout and store notifications may reconstruct a panel's `AnyView`
/// host. Keep ephemeral hierarchy workflow state keyed to the editor store so
/// selection/revision updates do not erase an active search or the user's
/// expansion choices. This remains process-local and is never written to disk.
private final class HierarchyPanelSessionState {
    var expandedEntityIDs: Set<UInt64>
    var searchQuery: String

    init(expandedEntityIDs: Set<UInt64>, searchQuery: String = "") {
        self.expandedEntityIDs = expandedEntityIDs
        self.searchQuery = searchQuery
    }
}

private enum HierarchyPanelSessionRegistry {
    nonisolated(unsafe) private static var states: [
        ObjectIdentifier: HierarchyPanelSessionState
    ] = [:]

    static func state(for store: EditorStore,
                      defaultExpandedEntityIDs: Set<UInt64>)
        -> HierarchyPanelSessionState
    {
        let key = ObjectIdentifier(store)
        if let existing = states[key] {
            return existing
        }
        let created = HierarchyPanelSessionState(
            expandedEntityIDs: defaultExpandedEntityIDs
        )
        states[key] = created
        return created
    }
}

private struct HierarchyNodeLocation {
    let node: EditorSceneNode
    let parentID: UInt64?
    let index: Int
}

private struct HierarchyDropDestination {
    let parentID: UInt64?
    let index: Int
}

private struct HierarchyTreeRowStyle: TreeRowStyle {
    func makeBody(configuration: TreeRowStyleConfiguration) -> some View {
        let t = configuration.theme
        let bg: Color = {
            if configuration.isSelected { return t.colors.selection }
            if configuration.isSearchHit { return t.colors.stateLayerSelected }
            if configuration.isHovered { return t.colors.stateLayerHover }
            return Color(r: 0, g: 0, b: 0, a: 0)
        }()

        return Row(alignment: .center, spacing: 0) {
            configuration.content
                .flex(1, shrink: 1, basis: 0)
        }
        .padding(horizontal: 6, vertical: 0)
        .frame(height: 26)
        .clipped()
        .background(bg)
        .cornerRadius(t.radius.sm)
        .opacity(configuration.isEnabled ? 1 : 0.55)
    }
}

private struct HierarchyPanelHeader: View {
    let entityCount: Int
    let selectionCount: Int
    let isAuthoringEnabled: Bool
    let selectedParent: EditorSceneEntitySummary?
    let selectionActions: [MenuEntry]
    let onCreateEntity: (EditorEntityTemplate, UInt64?) -> Void
    @State private var isCreatePresented: Bool = false
    @State private var isActionsPresented: Bool = false

    var body: some View {
        EditorPanelToolbar {
            if selectionCount > 0 {
                EditorPanelBadge("\(selectionCount) \(L("selected"))", foreground: .accent)
            } else {
                EditorPanelBadge("\(entityCount) \(L(entityCount == 1 ? "entity" : "entities"))")
            }

            Spacer(minLength: 0)

            if selectionCount > 0 {
                Popover(isPresented: $isActionsPresented, width: 220) {
                    actionLabel()
                } content: {
                    Menu(selectionActions,
                         width: 220,
                         maxVisibleRows: 11,
                         onItemActivated: {
                             isActionsPresented = false
                         })
                }
            }

            if isAuthoringEnabled {
                Popover(isPresented: $isCreatePresented,
                        width: 240,
                        placement: .end) {
                    createLabel()
                } content: {
                    Menu(createEntries(),
                         width: 240,
                         maxVisibleRows: 14,
                         onItemActivated: {
                        isCreatePresented = false
                    })
                }
            } else {
                Button(isEnabled: false,
                       tooltip: L("Stop simulation to edit the scene"),
                       action: {}) {
                    createLabel()
                }
                .buttonStyle(.plain)
            }

        }
    }

    private func createEntries() -> [MenuEntry] {
        var entries = EditorEntityTemplate.allCases.map { template in
            MenuEntry.item(MenuItem(id: "create-root-entity-\(template.rawValue)",
                                    title: L(template.displayName),
                                    action: { onCreateEntity(template, nil) }))
        }
        if let selectedParent {
            entries.append(.separator("create-child-separator"))
            entries.append(contentsOf: EditorEntityTemplate.allCases.map { template in
                MenuEntry.item(MenuItem(
                    id: "create-child-entity-\(template.rawValue)",
                    title: String(format: L("%@ as Child"), L(template.displayName)),
                    action: { onCreateEntity(template, selectedParent.id) }
                ))
            })
        }
        return entries
    }

    private func actionLabel() -> some View {
        Row(alignment: .center, spacing: 4) {
            Text(L("Actions"))
                .font(.caption)
                .foregroundColor(.onSurface)
            Icon(isActionsPresented ? UICommonIcons.chevronUp : UICommonIcons.chevronDown,
                 size: 8,
                 color: .onSurfaceMuted)
        }
        .padding(horizontal: 7, vertical: 4)
        .background(.surfaceSunken)
        .cornerRadius(4)
    }

    private func createLabel() -> some View {
        Row(alignment: .center, spacing: 5) {
            Text("+")
                .font(.bodyStrong)
                .foregroundColor(isAuthoringEnabled ? .accent : .onSurfaceMuted)
            Text(L("Create"))
                .font(.caption)
                .foregroundColor(isAuthoringEnabled ? .onSurface : .onSurfaceMuted)
        }
        .padding(horizontal: 8, vertical: 4)
        .background(.surfaceSunken)
        .cornerRadius(4)
    }
}

private struct HierarchyEntityRow: View {
    let entity: EditorSceneNode
    let isSelected: Bool
    let searchQuery: String
    let isRenaming: Bool
    let renameDraft: Binding<String>
    let focusRequestID: UInt64?
    let onCommitRename: () -> Void
    let onCancelRename: () -> Void

    var body: some View {
        Row(alignment: .center, spacing: 7) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                HierarchyEntityIcon(kind: entity.kind)
                    .foregroundColor(isSelected ? .onSurface : .onSurfaceVariant)
                    .frame(width: 18, height: 18)
            }
            .frame(width: 18, height: 26)

            if isRenaming {
                TextField(text: renameDraft,
                          size: .small,
                          maxLength: 128,
                          focusRequestID: focusRequestID,
                          onSubmit: onCommitRename,
                          onCancel: onCancelRename,
                          onBlur: onCommitRename)
                    .font(.body)
                    .flex(1, shrink: 1, basis: 0)
            } else {
                highlightedName()
                    .padding(horizontal: 2, vertical: 0)
                    .flex(1, shrink: 1, basis: 0)
                    .clipped()
            }
        }
        .frame(height: 26)
        .clipped()
    }

    private func highlightedName() -> AnyView {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty || query.count < 2 {
            return AnyView(
                Text(entity.name, lineLimit: 1)
                    .font(entity.children.isEmpty ? .body : .bodyStrong)
                    .foregroundColor(.onSurface)
            )
        }
        guard let range = entity.name.range(of: query, options: .caseInsensitive), !range.isEmpty else {
            return AnyView(
                Text(entity.name, lineLimit: 1)
                    .font(entity.children.isEmpty ? .body : .bodyStrong)
                    .foregroundColor(.onSurface)
            )
        }

        let prefix = String(entity.name[..<range.lowerBound])
        let match = String(entity.name[range])
        let suffix = String(entity.name[range.upperBound...])

        return AnyView(
            Row(alignment: .center, spacing: 0) {
                if !prefix.isEmpty {
                    Text(prefix, lineLimit: 1)
                        .font(entity.children.isEmpty ? .body : .bodyStrong)
                        .foregroundColor(.onSurface)
                }
                Text(match, lineLimit: 1)
                    .font(.bodyStrong)
                    .foregroundColor(.accent)
                if !suffix.isEmpty {
                    Text(suffix, lineLimit: 1)
                        .font(entity.children.isEmpty ? .body : .bodyStrong)
                        .foregroundColor(.onSurface)
                }
            }
            .clipped()
        )
    }
}

private struct HierarchyRowTrailingSlots: View {
    let isVisible: Bool
    let isLocked: Bool
    let isEnabled: Bool
    let isSelected: Bool
    let onToggleVisibility: () -> Void
    let onToggleLock: () -> Void

    var body: some View {
        Row(alignment: .center, spacing: 0) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Button(isEnabled: isEnabled,
                       tooltip: isVisible ? L("Hide") : L("Show"),
                       action: onToggleVisibility) {
                    Icon(HierarchyIconCatalog.visibilityResource(isVisible: isVisible), size: 13, color: isSelected ? .onSurface : .onSurfaceVariant)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 20, height: 26)

            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Button(isEnabled: isEnabled,
                       tooltip: isLocked ? L("Unlock") : L("Lock"),
                       action: onToggleLock) {
                    Icon(HierarchyIconCatalog.lockResource(isLocked: isLocked), size: 13, color: isSelected ? .onSurface : .onSurfaceVariant)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 20, height: 26)

            // Reserve a narrow terminal gutter so disclosure chevrons from
            // neighboring content never visually collide with icon columns.
            Box { EmptyView() }
                .frame(width: 8, height: 26)
        }
        .frame(width: 48, height: 26)
    }
}

private struct HierarchyDisclosureIcon: View {
    let isExpanded: Bool

    var body: some View {
        Icon(HierarchyIconCatalog.disclosureResource(expanded: isExpanded), size: 12, color: .onSurfaceVariant)
    }
}

private struct HierarchyEntityIcon: View {
    let kind: String

    var body: some View {
        Icon(HierarchyIconCatalog.entityResource(for: kind), size: 18, color: .white)
    }
}

private enum HierarchyIconCatalog {
    static func visibilityResource(isVisible: Bool) -> BundleImageResource {
        resource(named: isVisible ? "eye" : "eye-slash")
    }

    static func lockResource(isLocked: Bool) -> BundleImageResource {
        resource(named: isLocked ? "lock-closed" : "lock-open")
    }

    static func disclosureResource(expanded: Bool) -> BundleImageResource {
        resource(named: expanded ? "triangle-down" : "triangle-right")
    }

    static func entityResource(for kind: String) -> BundleImageResource {
        let normalized = kind.lowercased()
        if normalized.contains("camera") {
            return resource(named: "camera")
        }
        if normalized.contains("light") {
            return resource(named: "light-bulb")
        }
        if normalized.contains("mesh") {
            return resource(named: "cube")
        }
        if normalized.contains("group") {
            return resource(named: "squares-2x2")
        }
        if normalized.contains("socket") || normalized.contains("locator") {
            return resource(named: "crosshair")
        }
        if normalized.contains("constraint") {
            return resource(named: "arrow-path")
        }
        return resource(named: "cube")
    }

    private static func resource(named name: String) -> BundleImageResource {
        .svg(named: name,
             in: EditorAppResourceBundle.bundle,
             subdirectory: "HierarchyIcons")
    }
}
