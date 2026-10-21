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
                        VirtualStack(Array(presentation.actions.enumerated()), id: \.offset, rowHeight: 30) { entry in
                            Button(isEnabled: entry.element.disabledReason == nil && !presentation.isBusy,
                                   tooltip: entry.element.disabledReason, action: { session.apply(entry.element) }) {
                                Text((entry.element.isPreferred ? "★ " : "") + entry.element.title, lineLimit: 1)
                                    .font(.caption).foregroundColor(.onSurface)
                            }.buttonStyle(.ghost)
                        }.frame(height: min(160, Float(presentation.actions.count) * 30)).debugName("script-language-code-actions")
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
                        Text(active.label + (active.documentation.map { " — " + $0 } ?? ""), lineLimit: 2)
                            .font(.caption).foregroundColor(.accent)
                    }
                    if let documentation = signature.documentation {
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
