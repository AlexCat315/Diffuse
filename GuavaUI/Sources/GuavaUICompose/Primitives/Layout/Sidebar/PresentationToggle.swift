/// The same affordance opens and collapses modal navigation at the leading edge.
struct SidebarToggle: View {
    let label: String
    let isExpanded: Bool
    let action: () -> Void
    var body: some View {
        Button(icon: .resource(UIIcons.Layout.panelLeft), tooltip: label, action: action)
            .buttonStyle(.ghost).frame(minWidth: 44, minHeight: 44)
            .accessibility { $0.label = label; $0.state.isExpanded = isExpanded }
            .flex(0, shrink: 0)
    }
}
