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
    @State private var hiddenEntityIDs: Set<UInt64>
    @State private var lockedEntityIDs: Set<UInt64>

    init(store: EditorStore, scene: EditorSceneAdapter) {
        self.store = store
        self.scene = scene
        _expandedKeys = State(
            wrappedValue: Self.defaultExpandedKeys(defaultIDs: scene.defaultExpandedEntityIDs,
                                                   roots: scene.roots)
        )
        _searchQuery = State(wrappedValue: "")
        _hiddenEntityIDs = State(wrappedValue: [])
        _lockedEntityIDs = State(wrappedValue: [])
    }

    var body: some View {
        StoreScope(store) { store in
            let hierarchyRoots = scene.roots
            let keysByID = Self.keyIndex(in: hierarchyRoots)
            let selectionKey = Binding<TreeNodeKey<UInt64>?>(
                get: {
                    guard let selected = store.state.selectedEntityID else { return nil }
                    return keysByID[selected]?.first
                },
                set: { next in
                    let nextID = next?.id
                    if store.state.selectedEntityID != nextID {
                        store.dispatch(.setPrimarySelectedEntity(nextID))
                    }
                }
            )
            let multiSelectionKeys = Binding<Set<TreeNodeKey<UInt64>>>(
                get: {
                    Set(store.state.selectedEntityIDs.compactMap { keysByID[$0]?.first })
                },
                set: { next in
                    let nextIDs = Set(next.map(\ .id))
                    if store.state.selectedEntityIDs != nextIDs {
                        store.dispatch(.setSelectedEntities(nextIDs))
                    }
                }
            )

            Box(direction: .column, alignItems: .stretch) {
                HierarchyPanelHeader(entityCount: scene.entityCount,
                                     isConnected: store.state.connected)
                    .padding(horizontal: 10, vertical: 7)

                Box(direction: .row, alignItems: .center, spacing: 6) {
                    Text(L("Search"))
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)

                    TextField(text: $searchQuery)
                        .font(.caption)
                        .flex()
                }
                .padding(horizontal: 10, vertical: 6)

                Divider()

             Tree(hierarchyRoots,
                     children: \.children,
                     selectionKey: selectionKey,
                     multiSelectionKeys: multiSelectionKeys,
                     expandedKeys: $expandedKeys,
                     rowHeight: 28,
                     rowSpacing: 0,
                     indentation: 16,
                     disclosureWidth: 18,
                     showsIndentGuides: false,
                     disclosureContent: { isExpanded in
                         AnyView(HierarchyDisclosureIcon(isExpanded: isExpanded))
                     },
                     trailingSlotWidth: 72,
                     trailingContent: { entity, isSelected, _, _, isHovered, _ in
                         AnyView(
                            HierarchyRowTrailingSlots(
                                isVisible: !hiddenEntityIDs.contains(entity.id),
                                isLocked: lockedEntityIDs.contains(entity.id),
                                showsControls: isHovered || isSelected,
                                isSelected: isSelected,
                                onToggleVisibility: {
                                    toggleVisibility(entityID: entity.id,
                                                     selectedIDs: store.state.selectedEntityIDs)
                                },
                                onToggleLock: {
                                    toggleLock(entityID: entity.id,
                                               selectedIDs: store.state.selectedEntityIDs)
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
                .padding(horizontal: 5, vertical: 4)
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
            let allHidden = targets.allSatisfy { hiddenEntityIDs.contains($0) }
            if allHidden {
                hiddenEntityIDs.subtract(targets)
            } else {
                hiddenEntityIDs.formUnion(targets)
            }
        }
    }

    private func toggleLock(entityID: UInt64, selectedIDs: Set<UInt64>) {
        applyToSelectionOrEntity(entityID, selectedIDs: selectedIDs) { targets in
            let allLocked = targets.allSatisfy { lockedEntityIDs.contains($0) }
            if allLocked {
                lockedEntityIDs.subtract(targets)
            } else {
                lockedEntityIDs.formUnion(targets)
            }
        }
    }

    private func handleBatchKey(event: KeyEvent, selectedIDs: Set<UInt64>) -> Bool {
        guard !selectedIDs.isEmpty else { return false }
        switch event.scancode {
        case 25: // SDL_SCANCODE_V
            let allHidden = selectedIDs.allSatisfy { hiddenEntityIDs.contains($0) }
            if allHidden {
                hiddenEntityIDs.subtract(selectedIDs)
            } else {
                hiddenEntityIDs.formUnion(selectedIDs)
            }
            return true
        case 15: // SDL_SCANCODE_L
            let allLocked = selectedIDs.allSatisfy { lockedEntityIDs.contains($0) }
            if allLocked {
                lockedEntityIDs.subtract(selectedIDs)
            } else {
                lockedEntityIDs.formUnion(selectedIDs)
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
        guard sourceID != targetID,
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
        let bg: Color = {
            if configuration.isSelected {
                return Color(red: 56, green: 82, blue: 136)
            }
            if configuration.isSearchHit {
                return Color(r: 73.0 / 255.0, g: 89.0 / 255.0, b: 42.0 / 255.0, a: 0.72)
            }
            if configuration.isHovered {
                return Color(r: 52.0 / 255.0, g: 59.0 / 255.0, b: 71.0 / 255.0, a: 0.96)
            }
            return Color(r: 0, g: 0, b: 0, a: 0)
        }()

        return Row(alignment: .center, spacing: 0) {
            configuration.content
                .flex(1, shrink: 1, basis: 0)
        }
        .padding(horizontal: 7, vertical: 0)
        .frame(height: 28)
        .clipped()
        .background(bg)
        .cornerRadius(configuration.isSelected ? 4 : 0)
        .opacity(configuration.isEnabled ? 1 : 0.55)
    }
}

private struct HierarchyPanelHeader: View {
    let entityCount: Int
    let isConnected: Bool

    var body: some View {
        Row(alignment: .center, spacing: 8) {
            Text("\(entityCount) entities")
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            Spacer(minLength: 0)

            Row(alignment: .center, spacing: 5) {
                Box { EmptyView() }
                    .frame(width: 6, height: 6)
                    .background(isConnected ? .success : .warning)
                    .cornerRadius(3)

                Text(isConnected ? "Live" : "Offline")
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
            .frame(width: 18, height: 28)

            highlightedName()
                .padding(horizontal: 2, vertical: 0)
                .flex(1, shrink: 1, basis: 0)
                .clipped()
        }
        .frame(height: 28)
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
                    Image(resource: HierarchyIconCatalog.visibilityResource(isVisible: isVisible),
                          width: 13,
                          height: 13,
                          tint: .white,
                          contentMode: .fit)
                        .foregroundColor(isSelected ? .onSurface : .onSurfaceVariant)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 22, height: 28)

            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Button(action: onToggleLock) {
                    Image(resource: HierarchyIconCatalog.lockResource(isLocked: isLocked),
                          width: 13,
                          height: 13,
                          tint: .white,
                          contentMode: .fit)
                        .foregroundColor(isSelected ? .onSurface : .onSurfaceVariant)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 22, height: 28)

            // Reserve a narrow terminal gutter so disclosure chevrons from
            // neighboring content never visually collide with icon columns.
            Box { EmptyView() }
                .frame(width: 10, height: 28)
        }
        .frame(width: 54, height: 28)
        .opacity(showsControls ? 1 : 0)
    }
}

private struct HierarchyDisclosureIcon: View {
    let isExpanded: Bool

    var body: some View {
        Image(resource: HierarchyIconCatalog.disclosureResource(expanded: isExpanded),
              width: 12,
              height: 12,
                            tint: .white,
                            contentMode: .fit)
            .foregroundColor(.onSurfaceVariant)
    }
}

private struct HierarchyEntityIcon: View {
    let kind: String

    var body: some View {
        Image(resource: HierarchyIconCatalog.entityResource(for: kind),
              width: 18,
              height: 18,
              tint: .white,
              contentMode: .fit)
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
             in: .module,
             subdirectory: "HierarchyIcons")
    }
}
