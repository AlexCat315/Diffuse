import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime

struct HierarchyPanel: View {
    let store: EditorStore
    let scene: EditorSceneAdapter
    @State private var expanded: Set<UInt64>

    init(store: EditorStore, scene: EditorSceneAdapter) {
        self.store = store
        self.scene = scene
        _expanded = State(wrappedValue: scene.defaultExpandedEntityIDs)
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

            Box(direction: .column, alignItems: .stretch) {
                HierarchyPanelHeader(entityCount: scene.entityCount,
                                     isConnected: store.state.connected)
                    .padding(horizontal: 10, vertical: 7)

                Divider()

                Tree(scene.roots,
                     children: \.children,
                     selection: selection,
                     expanded: $expanded,
                     rowHeight: 28,
                     rowSpacing: 0,
                     indentation: 16,
                     disclosureWidth: 20,
                     showsIndentGuides: false,
                     disclosureContent: { isExpanded in
                         AnyView(HierarchyDisclosureIcon(isExpanded: isExpanded))
                     }) { entity, isSelected, _, _ in
                    HierarchyEntityRow(entity: entity, isSelected: isSelected)
                }
                .padding(horizontal: 5, vertical: 4)
                .flex()
            }
            .frame(minWidth: 220)
        }
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
                    .foregroundColor(.onSurfaceMuted)
            }
        }
    }
}

private struct HierarchyEntityRow: View {
    let entity: EditorSceneNode
    let isSelected: Bool

    var body: some View {
        Row(alignment: .center, spacing: 7) {
            HierarchyEntityIcon(kind: entity.kind)
                .foregroundColor(isSelected ? .onSurface : .onSurfaceVariant)

            Text(entity.name)
                .font(entity.children.isEmpty
                      ? .body
                      : .bodyStrong)
                .foregroundColor(.onSurface)
        }
        .padding(horizontal: 2, vertical: 1)
    }
}

private struct HierarchyDisclosureIcon: View {
    let isExpanded: Bool

    var body: some View {
        if let path = HierarchyIconCatalog.disclosurePath(expanded: isExpanded) {
            Image(file: path,
                  width: 20,
                  height: 20,
                  tint: .white)
            .foregroundColor(.onSurfaceMuted)
        } else {
            Text(isExpanded ? "▾" : "▸")
                .font(.bodyStrong)
                .foregroundColor(.onSurfaceMuted)
        }
    }
}

private struct HierarchyEntityIcon: View {
    let kind: String

    var body: some View {
        if let path = HierarchyIconCatalog.entityPath(for: kind) {
            Image(file: path,
                  width: 12,
                  height: 12,
                  tint: .white)
        } else {
            EmptyView()
        }
    }
}

private enum HierarchyIconCatalog {
    static func disclosurePath(expanded: Bool) -> String? {
        resourcePath(named: expanded ? "triangle-down" : "triangle-right")
    }

    static func entityPath(for kind: String) -> String? {
        let normalized = kind.lowercased()
        if normalized.contains("camera") {
            return resourcePath(named: "camera")
        }
        if normalized.contains("light") {
            return resourcePath(named: "light-bulb")
        }
        if normalized.contains("mesh") {
            return resourcePath(named: "cube")
        }
        if normalized.contains("group") {
            return resourcePath(named: "squares-2x2")
        }
        if normalized.contains("socket") || normalized.contains("locator") {
            return resourcePath(named: "crosshair")
        }
        if normalized.contains("constraint") {
            return resourcePath(named: "arrow-path")
        }
        return resourcePath(named: "cube")
    }

    private static func resourcePath(named name: String) -> String? {
        Bundle.module.path(forResource: name,
                           ofType: "svg",
                           inDirectory: "HierarchyIcons")
    }
}
