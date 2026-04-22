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

            Box(direction: .column, alignItems: .stretch) {
                if let entity {
                    InspectorSelectionSummary(entity: entity)

                    Divider()

                    PropertyGrid(propertySections(sections),
                                 labelWidth: 104,
                                 rowHeight: 28)
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

    private func propertySections(_ sections: [EditorInspectorSection]) -> [PropertyGridSection] {
        sections.map { section in
            PropertyGridSection(
                id: section.id,
                title: section.title,
                rows: section.fields.map { field in
                    PropertyGridRow(id: field.id, label: field.label) {
                        fieldView(field.value)
                    }
                }
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
            return AnyView(
                Button(binding.wrappedValue ? "On" : "Off") {
                    binding.wrappedValue.toggle()
                }
                .buttonStyle(.secondary)
            )
        }
    }
}
