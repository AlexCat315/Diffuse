import GuavaUIRuntime

/// A keyboard-focusable disclosure header with naturally sized content.
/// Expansion belongs to the caller, so it survives panel reconstruction and
/// can also be controlled by search or an Expand All command.
public struct DisclosureGroup<Label: View, Content: View>: View {
    public let isExpanded: Binding<Bool>
    public let isEnabled: Bool
    private let label: Label
    private let content: Content

    public init(isExpanded: Binding<Bool>,
                isEnabled: Bool = true,
                @ViewBuilder content: () -> Content,
                @ViewBuilder label: () -> Label) {
        self.isExpanded = isExpanded
        self.isEnabled = isEnabled
        self.label = label()
        self.content = content()
    }

    public var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 4) {
            Button(isEnabled: isEnabled, action: {
                isExpanded.wrappedValue.toggle()
            }) {
                Row(alignment: .center, spacing: 5) {
                    Icon(isExpanded.wrappedValue ? UICommonIcons.chevronDown : UICommonIcons.chevronRight,
                         size: 12, color: .onSurfaceVariant)
                    label.flex(1, shrink: 1, basis: 0)
                }
                .padding(horizontal: 2)
                .frame(height: 24, minWidth: 0)
                .flex(1, shrink: 1, basis: 0)
            }
            .buttonStyle(.ghost)
            .controlSize(.small)
            .frame(height: 24)
            .debugName("disclosure-header")

            if isExpanded.wrappedValue {
                content
            }
        }
        .frame(minWidth: 0)
    }
}

public extension DisclosureGroup where Label == AnyView {
    init(_ title: String,
         isExpanded: Binding<Bool>,
         isEnabled: Bool = true,
         @ViewBuilder content: () -> Content) {
        self.init(isExpanded: isExpanded, isEnabled: isEnabled, content: content) {
            AnyView(Text(title).lineLimit(1).font(.caption).foregroundColor(.onSurfaceVariant)
                .debugName("disclosure-label"))
        }
    }
}
