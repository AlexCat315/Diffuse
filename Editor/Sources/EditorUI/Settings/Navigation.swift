internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime
private import Foundation

struct SettingsSidebar: View {
    let app: EditorApplication
    let category: SettingsCategory
    let isSearching: Bool
    let onSelect: (SettingsCategory) -> Void

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Row(alignment: .center, spacing: 10) {
                SettingsBrandMark()
                Column(alignment: .leading, spacing: 2) {
                    Text("Guava Studio").font(.bodyStrong).foregroundColor(.onSurface)
                    Text(L("Settings")).font(.caption).foregroundColor(.onSurfaceMuted)
                }
            }.padding(horizontal: 18, vertical: 22)
            Text(L("WORKSPACE")).font(.caption).foregroundColor(.onSurfaceMuted)
                .padding(horizontal: 20, vertical: 8)
            for item in [SettingsCategory.general, .editor] { AnyView(destination(item)) }
            Text(L("TOOLS & ASSISTANT")).font(.caption).foregroundColor(.onSurfaceMuted)
                .padding(EdgeInsets(top: 24, leading: 20, bottom: 8, trailing: 20))
            for item in [SettingsCategory.agent, .plugins, .shortcuts] { AnyView(destination(item)) }
            Spacer(minLength: 24)
            destination(.about)
            Row(alignment: .center, spacing: 6) {
                Box {}.frame(width: 5, height: 5).background(.accent).cornerRadius(3)
                Text(URL(fileURLWithPath: app.projectDirectory).lastPathComponent, lineLimit: 1)
                    .font(.caption).foregroundColor(.onSurfaceVariant).flex().frame(minWidth: 0)
            }.padding(horizontal: 20, vertical: 12)
        }.frame(width: 212).debugName("settings-sidebar")
    }

    private func destination(_ item: SettingsCategory) -> some View {
        Button(isSelected: !isSearching && category == item, action: { onSelect(item) }) {
            Row(alignment: .center, spacing: 10) {
                Icon(item.icon, size: 16, color: item == .agent ? EditorThemeTokens.agentColor : .onSurfaceVariant)
                Text(item.title, lineLimit: 1).font(.label).flex().frame(minWidth: 0)
            }.padding(horizontal: 12, vertical: 11).frame(width: .percent(100), minWidth: 0)
        }.buttonStyle(SettingsNavigationStyle()).padding(horizontal: 10, vertical: 2)
            .accessibility { $0.label = item.title; $0.state.isSelected = !isSearching && category == item }
            .debugName("settings-category-" + item.rawValue)
    }
}

struct SettingsCategoryMenu: View {
    let category: SettingsCategory
    let onSelect: (SettingsCategory) -> Void
    @State private var isPresented = false

    var body: some View {
        Popover(isPresented: $isPresented, width: 220, surface: .content, overflow: .flip) {
            Row(alignment: .center, spacing: 4) {
                Icon(category.icon, size: 16, color: .onSurfaceVariant)
                Icon(UIIcons.Navigation.chevronDown, size: 9, color: .onSurfaceMuted)
            }.frame(width: 44, height: 32).background(.surfaceVariant).cornerRadius(6)
                .accessibility { $0.label = L("Settings categories"); $0.value = category.title }
        } content: {
            Menu(SettingsCategory.allCases.map { item in
                .item(MenuItem(id: item.rawValue, title: item.title, isSelected: item == category, action: {
                    onSelect(item); isPresented = false
                }))
            }, width: 220, onDismiss: { isPresented = false })
        }.debugName("settings-category-menu")
    }
}

private struct SettingsNavigationStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        AnyView(configuration.label)
            .foregroundColor(configuration.isSelected ? .onSurface : .onSurfaceVariant)
            .background(configuration.isSelected ? .surfaceVariant
                : configuration.isHovered ? .stateLayerHover : .clear)
            .cornerRadius(7).border(configuration.isFocused ? .focusRing : .clear, width: 1)
            .animation(motion: .fast, value: configuration.interactionKey)
    }
}
