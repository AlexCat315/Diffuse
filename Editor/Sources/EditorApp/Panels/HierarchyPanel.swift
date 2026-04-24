import EditorCore
import EngineKernel
import Foundation
import GuavaUICompose
import GuavaUIRuntime

struct HierarchyPanel: View {
    let store: EditorStore
    let scene: EditorSceneAdapter

    @State private var expanded: Set<UInt64>
    @State private var searchQuery: String
    @State private var hiddenEntityIDs: Set<UInt64>
    @State private var lockedEntityIDs: Set<UInt64>

    init(store: EditorStore, scene: EditorSceneAdapter) {
        self.store = store
        self.scene = scene
        _expanded = State(wrappedValue: scene.defaultExpandedEntityIDs)
        _searchQuery = State(wrappedValue: "")
        _hiddenEntityIDs = State(wrappedValue: [])
        _lockedEntityIDs = State(wrappedValue: [])
    }

    var body: some View {
        StoreScope(store) { store in
            let selection = Binding<UInt64?>(
                get: { store.state.selectedEntityID },
                set: { next in
                    if store.state.selectedEntityID != next {
                        store.dispatch(.setSelectedEntity(next))
                    }
                }
            )
            let multiSelection = Binding<Set<UInt64>>(
                get: { store.state.selectedEntityIDs },
                set: { next in
                    if store.state.selectedEntityIDs != next {
                        store.dispatch(.setSelectedEntities(next))
                    }
                }
            )

            Box(direction: .column, alignItems: .stretch) {
                HierarchyPanelHeader(entityCount: scene.entityCount,
                                     isConnected: store.state.connected)
                    .padding(horizontal: 10, vertical: 7)

                Box(direction: .row, alignItems: .center, spacing: 6) {
                    Text("Search")
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)

                    TextField(text: $searchQuery)
                        .font(.caption)
                        .flex()
                }
                .padding(horizontal: 10, vertical: 6)

                Divider()

                Tree(scene.roots,
                     children: \.children,
                     selection: selection,
                     multiSelection: multiSelection,
                     expanded: $expanded,
                     rowHeight: 28,
                     rowSpacing: 0,
                     indentation: 16,
                     disclosureWidth: 18,
                     showsIndentGuides: true,
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
}

private struct HierarchyTreeRowStyle: TreeRowStyle {
    func makeBody(configuration: TreeRowStyleConfiguration) -> some View {
        let bg: Color = {
            if configuration.isSelected {
                return Color(red: 47, green: 68, blue: 112)
            }
            if configuration.isSearchHit {
                return Color(r: 73.0 / 255.0, g: 89.0 / 255.0, b: 42.0 / 255.0, a: 0.72)
            }
            if configuration.isHovered {
                return Color(r: 42.0 / 255.0, g: 47.0 / 255.0, b: 56.0 / 255.0, a: 0.82)
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
        .cornerRadius(configuration.isSelected || configuration.isHovered || configuration.isSearchHit ? 4 : 0)
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
            HierarchyEntityIcon(kind: entity.kind)
                .foregroundColor(isSelected ? .onSurface : .onSurfaceVariant)
                .frame(width: 18, height: 18)

            highlightedName()
                .padding(horizontal: 2, vertical: 1)
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
        Row(alignment: .center, spacing: 10) {
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
