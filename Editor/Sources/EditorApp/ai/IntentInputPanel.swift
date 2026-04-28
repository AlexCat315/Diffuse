import EditorCore
import GuavaUICompose
import GuavaUIRuntime
import simd

struct IntentInputPanel: View {
    let app: EditorApplication

    @State private var spawnLabel: String = "AI Entity"
    @State private var spawnX: Float = 0
    @State private var spawnY: Float = 0
    @State private var spawnZ: Float = 0
    @State private var transformX: Float = 0
    @State private var transformY: Float = 0
    @State private var transformZ: Float = 0

    init(app: EditorApplication) {
        self.app = app
    }

    var body: some View {
        StoreScope(app.store, select: IntentInputPanelSelection.init) { store in
            let selection = app.scene.entitySummary(id: store.state.selectedEntityID)

            ScrollView(.vertical) {
                Box(direction: .column, alignItems: .stretch, spacing: 10) {
                    AIStatusSummary(status: store.state.aiStatusMessage,
                                    warnings: store.state.aiWarnings)

                    AISection(title: "Selection") {
                        Box(direction: .column, alignItems: .stretch, spacing: 4) {
                            Text(selection.map { "\($0.name) · ID \($0.id)" } ?? "No selection")
                                .font(.bodyStrong)
                            Text(selection?.kind ?? "Select an entity for transform or delete actions.")
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                        }
                    }

                    AISection(title: "scene.spawn_entity") {
                        Box(direction: .column, alignItems: .stretch, spacing: 8) {
                            TextField(text: $spawnLabel)
                            Vector3Fields(x: $spawnX, y: $spawnY, z: $spawnZ)
                            Button(L("Spawn Entity")) {
                                app.submitSpawnEntityIntent(label: spawnLabel,
                                                            position: SIMD3<Float>(spawnX, spawnY, spawnZ))
                            }
                        }
                    }

                    AISection(title: "scene.set_transform") {
                        Box(direction: .column, alignItems: .stretch, spacing: 8) {
                            Vector3Fields(x: $transformX, y: $transformY, z: $transformZ)
                            Row(alignment: .center, spacing: 8) {
                                Button(L("Use Selection"), isEnabled: selection != nil) {
                                    if let translation = app.currentSelectedEntityTranslation() {
                                        transformX = translation.x
                                        transformY = translation.y
                                        transformZ = translation.z
                                    }
                                }
                                .buttonStyle(SecondaryButtonStyle())
                                Button(L("Set Transform"), isEnabled: selection != nil) {
                                    app.submitSetTransformIntent(translation: SIMD3<Float>(transformX,
                                                                                            transformY,
                                                                                            transformZ))
                                }
                            }
                        }
                    }

                    AISection(title: "scene.delete_entity") {
                        Box(direction: .column, alignItems: .stretch, spacing: 8) {
                            Text(L("Delete the current selection through IntentRuntime confirmation flow."))
                                .font(.caption)
                                .foregroundColor(.onSurfaceMuted)
                            Button(L("Delete Selection"),
                                   role: .destructive,
                                   isEnabled: selection != nil) {
                                app.submitDeleteSelectedEntityIntent()
                            }
                        }
                    }
                }
                .padding(10)
            }
            .frame(minWidth: 320)
        }
    }
}

private struct IntentInputPanelSelection: Hashable {
    let selectedEntityID: UInt64?
    let aiStatusMessage: String?
    let aiWarnings: [String]
    let sceneRevision: UInt64
    let themeMode: EditorThemeMode
    let language: EditorLanguage

    init(_ state: EditorState) {
        self.selectedEntityID = state.selectedEntityID
        self.aiStatusMessage = state.aiStatusMessage
        self.aiWarnings = state.aiWarnings
        self.sceneRevision = state.sceneRevision
        self.themeMode = state.themeMode
        self.language = state.language
    }
}

private struct AIStatusSummary: View {
    let status: String?
    let warnings: [String]

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 6) {
            Text(status ?? L("Ready"))
                .font(.bodyStrong)
                .foregroundColor(status == nil ? .success : .onSurface)
            if warnings.isEmpty {
                Text(L("No active warnings"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
            } else {
                Text(warnings.joined(separator: "\n"))
                    .font(.caption)
                    .foregroundColor(.warning)
            }
        }
        .padding(8)
        .background(.surfaceSunken)
        .cornerRadius(2)
    }
}

private struct AISection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 8) {
            Text(title)
                .font(.mono)
                .foregroundColor(.onSurfaceMuted)
            content
        }
        .padding(8)
        .background(.surfaceOverlay)
        .cornerRadius(2)
    }
}

private struct Vector3Fields: View {
    let x: Binding<Float>
    let y: Binding<Float>
    let z: Binding<Float>

    init(x: Binding<Float>, y: Binding<Float>, z: Binding<Float>) {
        self.x = x
        self.y = y
        self.z = z
    }

    var body: some View {
        Row(alignment: .center, spacing: 6) {
            AxisField(label: "X", value: x)
            AxisField(label: "Y", value: y)
            AxisField(label: "Z", value: z)
        }
    }
}

private struct AxisField: View {
    let label: String
    let value: Binding<Float>

    init(label: String, value: Binding<Float>) {
        self.label = label
        self.value = value
    }

    var body: some View {
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
