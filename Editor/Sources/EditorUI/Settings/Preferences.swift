internal import EditorCore
internal import EngineKernel
internal import GuavaUI
internal import GuavaUIRuntime
private import Foundation

struct SettingsPanel: View {
    let app: EditorApplication
    let session: EditorSettingsSession
    @State private var navigation: SettingsNavigation
    @State private var agent: AgentSettingsState
    @State private var searchFocus: UInt64 = 0

    init(app: EditorApplication, session: EditorSettingsSession) {
        self.app = app; self.session = session
        _navigation = State(wrappedValue: session.navigation)
        _agent = State(wrappedValue: session.agent)
    }

    var body: some View {
        ContainerSizeReader { size in
            let wide = size.width >= 760
            let sections = SettingsSectionID.visible(category: navigation.category, query: navigation.query.stringValue)
            let editor = AgentSettingsEditor(app: app, state: Binding(get: { agent }, set: {
                agent = $0; session.agent = $0
            }), onChange: EditorSettingsPersistence(app: app).didChange)
            Box(direction: .row, alignItems: .stretch, spacing: 0) {
                ShortcutHost { event in
                    guard (event.modifiers.hasGui || event.modifiers.hasCtrl), event.scancode == Scancode.f else { return false }
                    searchFocus &+= 1; return true
                }
                Box(direction: .row, alignItems: .stretch, spacing: 0) {
                    if wide {
                        SettingsSidebar(app: app, category: navigation.category, isSearching: isSearching, onSelect: select)
                        Box {}.frame(width: 1).background(.divider)
                    }
                }.frame(width: wide ? 213 : 0).clipped()
                Box(direction: .column, alignItems: .stretch, spacing: 0) {
                    searchBar(wide: wide)
                    Divider()
                    ScrollView(.vertical, scrollbarGutter: .stable) {
                        Box(direction: .row, alignItems: .stretch, justifyContent: .center) {
                            Box(direction: .column, alignItems: .stretch, spacing: 16) {
                                heading(count: sections.count)
                                if sections.isEmpty {
                                    emptyResults
                                } else {
                                    for section in sections {
                                        AnyView(Box(direction: .column, alignItems: .stretch, spacing: 8) {
                                            if isSearching {
                                                Text(section.category.title).font(.caption).foregroundColor(.onSurfaceMuted)
                                            }
                                            content(section, editor: editor).debugName("settings-section-" + section.rawValue)
                                        })
                                    }
                                }
                            }.frame(width: .percent(100), minWidth: 0, maxWidth: 760)
                        }.padding(wide ? 28 : 18).frame(width: .percent(100), minWidth: 0)
                    }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0).debugName("settings-content-scroll")
                    Divider()
                    footer(editor: editor, showsAgent: sections.contains { $0.category == .agent }, compact: !wide)
                }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
            }.frame(width: .percent(100), height: .percent(100), minWidth: 0, minHeight: 0).background(.background)
        }.flex().frame(minWidth: 0, minHeight: 0).debugName("editor-settings")
    }

    private var isSearching: Bool { !navigation.query.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func select(_ category: SettingsCategory) {
        navigation.category = category; navigation.query = ""; session.navigation = navigation
    }

    private func searchBar(wide: Bool) -> some View {
        TextScalerReader { scaler in
            SurfaceReader { surface in
                Row(alignment: .center, spacing: 10) {
                    if !wide { SettingsCategoryMenu(category: navigation.category, onSelect: select) }
                    Icon(UIIcons.Action.search, size: 15, color: .onSurfaceMuted)
                    TextField(L("Search all settings…"), text: Binding(get: { navigation.query }, set: {
                        navigation.query = $0; session.navigation = navigation
                    })) { input in
                        input.behavior.clearable = true
                        input.navigation.focusRequestID = "settings-search-\(searchFocus)"
                        input.events.onCancel = { navigation.query = ""; session.navigation = navigation }
                    }.textFieldStyle(SettingsSearchStyle()).font(.body).flex().frame(minWidth: 0)
                        .debugName("settings-search")
                    if wide { Text(KeyboardShortcut.primary("F").displayString).font(.caption).foregroundColor(.onSurfaceMuted) }
                }.padding(horizontal: wide ? 28 : 18, vertical: 12)
                    .frame(height: max(56, max(scaler.scale(32), surface.minimumControlExtent) + 24)).background(.surface)
            }
        }
    }

    private func heading(count: Int) -> some View {
        Column(alignment: .leading, spacing: 8) {
            Text(isSearching ? L("Search Results") : navigation.category.title).font(.headline).foregroundColor(.onSurface)
            Text(isSearching ? String(format: L("%lld sections match your search."), Int64(count)) : navigation.category.summary)
                .font(.body).foregroundColor(.onSurfaceMuted)
        }.padding(EdgeInsets(bottom: 8)).frame(width: .percent(100), minWidth: 0)
    }

    private var emptyResults: some View {
        SettingsCard(L("No settings found"), subtitle: L("Try a provider name, a feature, or a different keyword.")) {
            Button(L("Clear search")) { navigation.query = ""; session.navigation = navigation }
                .buttonStyle(.secondary).debugName("settings-clear-search")
        }
    }

    @ViewBuilder
    private func content(_ section: SettingsSectionID, editor: AgentSettingsEditor) -> some View {
        let persist = EditorSettingsPersistence(app: app).didChange
        switch section {
        case .appearance: AppearanceSettings(app: app, onChange: persist)
        case .language: LanguageSettings(app: app, onChange: persist)
        case .selection: SelectionSettings(app: app, onChange: persist)
        case .display: DisplaySettings(app: app, onChange: persist)
        case .provider: AgentProviderSettings(editor: editor)
        case .execution: AgentExecutionSettings(editor: editor)
        case .capabilities: CapabilitySettings(app: app, onChange: persist)
        case .plugins: PluginSettings(app: app)
        case .shortcuts: ShortcutSettings(app: app)
        case .about: AboutSettings(app: app)
        }
    }

    private func footer(editor: AgentSettingsEditor, showsAgent: Bool, compact: Bool) -> some View {
        let feedback = showsAgent || editor.isDirty ? agent.feedback : nil
        return Box(direction: compact && (showsAgent || editor.isDirty) ? .column : .row, alignItems: compact ? .stretch : .center, spacing: 10) {
            Row(alignment: .center, spacing: 6) {
                Box {}.frame(width: 5, height: 5).background(feedback?.isError == true ? .error : editor.isDirty ? .warning : .accent).cornerRadius(3)
                Text(feedback?.message ?? (editor.isDirty ? L("Unapplied Agent changes") : L("Preferences are saved on this computer.")))
                    .font(.caption).foregroundColor(feedback?.isError == true ? .error : .onSurfaceMuted)
                    .flex().frame(minWidth: 0)
            }.flex(compact ? 0 : 1, shrink: 1, basis: compact ? nil : 0).frame(minWidth: 0)
            if showsAgent || editor.isDirty {
                Box(direction: .row, alignItems: .center, justifyContent: .flexEnd, wrap: .wrap, spacing: 8) {
                    Button(L("Discard changes"), isEnabled: editor.isDirty, action: editor.reset)
                        .buttonStyle(.secondary).debugName("settings-agent-reset")
                    Button(L("Apply AI Settings"), isEnabled: editor.isDirty, action: editor.apply)
                        .buttonStyle(.primary).debugName("settings-agent-apply")
                }.frame(minWidth: 0)
            }
        }.padding(horizontal: compact ? 18 : 28, vertical: 12).background(.surface).debugName("settings-footer")
    }
}

private struct SettingsSearchStyle: TextFieldStyle {
    func makeBody(configuration: TextFieldStyleConfiguration) -> some View { configuration.content }
}
