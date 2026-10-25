internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

/// Package commands placed on the title bar, one icon button each.
struct PluginToolbar: View {
    let items: [ContributedToolbarItem]
    let onCommand: (EditorCommand) -> Void

    var body: some View {
        Row(alignment: .center, spacing: 2) {
            items.map { item in
                AnyView(Button(icon: .resource(.svg(named: item.icon, in: EditorAppResourceBundle.bundle,
                                                    subdirectory: "ToolbarIcons")),
                               size: 13, tooltip: item.command.title) {
                    onCommand(.plugin(pluginID: item.command.pluginID, name: item.command.name))
                }.buttonStyle(ToggleButtonStyle(height: 26)).debugName("editor-plugin-tool-" + item.command.id))
            }
        }.debugName("editor-plugin-toolbar")
    }
}
