import CoveUI
import CoveUIRuntime

/// Menu affordances are explicit and remain stable when the value changes.
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
                Icon(UIIcons.Navigation.chevronDown,size: 9,color: .onSurfaceMuted)
            }
        }
        .padding(horizontal: label == nil ? 7 : 10)
        .frame(height: 28)
        .background(isActive ? SemanticColorRef.accentMuted : isHovered ? .stateLayerHover : .clear)
        .cornerRadius(7)
        .onHover { isHovered = $0 }
    }
}
