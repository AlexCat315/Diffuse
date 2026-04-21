import GuavaUIRuntime

/// Tree row default: depth-indented row with a chevron disclosure slot and
/// the same selection / hover treatment as `DefaultListRowStyle`. The
/// disclosure glyph is rendered as a `Text` chevron; Step 8 will swap it for
/// `Image(systemName:)` once that asset pipeline lands.
public struct DefaultTreeRowStyle: TreeRowStyle {
    public init() {}

    public func makeBody(configuration: TreeRowStyleConfiguration) -> some View {
        let t = configuration.theme
        let clear = Color(r: 0, g: 0, b: 0, a: 0)
        let bg: Color = {
            if configuration.isSelected { return t.colors.selection }
            if configuration.isHovered  { return t.colors.selection.mixed(with: t.colors.surface, amount: 0.7) }
            return clear
        }()

        let chevron: String = {
            guard configuration.hasChildren else { return "" }
            return configuration.isExpanded ? "▾" : "▸"
        }()

        return Row(alignment: .center, spacing: 0) {
            // Indent gutter.
            Box { EmptyView() }
                .frame(width: Float(configuration.depth) * configuration.indentation)

            // Disclosure slot — always reserved so siblings align even when a
            // node has no children.
            Box(direction: .row, alignItems: .center, justifyContent: .center) {
                Text(chevron)
                    .foregroundColor(SemanticColorRef.onSurfaceMuted)
            }
            .frame(width: configuration.disclosureWidth)

            // Row content.
            Row(alignment: .center, spacing: t.spacing.sm) {
                configuration.content
                Spacer(minLength: 0)
            }
            .flex()
            .padding(horizontal: t.spacing.sm, vertical: t.spacing.sm)
        }
        .background(bg)
        .cornerRadius(t.radius.sm)
        .opacity(configuration.isEnabled ? 1 : 0.55)
    }
}
