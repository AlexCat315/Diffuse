internal import EditorCore
internal import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

/// The language sessions a document editor keeps for its Swift tabs.
struct ScriptDocumentSessions {
    let semantic: ScriptSemanticSession
    let insights: ScriptInsightSession

    init(app: EditorApplication) {
        semantic = ScriptSemanticSession(app: app)
        insights = ScriptInsightSession(app: app)
    }
}

/// The path bar of a Swift tab, laid out like JetBrains' navigation bar:
/// history on the left, then the file and the declarations around the caret,
/// then the jumps that act on the symbol under the caret, and finally the
/// script's build state, Build, and the file's other actions.
struct ScriptDocumentBar: View {
    let app: EditorApplication
    let sessions: ScriptDocumentSessions
    let path: String
    private var semanticRevision: Observed<ScriptSemanticSession, UInt64>
    private var insightRevision: Observed<ScriptInsightSession, UInt64>
    @State private var isOutlinePresented = false
    @State private var isMenuPresented = false

    init(app: EditorApplication, sessions: ScriptDocumentSessions, path: String) {
        self.app = app
        self.sessions = sessions
        self.path = path
        semanticRevision = Observed(\.revision, on: sessions.semantic)
        insightRevision = Observed(\.revision, on: sessions.insights)
    }

    var body: some View {
        let _ = semanticRevision.wrappedValue
        let _ = insightRevision.wrappedValue
        let semantic = sessions.semantic
        let insights = sessions.insights
        Row(alignment: .center, spacing: 6) {
            ScriptNavigationButtons(commands: [.back, .forward], canPerform: semantic.canPerform, perform: semantic.perform)
            // The trail gives way first, so the jump buttons stay reachable.
            Row(alignment: .center, spacing: 6) {
                DocumentPathCrumbs(path: path)
                for symbol in insights.path(atLine: insights.caretLine) {
                    AnyView(Icon(UIIcons.Navigation.chevronRight, size: 9, color: .onSurfaceMuted))
                    AnyView(Button(tooltip: symbol.detail ?? symbol.name, action: { semantic.open(symbol) }) {
                        Row(alignment: .center, spacing: 4) {
                            Icon(ScriptSymbolIcon(kind: symbol.kind).resource, size: 11, color: .onSurfaceVariant)
                            Text(symbol.name, lineLimit: 1).font(.caption).foregroundColor(.onSurface)
                        }.padding(horizontal: 4).frame(height: 22)
                    }.buttonStyle(EditorChromeButtonStyle(height: 22)).debugName("script-crumb-\(symbol.name)"))
                }
            }.flex(1, shrink: 1).frame(minWidth: 0).clipped()
            ScriptNavigationButtons(commands: [.definition, .implementations, .references],
                                    canPerform: semantic.canPerform, perform: semantic.perform)
            outline(insights.symbols, semantic: semantic)
            ScriptWorkspaceReader(app.workstation.scripts) { snapshot in
                if let document = snapshot.selectedDocument {
                    ScriptBuildControl(app: app, document: document, allowsExecution: snapshot.trustState.allowsExecution)
                        .padding(EdgeInsets(leading: 6))
                }
            }
            Popover(isPresented: $isMenuPresented, width: 230, placement: .bottomTrailing, surface: .content, overflow: .flip,
                    triggerStyle: AnyButtonStyle(EditorChromeButtonStyle(height: 24)),
                    label: { Icon(UIIcons.Action.moreHorizontal, size: 13, color: .onSurfaceVariant).padding(horizontal: 5) }) {
                Menu(ScriptFileActions.entries(app: app, path: path), width: 230, onItemActivated: { isMenuPresented = false })
            }
            .tooltip(L("More Actions"))
            .accessibility { $0.label = L("More Actions") }
            .debugName("script-actions")
        }
        .padding(EdgeInsets(leading: 6, trailing: 8))
        .frame(height: 30)
        .debugName("document-path-bar")
    }

    /// Every declaration in the file, indented by depth, with its kind icon.
    private func outline(_ symbols: [ScriptDocumentSymbol], semantic: ScriptSemanticSession) -> some View {
        var entries: [MenuEntry] = []
        func add(_ symbols: [ScriptDocumentSymbol], depth: Int) {
            for symbol in symbols {
                let indent = String(repeating: "    ", count: depth)
                entries.append(.item(MenuItem(id: "outline-\(entries.count)", title: indent + symbol.name,
                    content: MenuItemContent(icon: ScriptSymbolIcon(kind: symbol.kind).resource)) { semantic.open(symbol) }))
                add(symbol.children, depth: depth + 1)
            }
        }
        add(symbols, depth: 0)
        return Popover(isPresented: $isOutlinePresented, isEnabled: !entries.isEmpty, width: 280,
                              placement: .bottomTrailing, surface: .content, overflow: .flip,
                              triggerStyle: AnyButtonStyle(EditorChromeButtonStyle(height: 24)),
                              label: { Icon(ScriptSemanticCommand.symbols.icon, size: 13, color: .onSurfaceVariant).padding(horizontal: 5) }) {
            Menu(entries, width: 280, onItemActivated: { isOutlinePresented = false })
        }
        .tooltip(ScriptSemanticCommand.symbols.help)
        .accessibility { $0.label = L(ScriptSemanticCommand.symbols.title) }
        .debugName("script-outline")
    }
}

/// A Swift tab's editing area: trust and disk-change notices above the
/// editor. Its text is the script workspace's selection, which follows the
/// front tab; should the two ever part, the tab offers to resync.
struct ScriptDocumentSurface: View {
    let app: EditorApplication
    let sessions: ScriptDocumentSessions
    let scriptID: String
    let path: String

    var body: some View {
        ScriptWorkspaceReader(app.workstation.scripts) { snapshot in
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                if snapshot.selectedScriptID == scriptID || sessions.semantic.externalDocument != nil {
                    ScriptTrustBanner(app: app, snapshot: snapshot)
                    if sessions.semantic.externalDocument == nil, let document = snapshot.selectedDocument {
                        ScriptExternalChangeBanner(app: app, document: document)
                    }
                    ScriptSourceEditor(app: app, semantic: sessions.semantic, insights: sessions.insights)
                        .flex().frame(minWidth: 0, minHeight: 0)
                } else {
                    EditorPanelEmptyState(L("This script needs reloading"),
                                          detail: L("Reload it to keep editing in this tab."))
                    Button(L("Reload")) { app.workstation.documents.open(path) }
                        .buttonStyle(.secondary)
                }
            }.flex().frame(minWidth: 0, minHeight: 0)
        }
    }
}
