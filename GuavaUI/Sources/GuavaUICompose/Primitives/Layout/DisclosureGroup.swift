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
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            Button(isEnabled: isEnabled, action: {
                isExpanded.wrappedValue.toggle()
            }) {
                Row(alignment: .center, spacing: 5) {
                    Icon(isExpanded.wrappedValue ? UIIcons.Navigation.chevronDown : UIIcons.Navigation.chevronRight,
                         size: .small, color: .onSurfaceVariant).accessibilityHidden()
                    label.flex(1, shrink: 1)
                }
                .padding(horizontal: 2)
                .frame(minWidth: 0)
                .flex(1, shrink: 1)
            }
            .compositionLocal(ActionControlAccessibility.isExpanded, isExpanded.wrappedValue)
            .buttonStyle(.ghost)
            .controlSize(.small)
            .debugName("disclosure-header")

            AnimatedVisibility(isVisible: isExpanded.wrappedValue) {
                content.padding(EdgeInsets(top: 6))
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
            AnyView(Text(title).font(.label).foregroundColor(.onSurfaceVariant)
                .debugName("disclosure-label"))
        }
    }
}
