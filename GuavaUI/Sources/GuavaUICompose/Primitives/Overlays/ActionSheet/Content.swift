internal import Foundation
internal import GuavaUIRuntime

struct ActionSheetContent: View {
    let question: ActionSheetQuestion
    let isPresented: Binding<Bool>
    let maximumHeight: Float
    let showsHandle: Bool
    let onTranslation: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void
    @State private var highlighted: String?

    var body: some View {
        let enabled = question.actions.filter(\.isEnabled).map { AnyHashable($0.id) }
        let current = highlighted.map(AnyHashable.init).flatMap { enabled.contains($0) ? $0 : nil } ?? enabled.first
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            if showsHandle {
                SheetDragHandle(onTranslation: onTranslation, onEnd: onEnd)
                    .accessibilityHidden()
                    .debugName("action-sheet-handle")
            }
            header
            Divider()
            ScrollView(.vertical, scrollbarGutter: .overlay) {
                RovingFocusHost(enabledItems: enabled, selection: { current },
                    onSelect: { highlighted = $0.base as? String },
                    command: { event in
                        [Scancode.arrowUp, Scancode.arrowDown, Scancode.home, Scancode.end].contains(event.scancode)
                            ? SelectionNavigation.command(for: event.scancode) : nil
                    }) {
                    Box(direction: .column, alignItems: .stretch, spacing: 0) {
                        for (index, item) in question.actions.enumerated() {
                            AnyView(action(item).id(item.id).modifier(RovingItemModifier(id: item.id,
                                isTabStop: current == AnyHashable(item.id))))
                            if index < question.actions.count - 1 {
                                AnyView(Divider().debugName("action-sheet-separator-\(index)"))
                            }
                        }
                    }.padding(vertical: 4)
                }
            }.frame(maxHeight: maximumHeight)
        }
        .frame(minWidth: 0)
        .debugName("action-sheet-content")
        .overlay(alignment: .topTrailing) {
            if !showsHandle {
                closeButton.padding(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 12))
            }
        }
        .accessibility { $0.role = .dialog; $0.label = question.title; $0.help = question.message }
    }

    private var header: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 6) {
            Text(question.title).font(.bodyStrong).accessibility { $0.role = .heading }
            if !question.message.isEmpty {
                Text(question.message).font(.caption).foregroundColor(.onSurfaceMuted)
            }
        }
        .padding(EdgeInsets(top: 8, leading: 12, bottom: 10, trailing: showsHandle ? 12 : 52))
        .frame(minHeight: 44)
    }

    private var closeButton: some View {
        Button(icon: .resource(UIIcons.Action.x), size: 14, tooltip: question.closeLabel) {
            isPresented.wrappedValue = false
        }
        .buttonStyle(.ghost)
        .frame(width: 44, height: 44)
        .compositionLocal(ActionControlAccessibility.label, question.closeLabel)
        .debugName("action-sheet-close")
    }

    private func action(_ item: ActionSheetAction) -> some View {
        let color: SemanticColorRef = !item.isEnabled ? .onSurfaceDisabled : item.role == .destructive ? .error : .onSurface
        return Button(role: item.role, isEnabled: item.isEnabled, action: {
            guard isPresented.wrappedValue && item.isEnabled else { return }
            isPresented.wrappedValue = false
            item.action()
        }) {
            Box(direction: .row, alignItems: .center, spacing: 10) {
                if let icon = item.icon { Icon(icon, size: .small, color: color).accessibilityHidden() }
                Text(item.title).foregroundColor(color).frame(minWidth: 0).flex(1, shrink: 1, basis: 0)
            }.frame(minWidth: 0)
        }.buttonStyle(ActionSheetRowStyle())
            .compositionLocal(ActionControlAccessibility.label, item.title)
    }
}

private struct ActionSheetRowStyle: ButtonStyle {
    func makeBody(configuration: ButtonStyleConfiguration) -> some View {
        let theme = configuration.theme
        let clear = Color(r: 0, g: 0, b: 0, a: 0)
        let fill: Color = configuration.isPressed ? theme.colors.stateLayerPressed
            : (configuration.isHovered || configuration.isFocused) ? theme.colors.stateLayerHover
            : clear
        return Box(direction: .column, alignItems: .stretch) { AnyView(configuration.label) }
            .padding(horizontal: 12, vertical: 10)
            .frame(width: .percent(100), minWidth: 0, minHeight: 44)
            .background(fill)
            .cornerRadius(theme.radius.sm)
            .animation(.semantic(.fast, in: theme), value: configuration.interactionKey)
    }
}
