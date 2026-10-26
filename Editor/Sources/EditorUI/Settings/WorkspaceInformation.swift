internal import EditorCore
internal import CoveUI
internal import CoveUIRuntime
private import Foundation

struct AboutSettings: View {
    let app: EditorApplication
    @State private var copied = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("Development")
    }

    var body: some View {
        SettingsCard(L("Workspace Information")) {
            Row(alignment: .center, spacing: 12) {
                SettingsBrandMark(size: 44)
                Column(alignment: .leading, spacing: 4) {
                    Text("Cove Studio").font(.headline).foregroundColor(.onSurface)
                    Text(version).font(.caption).foregroundColor(.onSurfaceMuted)
                }
            }
            information(L("Project"), value: URL(fileURLWithPath: app.projectDirectory).lastPathComponent)
            information(L("Project directory"), value: app.projectDirectory)
            information(L("Operating system"), value: ProcessInfo.processInfo.operatingSystemVersionString)
            Text(L("Copy application and workspace information for a support request. Credentials are excluded."))
                .font(.body).foregroundColor(.onSurfaceMuted)
            Button(copied ? L("Copied") : L("Copy diagnostics"), isEnabled: ClipboardHolder.write != nil) {
                ClipboardHolder.write?("Cove Studio \(version)\nOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nProject: \(app.projectDirectory)\nContent: \(app.store.content.rawValue)\nTheme: \(app.store.themeMode)\nLanguage: \(app.store.language)\nPlugins: \(app.store.pluginManagement.installed.filter(\.lifecycle.isEnabled).count)")
                copied = true
            }.buttonStyle(.secondary).debugName("settings-copy-diagnostics")
        }
    }

    private func information(_ label: String, value: String) -> some View {
        Column(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundColor(.onSurfaceMuted)
            Text(value).font(.body).foregroundColor(.onSurfaceVariant)
        }.frame(width: .percent(100), minWidth: 0)
    }
}
