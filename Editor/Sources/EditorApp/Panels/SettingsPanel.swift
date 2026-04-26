import EditorCore
import GuavaUICompose
import GuavaUIRuntime

struct SettingsPanel: View {
    let app: EditorApplication

    var body: some View {
        StoreScope(app.store) { store in
            ScrollView(.vertical) {
                Box(direction: .column, alignItems: .stretch, spacing: 14) {
                    SettingsSection(title: L("Appearance")) {
                        Row(alignment: .center, spacing: 8) {
                            SettingsChoiceButton(title: L("Dark"),
                                                 isActive: store.state.themeMode == .dark) {
                                store.dispatch(.setThemeMode(.dark))
                                applySettingsChange(store)
                            }
                            SettingsChoiceButton(title: L("Light"),
                                                 isActive: store.state.themeMode == .light) {
                                store.dispatch(.setThemeMode(.light))
                                applySettingsChange(store)
                            }
                        }
                    }

                    SettingsSection(title: L("Frame Rate")) {
                        Box(direction: .column, alignItems: .flexStart, spacing: 8) {
                            Row(alignment: .center, spacing: 8) {
                                frameRateButton(.unlimited, store: store)
                                frameRateButton(.fps30, store: store)
                                frameRateButton(.fps60, store: store)
                                frameRateButton(.fps120, store: store)
                            }
                        }
                    }

                    SettingsSection(title: L("Language")) {
                        Row(alignment: .center, spacing: 8) {
                            SettingsChoiceButton(title: L("System"),
                                                 isActive: store.state.language == .system) {
                                store.dispatch(.setLanguage(.system))
                                EditorLocalizationPreferences.language = .system
                                applySettingsChange(store)
                            }
                            SettingsChoiceButton(title: "English",
                                                 isActive: store.state.language == .english) {
                                store.dispatch(.setLanguage(.english))
                                EditorLocalizationPreferences.language = .english
                                applySettingsChange(store)
                            }
                            SettingsChoiceButton(title: "简体中文",
                                                 isActive: store.state.language == .simplifiedChinese) {
                                store.dispatch(.setLanguage(.simplifiedChinese))
                                EditorLocalizationPreferences.language = .simplifiedChinese
                                applySettingsChange(store)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .flex()
            .frame(minWidth: 220)
        }
    }

    private func applySettingsChange(_ store: EditorStore) {
        persistShell(store)
        app.requestDisplayRefresh()
    }

    private func persistShell(_ store: EditorStore) {
        EditorRootViewFactory.saveShellState(mode: store.state.workspaceMode,
                                             preset: store.state.activeLayoutPreset,
                                             themeMode: store.state.themeMode,
                                             language: store.state.language,
                                             frameRateLimit: store.state.frameRateLimit)
    }

    private func title(for limit: EditorFrameRateLimit) -> String {
        switch limit {
        case .unlimited:
            if let refreshRate = app.currentDisplayRefreshRate() {
                return String(format: "%@ %.0f FPS", L("System"), refreshRate)
            }
            return L("System")
        case .fps30:
            return "30 FPS"
        case .fps60:
            return "60 FPS"
        case .fps120:
            return "120 FPS"
        case .fps240:
            return "240 FPS"
        }
    }

    private func frameRateButton(_ limit: EditorFrameRateLimit,
                                 store: EditorStore) -> SettingsChoiceButton {
        SettingsChoiceButton(title: title(for: limit),
                             isActive: store.state.frameRateLimit == limit) {
            store.dispatch(.setFrameRateLimit(limit))
            app.applyFrameRateLimit(limit)
            applySettingsChange(store)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            content
        }
    }
}

private struct SettingsChoiceButton: View {
    let title: String
    let isActive: Bool
    let onClick: () -> Void

    var body: some View {
        Button(action: onClick) {
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Text(title, lineLimit: 1)
                    .font(.caption)
                    .foregroundColor(isActive ? .onAccent : .onSurface)
            }
            .frame(height: 30, minWidth: 86)
            .padding(horizontal: 10, vertical: 0)
            .background(isActive ? .accent : .surfaceSunken)
            .cornerRadius(4)
            .clipped()
        }
        .buttonStyle(.plain)
    }
}
