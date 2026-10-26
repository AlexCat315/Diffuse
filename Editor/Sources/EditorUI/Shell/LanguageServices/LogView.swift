internal import EditorCore
internal import CoveUI

struct LanguageServerLogView: View {
    let details: ScriptLanguageServiceDetails?

    var body: some View {
        Column(alignment: .leading, spacing: 5) {
            Text(L("Language Server Logs")).font(.label).foregroundColor(.onSurface)
            if let path = details?.executablePath { Text(path, lineLimit: 3).font(.mono).foregroundColor(.onSurfaceMuted) }
            if let logs = details?.logs, !logs.isEmpty {
                VirtualStack(logs, id: \.id, rowHeight: 48) { entry in
                    Column(alignment: .leading, spacing: 2) {
                        Text(entry.date.formatted(date: .omitted, time: .standard) + " · " + entry.level.rawValue)
                            .font(.caption).foregroundColor(.onSurfaceMuted)
                        Text(entry.message, lineLimit: 2).font(.mono)
                            .foregroundColor(entry.level == .error ? .error : entry.level == .warning ? .warning : .onSurfaceVariant)
                    }
                }.frame(height: 240)
            } else {
                Text(L("No language server logs yet")).font(.caption).foregroundColor(.onSurfaceMuted)
            }
        }.padding(12).debugName("language-server-log-view")
    }
}
