import EditorCore
import GuavaUICompose
import GuavaUIRuntime

struct InspectorPanel: View {
    let store: EditorStore
    let scene: EditorSceneAdapter

    var body: some View {
        StoreScope(store) { store in
            let entity = scene.entitySummary(id: store.state.selectedEntityID)
            let sections = scene.inspectorSections(for: store.state.selectedEntityID)
            let collapsedIDs = store.state.inspectorCollapsedSectionIDs

            Box(direction: .column, alignItems: .stretch) {
                if let entity {
                    InspectorSelectionSummary(entity: entity)

                    Divider()

                    PropertyGrid(propertySections(sections, collapsedIDs: collapsedIDs),
                                 labelWidth: 100,
                                 rowHeight: 26,
                                 onSectionCollapseChanged: { id, isCollapsed in
                        store.dispatch(.setInspectorSectionCollapsed(id: id, isCollapsed: isCollapsed))
                    })
                        .flex()
                } else {
                    Box(direction: .column, alignItems: .stretch, spacing: 4) {
                        Text("No selection")
                            .font(.bodyStrong)
                        Text("Select an entity in Hierarchy to inspect SceneRuntime components.")
                            .font(.caption)
                            .foregroundColor(.onSurfaceMuted)
                    }
                    .padding(10)
                }
            }
            .frame(minWidth: 340)
        }
    }

    private struct InspectorSelectionSummary: View {
        let entity: EditorSceneEntitySummary

        var body: some View {
            Row(alignment: .center, spacing: 8) {
                Box(direction: .column, alignItems: .stretch, spacing: 2) {
                    Text(entity.name)
                        .font(.headline)
                        .foregroundColor(.onSurface)

                    Text(entity.kind)
                        .font(.caption)
                        .foregroundColor(.onSurfaceVariant)
                }

                Spacer(minLength: 0)

                Text("ID \(entity.id)")
                    .font(.mono)
                    .foregroundColor(.onSurfaceMuted)
            }
            .padding(horizontal: 10, vertical: 9)
        }
    }

    private func propertySections(_ sections: [EditorInspectorSection],
                                  collapsedIDs: Set<String>) -> [PropertyGridSection] {
        sections.map { section in
            let startsCollapsed = collapsedIDs.contains(section.id)
            PropertyGridSection(
                id: section.id,
                title: section.title,
                rows: section.fields.map { field in
                    PropertyGridRow(id: field.id, label: field.label) {
                        fieldView(field.value)
                    }
                },
                isCollapsible: true,
                startsCollapsed: startsCollapsed
            )
        }
    }

    private func fieldView(_ value: EditorInspectorFieldValue) -> some View {
        switch value {
        case let .readOnly(text):
            return AnyView(
                Text(text)
                    .font(.mono)
                    .foregroundColor(.onSurfaceMuted)
            )
        case let .text(binding):
            return AnyView(TextField(text: binding))
        case let .bool(binding):
            return AnyView(Toggle(isOn: binding))
        case let .number(binding):
            return AnyView(NumberField(value: binding, size: .small))
        case let .vector3(x, y, z):
            return AnyView(vector3Field(x: x, y: y, z: z))
        case let .color(binding):
            return AnyView(ColorField(color: binding))
        }
    }

    private func vector3Field(x: Binding<Float>,
                              y: Binding<Float>,
                              z: Binding<Float>) -> some View {
        Row(alignment: .center, spacing: 4) {
            axisField("X", value: x)
            axisField("Y", value: y)
            axisField("Z", value: z)
        }
    }

    private func axisField(_ label: String,
                           value: Binding<Float>) -> some View {
        Row(alignment: .center, spacing: 4) {
            Text(label)
                .font(.label)
                .foregroundColor(.onSurfaceMuted)
            NumberField(value: value, size: .small)
                .flex()
        }
        .flex()
    }
}
