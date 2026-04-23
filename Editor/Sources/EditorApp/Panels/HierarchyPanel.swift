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
        Image(resource: HierarchyIconCatalog.disclosureResource(expanded: isExpanded),
              width: 20,
              height: 20,
              tint: .white)
        .foregroundColor(.onSurfaceMuted)
    }
}

private struct HierarchyEntityIcon: View {
    let kind: String

    var body: some View {
        Image(resource: HierarchyIconCatalog.entityResource(for: kind),
              width: 40,
              height: 40,
              tint: .white)
    }
}

private enum HierarchyIconCatalog {
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
