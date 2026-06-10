import EditorCore
import GuavaUICompose
import GuavaUIRuntime

/// Editor settings panel: captioned sections of pill choice buttons.
struct SettingsPanel: View {
    let store: EditorStore
    let app: EditorApplication

    init(app: EditorApplication) {
        self.app = app
        self.store = app.store
    }

    var body: some View {
        ScrollView(.vertical) {
            Column(alignment: .leading, spacing: 14) {
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
                        Toggle(isOn: Binding(
                            get: { store.vsyncMode.isEnabled },
                            set: { enabled in
                                let mode: EditorVSyncMode = enabled ? .enabled : .disabled
                                guard store.vsyncMode != mode else { return }
                                store.dispatch(.setVSyncMode(mode))
                                app.applyVSyncMode(mode)
                                applySettingsChange()
                            }
                        ))

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
            .padding(horizontal: 12, vertical: 12)
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

private struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Column(alignment: .leading, spacing: 8) {
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
            Row(alignment: .center, spacing: 0) {
                Text(title)
                    .lineLimit(1)
                    .font(.label)
                    .foregroundColor(isActive ? .accent : .onSurface)
            }
            .frame(height: 28, minWidth: 86)
            .padding(horizontal: 10, vertical: 0)
            .background(isActive ? SemanticColorRef.accentMuted : .surfaceSunken)
            .cornerRadius(7)
            .border(isActive ? SemanticColorRef.accent : .border, width: 1)
            .clipped()
        }
        .buttonStyle(PlainButtonStyle())
    }
}
