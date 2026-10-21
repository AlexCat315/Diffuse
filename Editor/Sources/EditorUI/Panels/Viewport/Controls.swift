import GuavaUI
import GuavaUIRuntime

/// The viewport header's one control vocabulary: ghost icon buttons, icon
/// menu triggers and a segmented tool switcher. None of them draws its own box
/// at rest; hover and "on" use the same rounded tint everywhere.
struct ViewportIconButtonStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let colors = configuration.theme.colors
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
                .foregroundColor(!configuration.isEnabled ? colors.onSurfaceMuted
                    : configuration.isSelected ? colors.accent : colors.onSurfaceVariant)
        }
        .frame(width: 28, height: 28)
        .background(configuration.isSelected ? colors.accentMuted
            : configuration.isPressed ? colors.stateLayerPressed
            : configuration.isHovered ? colors.stateLayerHover : .clear)
        .cornerRadius(7)
        .border(configuration.isFocused ? colors.focusRing : .clear, width: 1)
        .animation(motion: .fast, value: configuration.interactionKey)
    }
}

/// The face of a viewport menu: what the menu holds now, as a word ("透视",
/// "光照") or an icon. No chevron: like the other header controls it answers
/// the pointer with the shared rounded tint, and `isActive` tints it when the
/// setting departs from the default.
struct ViewportMenuTrigger: View {
    var icon: BundleImageResource?
    var label: String?
    var isActive = false
    @State private var isHovered = false

    var body: some View {
        Row(alignment: .center, spacing: 6) {
            if let icon { Icon(icon, size: 14, color: isActive ? .accent : .onSurfaceVariant) }
            if let label {
                Text(label, lineLimit: 1).font(.label).foregroundColor(isActive ? .accent : .onSurface)
            }
        }
        .padding(horizontal: label == nil ? 7 : 10)
        .frame(height: 28)
        .background(isActive ? SemanticColorRef.accentMuted : isHovered ? .stateLayerHover : .clear)
        .cornerRadius(7)
        .onHover { isHovered = $0 }
        .animation(motion: .fast, value: isHovered)
    }
}

/// Mutually exclusive tools in one sunken track; the current one is raised.
struct ViewportSegmentStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let colors = configuration.theme.colors
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            AnyView(configuration.label)
                .foregroundColor(!configuration.isEnabled ? colors.onSurfaceMuted
                    : configuration.isSelected ? colors.onSurface : colors.onSurfaceVariant)
        }
        .frame(width: 28, height: 24)
        .background(configuration.isSelected ? colors.surfaceVariant
            : configuration.isHovered ? colors.stateLayerHover : .clear)
        .cornerRadius(6)
        .border(configuration.isFocused ? colors.focusRing : .clear, width: 1)
        .animation(motion: .fast, value: configuration.interactionKey)
    }
}
