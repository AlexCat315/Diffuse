internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime

struct AppearanceSettings: View {
    let app: EditorApplication
    let onChange: () -> Void

    var body: some View {
        SettingsCard(L("Appearance"), subtitle: L("A calm canvas, in your preferred light.")) {
            Row(alignment: .center, spacing: 12) {
                Text(L("Theme")).font(.bodyStrong).flex()
                Select(selection: Binding(get: { app.store.presentation.themeID }, set: {
                    app.store.dispatch(.setThemeID($0)); onChange()
                }), options: app.themeCatalog.themes.map {
                    .init(value: $0.id, label: $0.title)
                }, width: 200).frame(width: 200).debugName("settings-theme")
            }
            Row(alignment: .top, spacing: 12) {
                themeChoice(.dark, title: L("Dark"), dark: true)
                themeChoice(.light, title: L("Light Theme"), dark: false)
            }
        }
    }

    private func themeChoice(_ mode: EditorThemeMode, title: String, dark: Bool) -> some View {
        let selected = app.store.themeMode == mode
        let palette = app.resolvedTheme(dark: dark).colors
        return Button(isSelected: selected, action: {
            guard app.store.themeMode != mode else { return }
            app.store.dispatch(.setThemeMode(mode)); onChange()
        }) {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                Column(alignment: .leading, spacing: 8) {
                    Row(alignment: .center, spacing: 4) {
                        for _ in 0..<3 { AnyView(Box {}.frame(width: 4, height: 4).background(palette.onSurfaceMuted).cornerRadius(2)) }
                        Spacer(minLength: 0)
                    }.padding(8).frame(width: .percent(100)).background(palette.surfaceRaised)
                    Row(alignment: .top, spacing: 8) {
                        Box {}.frame(width: 24, height: 34).background(palette.surfaceRaised).cornerRadius(3)
                        Column(alignment: .leading, spacing: 6) {
                            Box {}.frame(width: .percent(65), height: .points(5)).background(palette.accent).cornerRadius(2)
                            Box {}.frame(width: .percent(85), height: .points(4)).background(palette.onSurfaceMuted.multipliedAlpha(0.25)).cornerRadius(2)
                            Box {}.frame(width: 44, height: 4).background(palette.surfaceVariant).cornerRadius(2)
                        }.flex()
                    }.padding(horizontal: 10).padding(EdgeInsets(bottom: 10)).frame(width: .percent(100))
                }.frame(width: .percent(100)).background(palette.background)
                Row(alignment: .center, spacing: 8) {
                    Text(title).font(.label).foregroundColor(.onSurface).flex()
                    Icon(selected ? UIIcons.Action.check : UIIcons.Device.sun, size: 13,
                         color: selected ? .accent : .onSurfaceMuted)
                }.padding(horizontal: 12, vertical: 11).background(.surfaceRaised)
            }.padding(2).frame(width: .percent(100), minWidth: 0).background(.surfaceSunken).cornerRadius(8)
                .border(selected ? .accent : .divider, width: selected ? 2 : 1)
        }.buttonStyle(.plain).flex(1, shrink: 1, basis: 0).frame(minWidth: 0)
            .accessibility { $0.label = title; $0.state.isSelected = selected }
            .debugName("settings-theme-" + (dark ? "dark" : "light"))
    }
}

struct LanguageSettings: View {
    let app: EditorApplication
    let onChange: () -> Void

    var body: some View {
        SettingsCard(L("Language")) {
            SettingsField(L("Display language"), help: L("Menus and interface text update immediately.")) {
                Select(selection: Binding(get: { app.store.language }, set: {
                    app.store.dispatch(.setLanguage($0)); onChange()
                }), options: [
                    .init(value: .system, label: L("System")),
                    .init(value: .english, label: "English"),
                    .init(value: .simplifiedChinese, label: "简体中文"),
                ], width: 200).frame(width: 200).debugName("settings-language")
            }
        }
    }
}

struct SelectionSettings: View {
    let app: EditorApplication
    let onChange: () -> Void

    var body: some View {
        SettingsCard(L("Selection")) {
            SettingsField(L("Primary modifier + click"), help: L("Choose how Command / Control-click changes an existing selection.")) {
                Row(alignment: .center, spacing: 6) {
                    choice(.subtract, title: L("Subtract"))
                    choice(.toggle, title: L("Toggle"))
                }
            }
        }
    }

    private func choice(_ value: SelectionPrimaryModifierBehavior, title: String) -> some View {
        Button(title, isSelected: app.store.primarySelectBehavior == value) {
            app.store.dispatch(.setPrimarySelectBehavior(value)); onChange()
        }.buttonStyle(SettingsChoiceStyle()).debugName("settings-selection-" + (value == .subtract ? "subtract" : "toggle"))
    }
}

struct DisplaySettings: View {
    let app: EditorApplication
    let onChange: () -> Void

    var body: some View {
        SettingsCard(L("Display & Performance")) {
            SettingsField(L("Vertical Sync"), help: L("Synchronize presentation with the display to reduce tearing.")) {
                Toggle(isOn: Binding(get: { app.store.vsyncMode.isEnabled }, set: { enabled in
                    let mode: EditorVSyncMode = enabled ? .enabled : .disabled
                    guard app.store.vsyncMode != mode else { return }
                    app.store.dispatch(.setVSyncMode(mode)); app.applyVSyncMode(mode); onChange()
                })).accessibility { $0.label = L("Vertical Sync") }.debugName("settings-vsync")
            }
        }
    }
}

struct SwiftSettings: View {
    @State private var preferences = SwiftEditingPreferences.load()

    var body: some View {
        SettingsCard(L("Swift")) {
            SettingsField(L("Format on Save"), help: L("Format Swift files through the language service when they are saved.")) {
                Toggle(isOn: Binding(get: { preferences.formatsOnSave }, set: { enabled in
                    preferences.formatsOnSave = enabled
                    try? preferences.save()
                })).accessibility { $0.label = L("Format on Save") }.debugName("settings-swift-format-on-save")
            }
        }
    }
}
