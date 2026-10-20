import EditorCore
import EngineKernel
import Foundation
import GuavaUI
import GuavaUIRuntime
import GuavaUIWorkspace

/// Owns the window-sized animation layer; the centered barrier is absolute
/// and cannot give an intrinsically sized animation host its height.
/// Only opening animates. Closing removes the modal subtree at once, because
/// retained exit content would keep its focus scope and swallow the next
/// shortcut until the fade finished.
struct CommandPalettePresentation: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let registry: WorkspacePanelRegistry
    let availableHeight: Float

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if app.store.commandPaletteVisible {
                AnimatedVisibility(isVisible: true,
                                   transition: .opacity.combined(with: .move(edge: .top, distance: 12)),
                                   animateOnMount: true) {
                    CommandPaletteOverlay(app: app, controller: controller, registry: registry,
                                          availableHeight: availableHeight)
                }.frame(width: .percent(100), height: .percent(100))
            }
        }.frame(width: .percent(100), height: .percent(100))
    }
}

/// Local commands and quick-open work independently of AI provider settings.
struct CommandPaletteOverlay: View {
    let app: EditorApplication
    let controller: WorkspaceController
    let registry: WorkspacePanelRegistry
    var availableHeight: Float = 720
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
                Row(alignment: .center, spacing: 8) {
                    Icon(UIIcons.Status.sparkles, size: 16, color: EditorChromeTokens.agentColor)
                    TextField(L("Tell Guava what you want to do… (> commands, @ files, # entities)"), text: Binding(get: { app.store.commandPaletteQuery }, set: {
                            selectedIndex = 0
                            resultsOffset = .zero
                            app.store.dispatch(.setCommandPaletteQuery($0))
                        })) { input in
                        input.navigation.focusRequestID = "editor-command-search"
                        // Focus selects the field; a scope prefix (> @ #) must survive the
                        // first keystroke, so the caret starts after it instead.
                        let opening = app.store.commandPaletteQuery
                        if opening.characterCount > 0 {
                            input.navigation.caretRequestID = "editor-command-search-scope"
                            input.navigation.caretRequestIndex = opening.characterCount
                        }
                        input.events.onSubmit = {
                            if !matches.isEmpty { execute(matches[min(selectedIndex, matches.count - 1)]) }
                        }
                        input.events.onKeyDown = { key in
                            if key.scancode == Scancode.arrowDown {
                                select(min(max(0, matches.count - 1), selectedIndex + 1)); return true
                            }
                            if key.scancode == Scancode.arrowUp {
                                select(max(0, selectedIndex - 1)); return true
                            }
                            return false
                        }
                        input.events.onCancel = dismiss
                    }.flex().debugName("command-palette-search")
                    Button(icon: .resource(UIIcons.Action.x), size: 12, tooltip: L("Close"), action: dismiss)
                        .buttonStyle(EditorChromeButtonStyle(height: 24))
                }.padding(12)
                if let entity = app.scene.entitySummary(id: app.store.selectedEntityID) {
                    Row(alignment: .center, spacing: 6) {
                        Text(L("Context")).font(.caption).foregroundColor(.onSurfaceMuted)
                        Icon(UIIcons.Editor.box, size: 11, color: .accent)
                        Text(entity.name, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceVariant)
                    }.padding(horizontal: 14, vertical: 7)
                }
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
                                    }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
                                    Text(item.shortcut).font(.mono).foregroundColor(.onSurfaceVariant)
                                }.padding(horizontal: 10, vertical: 6).frame(width: .percent(100), minWidth: 0)
                            }.buttonStyle(.ghost).frame(width: .percent(100)).frame(height: 56))
                        }
                    }.padding(4).frame(width: .percent(100))
                }.frame(height: resultsHeight).debugName("command-palette-results")
                Divider()
                Text(L("↑ ↓ to select · Enter to run · Escape to close"))
                    .font(.caption).foregroundColor(.onSurfaceMuted).padding(10)
            }
            .frame(width: .percent(92), maxWidth: 620)
            .background(.surfaceRaised).cornerRadius(12).border(.borderStrong, width: 1)
            .shadow(color: Color.black.multipliedAlpha(0.45), offsetY: 20, blur: 50).clipped()
            .debugName("command-palette-card")
        }
    }

    private func results() -> [ResultItem] {
        let raw = app.store.commandPaletteQuery.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let commandsOnly = raw.hasPrefix(">")
        let resourcesOnly = raw.hasPrefix("@")
        let entitiesOnly = raw.hasPrefix("#")
        let query = commandsOnly || resourcesOnly || entitiesOnly ? String(raw.dropFirst()).trimmingCharacters(in: .whitespaces) : raw
        var entries: [ResultItem] = []
        if !resourcesOnly && !entitiesOnly {
            entries = EditorCommandSearch.commands(app: app).map { command in
                ResultItem(id: command.id, title: command.title, detail: L("Command"), shortcut: command.shortcut?.label ?? "",
                           enabled: command.isEnabled, searchText: command.title + " " + command.keywords + " " + command.id,
                           perform: {
                    EditorCommandDispatcher.handle(command.command, app: app, controller: controller,
                        registry: registry, fromCommandPalette: true)
                })
            }
        }
        if !commandsOnly && !entitiesOnly {
            entries += app.workstation.scripts.snapshot.documents.map { document in
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
        if entitiesOnly && app.store.workspaceMode.profile.features.contains(.scene) {
            entries += HierarchyPanelModel.allEntityIDs(in: app.scene.roots).compactMap { id in
                guard let entity = app.scene.entitySummary(id: id) else { return nil }
                return ResultItem(id: "entity/" + String(id), title: entity.name,
                    detail: entity.kind, shortcut: "", enabled: true, searchText: entity.name + " " + entity.kind,
                    perform: { app.store.dispatch(.setSelectedEntity(id)) })
            }
        }
        var matches = entries.compactMap { entry -> (ResultItem, Int)? in
            EditorCommandSearch.score(query, in: entry.searchText).map { (entry, $0) }
        }.sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.id < rhs.0.id : lhs.1 > rhs.1
        }.prefix(60).map { $0.0 }
        if !commandsOnly && !resourcesOnly && !entitiesOnly {
            let text = raw
            let intent = ResultItem(id: "agent.intent", title: text.isEmpty ? L("Open Agent") : L("Ask Guava") + ": " + text,
                detail: app.isAIAvailable ? L("Work with Agent in this context") : L("Set an AI provider in Settings to enable."),
                shortcut: "↵", enabled: true, searchText: "", perform: {
                    EditorCommandDispatcher.handle(.showPanel("intent-input"), app: app, controller: controller,
                                                   registry: registry, fromCommandPalette: true)
                    if !text.isEmpty {
                        if app.isAIAvailable { _ = app.submitNaturalLanguageIntent(text) }
                        else { app.openSettingsWindow() }
                    }
                })
            matches.insert(intent, at: 0)
        }
        return matches
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

    private func dismiss() { app.store.dispatch(.setCommandPaletteVisible(false)) }
}
