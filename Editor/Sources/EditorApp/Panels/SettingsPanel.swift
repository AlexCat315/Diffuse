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
                                                 isActive: store.themeMode == .dark) {
                                store.dispatch(.setThemeMode(.dark))
                                applySettingsChange(store)
                            }
                            SettingsChoiceButton(title: L("Light"),
                                                 isActive: store.themeMode == .light) {
                                store.dispatch(.setThemeMode(.light))
                                applySettingsChange(store)
                            }
                        }
                    }

                    SettingsSection(title: L("Vertical Sync")) {
                        Row(alignment: .center, spacing: 10) {
                            Toggle(isOn: Binding(get: {
                                store.vsyncMode.isEnabled
                            }, set: { enabled in
                                applyVSyncMode(enabled ? .enabled : .disabled, store: store)
                            }))

                            Text(store.vsyncMode.isEnabled ? L("On") : L("Off"))
                                .font(.caption)
                                .foregroundColor(.onSurface)
                        }
                    }

                    SettingsSection(title: L("Language")) {
                        Row(alignment: .center, spacing: 8) {
                            SettingsChoiceButton(title: L("System"),
                                                 isActive: store.language == .system) {
                                store.dispatch(.setLanguage(.system))
                                applySettingsChange(store)
                            }
                            SettingsChoiceButton(title: "English",
                                                 isActive: store.language == .english) {
                                store.dispatch(.setLanguage(.english))
                                applySettingsChange(store)
                            }
                            SettingsChoiceButton(title: "简体中文",
                                                 isActive: store.language == .simplifiedChinese) {
                                store.dispatch(.setLanguage(.simplifiedChinese))
                                applySettingsChange(store)
                            }
                        }
                    }

                    SettingsSection(title: L("Selection")) {
                        Row(alignment: .center, spacing: 8) {
                            SettingsChoiceButton(title: L("Subtract"),
                                                 isActive: store.cmdSelectBehavior == .subtract) {
                                store.dispatch(.setCommandSelectBehavior(.subtract))
                                applySettingsChange(store)
                            }
                            SettingsChoiceButton(title: L("Toggle"),
                                                 isActive: store.cmdSelectBehavior == .toggle) {
                                store.dispatch(.setCommandSelectBehavior(.toggle))
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
        EditorRootViewFactory.saveShellState(mode: store.workspaceMode,
                                             preset: store.activeLayoutPreset,
                                             themeMode: store.themeMode,
                                             language: store.language,
                                             vsyncMode: store.vsyncMode,
                                             cmdSelectBehavior: store.cmdSelectBehavior)
    }

    private func applyVSyncMode(_ mode: EditorVSyncMode, store: EditorStore) {
        guard store.vsyncMode != mode else { return }
        store.dispatch(.setVSyncMode(mode))
        app.applyVSyncMode(mode)
        applySettingsChange(store)
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
