import EditorCore
import EngineKernel
import Foundation
import GuavaUICompose
import GuavaUIRuntime

struct HierarchyPanel: View {
    let store: EditorStore
    let scene: EditorSceneAdapter

    @State private var expandedKeys: Set<TreeNodeKey<UInt64>>
    @State private var searchQuery: String
    @State private var lockedEntityIDs: Set<UInt64>

    init(store: EditorStore, scene: EditorSceneAdapter) {
        self.store = store
        self.scene = scene
        _expandedKeys = State(
            wrappedValue: Self.defaultExpandedKeys(defaultIDs: scene.defaultExpandedEntityIDs,
                                                   roots: scene.roots)
        )
        _searchQuery = State(wrappedValue: "")
        _lockedEntityIDs = State(wrappedValue: [])
    }

    var body: some View {
        StoreScope(store) { store in
            let _ = store.sceneRevision
            let hierarchyRoots = scene.roots
            let keysByID = Self.keyIndex(in: hierarchyRoots)
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
                                     isConnected: store.connected,
                                     onCreateEntity: { template in
                        guard let newID = scene.spawnEntity(template: template) else { return }
                        store.dispatch(.setSelectedEntity(newID))
                    })
                    .padding(horizontal: 10, vertical: 7)

                Box(direction: .row, alignItems: .center, spacing: 6) {
                    TextField(L("Search"), text: $searchQuery, size: .small)
                        .font(.caption)
                        .flex()
                }
                .padding(horizontal: 8, vertical: 4)

                Divider()

                Tree(hierarchyRoots,
                     children: \.children,
                     selectionKey: selectionKey,
                     multiSelectionKeys: multiSelectionKeys,
                     expandedKeys: $expandedKeys,
                     rowHeight: 26,
                     rowSpacing: 0,
                     indentation: 16,
                     disclosureWidth: 18,
                     showsIndentGuides: false,
                     disclosureContent: { isExpanded in
                         AnyView(HierarchyDisclosureIcon(isExpanded: isExpanded))
                     },
                     trailingSlotWidth: 58,
                     trailingContent: { entity, isSelected, _, _, isHovered, _ in
                         AnyView(
                            HierarchyRowTrailingSlots(
                                isVisible: scene.isHierarchyVisible(entity.id),
                                isLocked: scene.isEntityLocked(entity.id),
                                showsControls: isHovered || isSelected,
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
                         handleBatchKey(event: event, selectedIDs: selectedIDs)
                     },
                     canDrop: { source, target, position in
                         canDrop(entityID: source.id,
                                 on: target.id,
                                 position: position,
                                 in: hierarchyRoots)
                     },
                     onDrop: { source, target, position in
                         handleHierarchyDrop(entityID: source.id,
                                             on: target.id,
                                             position: position,
                                             roots: hierarchyRoots)
                     }) { entity, isSelected, _, _ in
                    HierarchyEntityRow(entity: entity,
                                       isSelected: isSelected,
                                       searchQuery: searchQuery)
                }
                .padding(horizontal: 4, vertical: 4)
                .flex()
                .treeRowStyle(HierarchyTreeRowStyle())
            }
            .frame(minWidth: 220)
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
            if allHidden {
                _ = scene.setHierarchyVisibility(true, for: targets)
            } else {
                _ = scene.setHierarchyVisibility(false, for: targets)
            }
        }
    }

    private func toggleLock(entityID: UInt64, selectedIDs: Set<UInt64>) {
        applyToSelectionOrEntity(entityID, selectedIDs: selectedIDs) { targets in
            let allLocked = targets.allSatisfy { scene.isEntityLocked($0) }
            if allLocked {
                lockedEntityIDs.subtract(targets)
                scene.setEntityLocked(false, entityIDs: targets)
            } else {
                lockedEntityIDs.formUnion(targets)
                scene.setEntityLocked(true, entityIDs: targets)
            }
        }
    }

    private func handleBatchKey(event: KeyEvent, selectedIDs: Set<UInt64>) -> Bool {
        guard !selectedIDs.isEmpty else { return false }

        switch event.keycode {
        case 0x08, 0x7F: // Backspace / Delete
            guard event.modifiers.isEmpty,
                  selectedIDs.allSatisfy({ !scene.isEntityLocked($0) }) else { return false }
            if scene.deleteEntities(selectedIDs) {
                store.dispatch(.setSelectedEntity(nil))
            }
            return true
        case 0x64: // D
            guard event.modifiers.hasGui || event.modifiers.hasCtrl,
                  let sourceID = store.state.selectedEntityID,
                  !scene.isEntityLocked(sourceID) else { return false }
            if let newID = scene.duplicateEntity(sourceID) {
                store.dispatch(.setSelectedEntity(newID))
            }
            return true
        default:
            break
        }

        guard event.modifiers.isEmpty else { return false }
        switch event.scancode {
        case 25: // SDL_SCANCODE_V
            let allHidden = selectedIDs.allSatisfy { !scene.isHierarchyVisible($0) }
            if allHidden {
                _ = scene.setHierarchyVisibility(true, for: selectedIDs)
            } else {
                _ = scene.setHierarchyVisibility(false, for: selectedIDs)
            }
            return true
        case 15: // SDL_SCANCODE_L
            let allLocked = selectedIDs.allSatisfy { scene.isEntityLocked($0) }
            if allLocked {
                lockedEntityIDs.subtract(selectedIDs)
                scene.setEntityLocked(false, entityIDs: selectedIDs)
            } else {
                lockedEntityIDs.formUnion(selectedIDs)
                scene.setEntityLocked(true, entityIDs: selectedIDs)
            }
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
            return
        }
        if position == .inside {
            let keysByID = Self.keyIndex(in: roots)
            if let targetKey = keysByID[targetID]?.first {
                expandedKeys.insert(targetKey)
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

    private static func defaultExpandedKeys(defaultIDs: Set<UInt64>,
                                            roots: [EditorSceneNode]) -> Set<TreeNodeKey<UInt64>> {
        let keysByID = keyIndex(in: roots)
        return Set(defaultIDs.compactMap { keysByID[$0]?.first })
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
    let isConnected: Bool
    let onCreateEntity: (EditorEntityTemplate) -> Void
    @State private var isCreatePresented: Bool = false

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Text("\(entityCount) \(L(entityCount == 1 ? "entity" : "entities"))")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            Spacer(minLength: 0)

            Popover(isPresented: $isCreatePresented, width: 210) {
                Row(alignment: .center, spacing: 5) {
                    Text("+")
                        .font(.bodyStrong)
                        .foregroundColor(.accent)
                    Text(L("Create"))
                        .font(.caption)
                        .foregroundColor(.onSurface)
                }
                .padding(horizontal: 8, vertical: 4)
                .background(.surfaceSunken)
                .cornerRadius(4)
            } content: {
                Menu(EditorEntityTemplate.allCases.map { template in
                    .item(MenuItem(id: "create-entity-\(template.rawValue)",
                                   title: L(template.displayName),
                                   action: { onCreateEntity(template) }))
                }, width: 210, maxVisibleRows: 8, onItemActivated: {
                    isCreatePresented = false
                })
            }

            Row(alignment: .center, spacing: 5) {
                Box { EmptyView() }
                    .frame(width: 6, height: 6)
                    .background(isConnected ? .success : .warning)
                    .cornerRadius(3)

                Text(isConnected ? L("Live") : L("Offline"))
                    .font(.caption)
                    .foregroundColor(isConnected ? .success : .warning)
            }
        }
    }
}

private struct HierarchyEntityRow: View {
    let entity: EditorSceneNode
    let isSelected: Bool
    let searchQuery: String

    var body: some View {
        Row(alignment: .center, spacing: 7) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                HierarchyEntityIcon(kind: entity.kind)
                    .foregroundColor(isSelected ? .onSurface : .onSurfaceVariant)
                    .frame(width: 18, height: 18)
            }
            .frame(width: 18, height: 26)

            highlightedName()
                .padding(horizontal: 2, vertical: 0)
                .flex(1, shrink: 1, basis: 0)
                .clipped()
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
    let showsControls: Bool
    let isSelected: Bool
    let onToggleVisibility: () -> Void
    let onToggleLock: () -> Void

    var body: some View {
        Row(alignment: .center, spacing: 0) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Button(action: onToggleVisibility) {
                    Icon(HierarchyIconCatalog.visibilityResource(isVisible: isVisible), size: 13, color: isSelected ? .onSurface : .onSurfaceVariant)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 20, height: 26)

            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Button(action: onToggleLock) {
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
        .opacity(showsControls ? 1 : 0)
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
