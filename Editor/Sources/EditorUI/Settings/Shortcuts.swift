internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime

struct ShortcutSettings: View {
    let app: EditorApplication

    var body: some View {
        let entries = EditorCommandCatalog.make(EditorCommandContext(app: app)).entries.filter { $0.shortcut != nil }
        SettingsCard(L("Keyboard Shortcuts"), subtitle: L("These shortcuts follow the commands available in the current Space.")) {
            Column(alignment: .leading, spacing: 0) {
                for entry in entries {
                    AnyView(Column(alignment: .leading, spacing: 0) {
                        Row(alignment: .center, spacing: 12) {
                            Text(entry.title).font(.body).foregroundColor(.onSurfaceVariant).flex().frame(minWidth: 0)
                            Text(entry.shortcut?.label ?? "").font(.mono).foregroundColor(.onSurface)
                                .padding(horizontal: 8, vertical: 4).background(.surfaceSunken).cornerRadius(5).border(.divider, width: 1)
                        }.padding(vertical: 9).frame(width: .percent(100), minWidth: 0)
                        Divider()
                    })
                }
            }.frame(width: .percent(100), minWidth: 0).accessibility { $0.label = L("Keyboard Shortcuts") }
        }
    }
}
