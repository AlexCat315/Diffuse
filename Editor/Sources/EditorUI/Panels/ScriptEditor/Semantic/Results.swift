internal import EditorCore
internal import Foundation
internal import GuavaUI

struct ScriptSemanticResults: View {
    let session: ScriptSemanticSession

    var body: some View {
        let presentation = session.presentation
        // Results slide open under the code instead of pushing it in one jump.
        AnimatedVisibility(isVisible: presentation.isVisible || presentation.signature != nil) {
            Column(alignment: .leading, spacing: 4) {
                if presentation.isVisible {
                    Row(alignment: .center, spacing: 6) {
                        Text(L(presentation.title)).font(.label).foregroundColor(.onSurfaceVariant)
                        if presentation.isBusy { Text(L("Loading…")).font(.caption).foregroundColor(.onSurfaceMuted) }
                        Spacer(minLength: 0)
                        Button(L("Close"), action: session.dismiss).buttonStyle(.ghost)
                    }
                    if let message = presentation.message {
                        Text(message, lineLimit: 3).font(.caption).foregroundColor(.onSurfaceVariant)
                    }
                    if let text = presentation.renameText {
                        Row(alignment: .center, spacing: 6) {
                            TextField(L("New name"), text: Binding(get: { session.presentation.renameText ?? text }, set: session.updateRename)) {
                                $0.events.onSubmit = session.confirmRename
                            }.flex(1, shrink: 1).debugName("script-symbol-rename-input")
                            Button(L("Rename"), isEnabled: !presentation.isBusy && !text.isEmpty, action: session.confirmRename)
                                .buttonStyle(.primary).debugName("script-symbol-rename-confirm")
                        }
                    }
                    if !presentation.locations.isEmpty {
                        VirtualStack(Array(presentation.locations.enumerated()), id: \.offset, rowHeight: 28) { entry in
                            Button(action: { session.open(entry.element) }) {
                                Text(locationTitle(entry.element), lineLimit: 1).font(.mono).foregroundColor(.onSurface)
                            }.buttonStyle(.ghost)
                        }.frame(height: min(160, Float(presentation.locations.count) * 28)).debugName("script-language-locations")
                    }
                    if !presentation.actions.isEmpty {
                        let rows = ScriptCodeActionRow.rows(presentation.actions)
                        VirtualStack(Array(rows.enumerated()), id: \.offset, rowHeight: 30) { entry in
                            switch entry.element {
                            case let .group(title):
                                AnyView(Text(L(title), lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
                                    .padding(horizontal: 8, vertical: 8))
                            case let .action(action):
                                AnyView(Button(isEnabled: action.disabledReason == nil && !presentation.isBusy,
                                               tooltip: action.disabledReason, action: { session.apply(action) }) {
                                    Text((action.isPreferred ? "★ " : "") + action.title, lineLimit: 1)
                                        .font(.caption).foregroundColor(.onSurface)
                                }.buttonStyle(.ghost))
                            }
                        }.frame(height: min(220, Float(rows.count) * 30)).debugName("script-language-code-actions")
                    }
                    if !presentation.symbols.isEmpty {
                        let rows = symbolRows(presentation.symbols)
                        VirtualStack(Array(rows.enumerated()), id: \.offset, rowHeight: 28) { entry in
                            Button(action: { session.open(entry.element.symbol) }) {
                                Row(alignment: .center, spacing: 6) {
                                    Icon(ScriptSymbolIcon(kind: entry.element.symbol.kind).resource, size: 12, color: .onSurfaceVariant)
                                        .debugName("script-symbol-icon-\(entry.element.symbol.kind)")
                                    Text(entry.element.symbol.name, lineLimit: 1)
                                        .font(.mono).foregroundColor(.onSurface)
                                }.padding(EdgeInsets(leading: Float(entry.element.depth) * 16))
                            }.buttonStyle(.ghost)
                                .accessibility { $0.label = entry.element.symbol.name }
                        }.frame(height: min(180, Float(rows.count) * 28)).debugName("script-language-outline")
                    }
                }
                if let help = presentation.signature, !help.signatures.isEmpty {
                    let signature = help.signatures[min(max(0, help.activeSignature), help.signatures.count - 1)]
                    Text(signature.label, lineLimit: 3).font(.mono).foregroundColor(.onSurface)
                    if let parameter = help.activeParameter, parameter >= 0, parameter < signature.parameters.count {
                        let active = signature.parameters[parameter]
                        Text(active.label + (active.documentation?.components(separatedBy: "\n\n").first.map { " — " + $0 } ?? ""), lineLimit: 2)
                            .font(.caption).foregroundColor(.accent)
                    }
                    // The summary paragraph only; the rest belongs in hover, not over the code.
                    if let documentation = signature.documentation?.components(separatedBy: "\n\n").first {
                        Text(documentation, lineLimit: 2).font(.caption).foregroundColor(.onSurfaceMuted)
                    }
                }
            }.padding(horizontal: 10, vertical: presentation.isVisible || presentation.signature != nil ? 6 : 0)
                .background(.surface).debugName("script-language-results")
        }
    }

    private func locationTitle(_ location: ScriptDefinitionLocation) -> String {
        let file = URL(string: location.documentURI)?.lastPathComponent ?? location.scriptID ?? location.documentURI
        return "\(file):\(location.span.start.line + 1):\(location.span.start.character + 1)"
    }

    private struct SymbolRow {
        let symbol: ScriptDocumentSymbol
        let depth: Int
    }

    private func symbolRows(_ symbols: [ScriptDocumentSymbol], depth: Int = 0) -> [SymbolRow] {
        symbols.flatMap { [SymbolRow(symbol: $0, depth: depth)] + symbolRows($0.children, depth: depth + 1) }
    }
}

/// Code actions under their kind, quick fixes first; a single kind needs no heading.
enum ScriptCodeActionRow {
    case group(String)
    case action(ScriptCodeAction)

    static func rows(_ actions: [ScriptCodeAction]) -> [Self] {
        let groups = ["quickfix": "Quick Fix", "refactor": "Refactor", "source": "Source Action"]
        let order = ["Quick Fix", "Refactor", "Source Action", "Other"]
        let grouped = Dictionary(grouping: actions) { action in
            groups[String((action.kind ?? "").split(separator: ".").first ?? "")] ?? "Other"
        }
        let present = order.filter { grouped[$0] != nil }
        return present.flatMap { title -> [Self] in
            let members = grouped[title, default: []].sorted { $0.isPreferred && !$1.isPreferred }.map(Self.action)
            return present.count > 1 ? [.group(title)] + members : members
        }
    }
}
