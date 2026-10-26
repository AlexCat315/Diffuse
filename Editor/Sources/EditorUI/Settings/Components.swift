internal import CoveUI
internal import CoveUIRuntime

struct SettingsBrandMark: View {
    var size: Float = 30

    var body: some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            Text("G").font(size > 30 ? .headline : .bodyStrong).foregroundColor(.onAccent)
        }.frame(width: size, height: size).background(.accent).cornerRadius(size * 0.26)
    }
}

struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let content: Content

    init(_ title: String, subtitle: String = "", @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.content = content()
    }

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 16) {
            Column(alignment: .leading, spacing: 4) {
                Text(title).font(.bodyStrong).foregroundColor(.onSurface)
                if !subtitle.isEmpty { Text(subtitle).font(.body).foregroundColor(.onSurfaceMuted) }
            }
            content
        }.padding(18).frame(width: .percent(100), minWidth: 0)
            .background(.surface).cornerRadius(10)
    }
}

struct SettingsField<Content: View>: View {
    let title: String
    let help: String
    let content: Content

    init(_ title: String, help: String, @ViewBuilder content: () -> Content) {
        self.title = title; self.help = help; self.content = content()
    }

    var body: some View {
        ContainerSizeReader { size in
            let leading = size.width >= 500
            Box(direction: leading ? .row : .column, alignItems: leading ? .center : .stretch, spacing: 14) {
                Column(alignment: .leading, spacing: 5) {
                    Text(title).font(.label).foregroundColor(.onSurface)
                    Text(help).font(.body).foregroundColor(.onSurfaceMuted)
                }.flex(leading ? 1 : 0, shrink: 1, basis: leading ? 0 : nil).frame(minWidth: 0)
                content.frame(minWidth: 0).flex(0, shrink: 1)
            }.frame(minWidth: 0)
        }
    }
}

struct SettingsChoiceStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let colors = configuration.theme.colors
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label).font(.label)
                .foregroundColor(configuration.isSelected ? colors.accent : colors.onSurfaceVariant)
        }.padding(horizontal: 12, vertical: 8).frame(minHeight: 32)
            .background(configuration.isSelected ? colors.accentMuted
                : configuration.isHovered ? colors.stateLayerHover : colors.surfaceSunken)
            .cornerRadius(6).border(configuration.isSelected ? colors.accent : colors.border, width: 1)
            .animation(motion: .fast, value: configuration.interactionKey)
    }
}
