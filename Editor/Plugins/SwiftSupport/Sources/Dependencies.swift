import CovePluginKit

/// The packages a `Package.resolved` pins, as a table beside its JSON: what
/// SwiftPM resolved, at which version or branch, and where it comes from.
func view(view: String, state: String, event: String, context: String) -> String {
    let text = JSON.parse(context)?["text"]?.string ?? ""
    guard let pins = JSON.parse(text)?["pins"]?.array else {
        return UI.result(state: nil, ui: UI.text("This file is not a Package.resolved SwiftPM can read.", tone: "danger"))
    }
    var rows: [JSON] = []
    for pin in pins {
        let state = pin["state"]
        let version = state?["version"]?.string ?? state?["branch"]?.string.map { "branch " + $0 } ?? "—"
        let revision = state?["revision"]?.string.map { String($0.prefix(10)) } ?? ""
        rows.append(UI.tableRow([pin["identity"]?.string ?? "?", version, revision, pin["location"]?.string ?? ""]))
    }
    return UI.result(state: nil, ui: UI.scroll(UI.column([
        UI.text("\(pins.count) pinned packages", style: "caption", tone: "muted"),
        UI.table(columns: ["Package", "Version", "Revision", "Location"], rows: rows),
    ], spacing: 6, padding: 10)))
}
