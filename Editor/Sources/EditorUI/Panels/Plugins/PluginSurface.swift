internal import EditorCore
internal import CoveUI
internal import PluginRuntime

/// All plugin modes use the same renderer and public view protocol.
struct PluginSurface: View {
    let app: EditorApplication
    let panel: ContributedPanel
    private var surface: EditorAssistantSurface { .of(app) }
    private var layout: Observed<EditorAssistantSurface, EditorAssistantSurface.State>
    private var catalog: Observed<WorkbenchSession, WorkbenchCatalog>
    init(app: EditorApplication, panel: ContributedPanel) {
        self.app = app; self.panel = panel
        layout = Observed(\.state, on: .of(app))
        catalog = Observed(\.catalog, on: app.workbench)
    }
    var body: some View {
        let _ = layout.wrappedValue
        let target = panel.pluginID + "." + (panel.surface ?? "")
        let regions = catalog.wrappedValue.panels.filter { $0.inSurface == target }
        return Box(direction: .row, alignItems: .stretch, spacing: 0) {
            if surface.regions.leading { region(regions, slot: "leading", width: 280) }
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                content(panel).flex().frame(minWidth: 0, minHeight: 0).debugName("plugin-main")
                region(regions, slot: "bottom", width: nil)
            }.flex().frame(minWidth: 0, minHeight: 0)
            if surface.regions.trailing { region(regions, slot: "trailing", width: 320) }
        }.flex().frame(minWidth: 0, minHeight: 0)
            .debugName("plugin-surface-" + panel.id)
    }

    private func content(_ panel: ContributedPanel) -> some View {
        let app = app
        let session = MainActor.assumeIsolated { app.viewSession(for: panel) }
        return PluginView(session: session).frame(minWidth: 0, minHeight: 0)
    }

    @ViewBuilder private func region(_ panels: [ContributedPanel], slot: String, width: Float?) -> some View {
        let items = panels.filter { $0.slot == slot }
        if let first = items.first {
            let selected = items.first { $0.id == surface.regions.selectedPanels[slot] } ?? first
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                if items.count > 1 {
                    ScrollView(.horizontal) { Row(alignment: .center, spacing: 4) {
                        for item in items {
                            AnyView(Button(item.title) { surface.selectRegionPanel(item.id, slot: slot) }
                                .buttonStyle(EditorChromeButtonStyle(height: 28))
                                .background(item.id == selected.id ? SemanticColorRef.surfaceRaised : .clear).cornerRadius(6)
                                .debugName("plugin-region-tab-" + item.id))
                        }
                    }.padding(8) }.frame(height: 44)
                }
                content(selected).flex().frame(minWidth: 0, minHeight: 0).debugName("plugin-region-content-" + selected.id)
            }.frame(width: width.map { .points($0) }, minWidth: 0, minHeight: 0)
                .flex(0, shrink: 0, basis: width ?? 160)
                .background(.surface)
                .debugName("plugin-region-" + slot)
        }
    }
}
