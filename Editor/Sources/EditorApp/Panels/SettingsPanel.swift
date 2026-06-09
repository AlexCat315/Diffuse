import EditorCore
import GuavaKit

struct SettingsPanel: GuavaKit.View {
    @Observed var store: EditorStore
    let app: EditorApplication

    init(app: EditorApplication) {
        self.app = app
        self.store = app.store
    }

    var body: some GuavaKit.View {
        ScrollView(.column) {
            Column(alignment: .stretch, spacing: 14) {
                SettingsSection(title: L("Appearance")) {
                    Row(alignment: .center, spacing: 8) {
                        SettingsChoiceButton(title: L("Dark"),
                                             isActive: store.themeMode == .dark) {
                            store.dispatch(.setThemeMode(.dark))
                            applySettingsChange()
                        }
                        SettingsChoiceButton(title: L("Light"),
                                             isActive: store.themeMode == .light) {
                            store.dispatch(.setThemeMode(.light))
                            applySettingsChange()
                        }
                    }
                }

                SettingsSection(title: L("Vertical Sync")) {
                    Row(alignment: .center, spacing: 10) {
                        Toggle(isOn: store.vsyncMode.isEnabled) { enabled in
                            let mode: EditorVSyncMode = enabled ? .enabled : .disabled
                            guard store.vsyncMode != mode else { return }
                            store.dispatch(.setVSyncMode(mode))
                            app.applyVSyncMode(mode)
                            applySettingsChange()
                        }

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
                            applySettingsChange()
                        }
                        SettingsChoiceButton(title: "English",
                                             isActive: store.language == .english) {
                            store.dispatch(.setLanguage(.english))
                            applySettingsChange()
                        }
                        SettingsChoiceButton(title: "简体中文",
                                             isActive: store.language == .simplifiedChinese) {
                            store.dispatch(.setLanguage(.simplifiedChinese))
                            applySettingsChange()
                        }
                    }
                }

                SettingsSection(title: L("Selection")) {
                    Row(alignment: .center, spacing: 8) {
                        SettingsChoiceButton(title: L("Subtract"),
                                             isActive: store.primarySelectBehavior == .subtract) {
                            store.dispatch(.setPrimarySelectBehavior(.subtract))
                            applySettingsChange()
                        }
                        SettingsChoiceButton(title: L("Toggle"),
                                             isActive: store.primarySelectBehavior == .toggle) {
                            store.dispatch(.setPrimarySelectBehavior(.toggle))
                            applySettingsChange()
                        }
                    }
                }

                SettingsSection(title: L("Capability Gate")) {
                    Row(alignment: .center, spacing: 8) {
                        for phase in EditorCapabilityReleasePhase.allCases {
                            SettingsChoiceButton(title: L(phase.displayName),
                                                 isActive: store.capabilitySettings.releasePhase == phase) {
                                applyCapabilityReleasePhase(phase)
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .flex(1, shrink: 1)
        .frame(minWidth: 220)
    }

    private func applySettingsChange() {
        persistShell()
        app.requestDisplayRefresh()
    }

    private func persistShell() {
        EditorRootViewFactory.saveShellState(mode: store.workspaceMode,
                                             preset: store.activeLayoutPreset,
                                             themeMode: store.themeMode,
                                             language: store.language,
                                             vsyncMode: store.vsyncMode,
                                             primarySelectBehavior: store.primarySelectBehavior,
                                             aiSettings: store.aiSettings,
                                             capabilitySettings: store.capabilitySettings)
    }

    private func applyCapabilityReleasePhase(_ phase: EditorCapabilityReleasePhase) {
        guard store.capabilitySettings.releasePhase != phase else { return }
        app.applyCapabilitySettings(EditorCapabilitySettings(releasePhase: phase))
        applySettingsChange()
    }
}

private struct SettingsSection<Content: GuavaKit.View>: GuavaKit.View {
    let title: String
    let content: Content

    init(title: String, @GuavaKit.ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some GuavaKit.View {
        Column(alignment: .stretch, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)

            content
        }
    }
}

private struct SettingsChoiceButton: GuavaKit.View {
    let title: String
    let isActive: Bool
    let onClick: () -> Void

    var body: some GuavaKit.View {
        Button(action: onClick) {
            Row(alignment: .center, spacing: 0) {
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
    }
}
