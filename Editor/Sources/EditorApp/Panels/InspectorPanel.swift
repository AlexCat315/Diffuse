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
                Text("Inspector")
                    .font(.headline)
                if let entity {
                    Text(entity.name)
                        .font(.title)
                    Text(entity.kind)
                        .font(.label)
                        .foregroundColor(.accent)
                    Text("Entity ID: \(entity.id)")
                        .font(.mono)
                    PropertyGrid(propertySections(sections))
                        .flex()
                } else {
                    Text("No selection")
                        .font(.bodyStrong)
                    Text("Pick a node in Hierarchy to inspect SceneRuntime components.")
                        .font(.caption)
                        .foregroundColor(.onSurfaceMuted)
                }
            }
            .padding(8)
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
