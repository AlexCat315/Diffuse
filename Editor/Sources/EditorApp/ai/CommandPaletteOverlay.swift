import EditorCore
import EngineKernel
import Foundation
import GuavaUICompose
import GuavaUIRuntime
import GuavaUIApp
import GuavaUIWorkspace

/// Owns the window-sized animation layer; the centered barrier is absolute
/// and cannot give an intrinsically sized animation host its height.
struct CommandPalettePresentation: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let registry: PanelRegistry
    let availableHeight: Float

    var body: some View {
        AnimatedVisibility(isVisible: app.store.commandPaletteVisible,
                           transition: .opacity.combined(with: .move(edge: .top, distance: 12))) {
            CommandPaletteOverlay(app: app, controller: controller, registry: registry,
                                  availableHeight: availableHeight)
        }.frame(width: .percent(100), height: .percent(100))
    }
}

/// Local commands and quick-open work independently of AI provider settings.
struct CommandPaletteOverlay: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let registry: PanelRegistry
    var availableHeight: Float = 720
    @State private var aiMode = false
    @State private var aiInput = ""
    @State private var selectedIndex = 0
    @State private var resultsOffset = CGPoint.zero
    private var resultsHeight: Float { max(80, min(320, availableHeight - 168)) }

    private struct ResultItem {
        let id: String
        let title: String
        let detail: String
        let shortcut: String
        let enabled: Bool
        let searchText: String
        let perform: () -> Void
    }

    var body: some View {
        let matches = results()
        ModalBarrier(onBackgroundTap: dismiss) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                Row(alignment: .center, spacing: 6) {
                    Button(L("Commands and Resources"), isSelected: !aiMode) { aiMode = false }.buttonStyle(.tab)
                    Button(L("AI Intent"), isSelected: aiMode) { aiMode = true }.buttonStyle(.tab)
                    Spacer(minLength: 0)
                    Button(icon: .resource(UICommonIcons.close), size: 12, action: dismiss).buttonStyle(.ghost)
                }.padding(horizontal: 10, vertical: 8)
                Divider()
                if aiMode {
                    TextField(L("Describe what you want to do…"), text: $aiInput, onSubmit: submitAI,
                              onCancel: dismiss).padding(12)
                    if !app.isAIAvailable {
                        Text(L("Set an AI provider in Settings to enable.")).font(.caption).foregroundColor(.warning).padding(12)
                        Button(L("Open Settings")) { dismiss(); app.openSettingsWindow() }.padding(12)
                    }
                    if app.store.aiStatusMessage != nil || !app.store.aiWarnings.isEmpty {
                        AIStatusFeedback(status: app.store.aiStatusMessage, warnings: app.store.aiWarnings).padding(12)
                    }
                } else {
                    TextField(L("Search commands or resources (> commands, @ resources)"),
                        text: Binding(get: { app.store.commandPaletteQuery }, set: {
                            selectedIndex = 0
                            resultsOffset = .zero
                            app.store.dispatch(.setCommandPaletteQuery($0))
                        }), focusRequestID: "editor-command-search", onSubmit: {
                            if !matches.isEmpty { execute(matches[min(selectedIndex, matches.count - 1)]) }
                        }, onKeyDown: { key in
                            if key.scancode == Scancode.arrowDown {
                                select(min(max(0, matches.count - 1), selectedIndex + 1)); return true
                            }
                            if key.scancode == Scancode.arrowUp {
                                select(max(0, selectedIndex - 1)); return true
                            }
                            return false
                        }, onCancel: dismiss).padding(12).debugName("command-palette-search")
                    Divider()
                    ScrollView(.vertical, scrollbarGutter: .stable, scrollOffset: $resultsOffset) {
                        Column(alignment: .leading, spacing: 2) {
                            if matches.isEmpty {
                                EditorPanelEmptyState(L("No matching commands or resources"))
                            }
                            matches.indices.map { index in
                                let item = matches[index]
                                return AnyView(Button(isEnabled: item.enabled, isSelected: index == selectedIndex,
                                       action: { execute(item) }) {
                                    Row(alignment: .center, spacing: 8) {
                                        Column(alignment: .leading, spacing: 2) {
                                            Text(item.title, lineLimit: 1).font(.label)
                                            Text(item.detail, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
                                        }.flex()
                                        Text(item.shortcut).font(.mono).foregroundColor(.onSurfaceVariant)
                                    }.padding(horizontal: 10, vertical: 6)
                                }.buttonStyle(.ghost).frame(width: .percent(100)).frame(height: 56))
                            }
                        }.padding(4).frame(width: .percent(100))
                    }.frame(height: resultsHeight).debugName("command-palette-results")
                }
                Divider()
                Text(L("↑ ↓ to select · Enter to run · Escape to close"))
                    .font(.caption).foregroundColor(.onSurfaceMuted).padding(10)
            }
            .frame(width: .percent(92), maxWidth: 580)
            .background(.surfaceFloating).cornerRadius(10).border(.border, width: 1)
            .debugName("command-palette-card")
        }
    }

    private func results() -> [ResultItem] {
        let raw = app.store.commandPaletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandsOnly = raw.hasPrefix(">")
        let resourcesOnly = raw.hasPrefix("@")
        let query = commandsOnly || resourcesOnly ? String(raw.dropFirst()).trimmingCharacters(in: .whitespaces) : raw
        var entries: [ResultItem] = []
        if !resourcesOnly {
            entries = EditorCommandSearch.commands(app: app).map { command in
                ResultItem(id: command.id, title: command.title, detail: L("Command"), shortcut: command.shortcut,
                           enabled: command.enabled, searchText: command.title + " " + command.keywords + " " + command.id,
                           perform: {
                    EditorCommandDispatcher.handle(command.command, app: app, controller: controller,
                        registry: registry, fromCommandPalette: true)
                })
            }
        }
        if !commandsOnly {
            entries += app.scriptWorkspace.snapshot.documents.map { document in
                ResultItem(id: "script/" + document.file.identifier, title: document.file.displayName + ".swift",
                    detail: "Scripts/", shortcut: "", enabled: true,
                    searchText: document.file.displayName + " " + document.file.identifier,
                    perform: { app.navigateToIssue(.script(id: document.file.identifier, line: 0, column: 0)) })
            }
            entries += EditorAssetCatalog.entries().map { asset in
                ResultItem(id: "asset/" + asset.id, title: asset.name, detail: asset.relativePath,
                    shortcut: "", enabled: true, searchText: asset.name + " " + asset.relativePath + " " + asset.kind.sceneKindLabel,
                    perform: { app.navigateToIssue(.asset(id: asset.id)) })
            }
        }
        return entries.compactMap { entry -> (ResultItem, Int)? in
            EditorCommandSearch.score(query, in: entry.searchText).map { (entry, $0) }
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 > rhs.1
        }.prefix(60).map { $0.0 }
    }

    private func execute(_ item: ResultItem) {
        guard item.enabled else { return }
        dismiss()
        item.perform()
    }

    private func select(_ index: Int) {
        selectedIndex = index
        let top = CGFloat(index * 58 + 4)
        if top < resultsOffset.y { resultsOffset.y = top }
        else if top + 56 > resultsOffset.y + CGFloat(resultsHeight) {
            resultsOffset.y = top + 56 - CGFloat(resultsHeight)
        }
    }

    private func submitAI() {
        let trimmed = aiInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, app.submitNaturalLanguageIntent(trimmed) { dismiss() }
    }

    private func dismiss() { app.store.dispatch(.setCommandPaletteVisible(false)) }
}
