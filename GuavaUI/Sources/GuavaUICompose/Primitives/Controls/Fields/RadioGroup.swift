import GuavaUIRuntime

public struct RadioOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: String
    public var detail = ""
    public var isEnabled = true
    public var id: Value { value }
    public init(_ value: Value, _ title: String, configure: (inout Self) -> Void = { _ in }) {
        self.value = value; self.title = title; configure(&self)
    }
}

/// Controlled selection with one Tab stop and wrapping arrow-key navigation.
public struct RadioGroup<Value: Hashable>: View {
    public let selection: Binding<Value?>
    public let options: [RadioOption<Value>]
    public var isEnabled = true
    public var isHorizontal = false
    public init(selection: Binding<Value?>, options: [RadioOption<Value>], configure: (inout Self) -> Void = { _ in }) {
        self.selection = selection; self.options = options; configure(&self)
        precondition(Set(options.map(\.value)).count == options.count, "Radio option values must be unique")
    }
    public var body: some View {
        let enabled = options.filter { isEnabled && $0.isEnabled }.map(\.value)
        let tabStop = selection.wrappedValue.flatMap { enabled.contains($0) ? $0 : nil } ?? enabled.first
        RovingFocusHost(enabledItems: enabled.map { AnyHashable($0) }, selection: { selection.wrappedValue.map { AnyHashable($0) } },
                        onSelect: { if let value = $0.base as? Value { selection.wrappedValue = value } }) {
            Box(direction: isHorizontal ? .row : .column, alignItems: isHorizontal ? .center : .stretch, spacing: 8) {
                for option in options {
                    AnyView(Button(isEnabled: isEnabled && option.isEnabled, isSelected: selection.wrappedValue == option.value,
                                   action: { selection.wrappedValue = option.value }) {
                        Row(alignment: .center, spacing: 9) {
                            RadioMark(isSelected: selection.wrappedValue == option.value, isEnabled: isEnabled && option.isEnabled)
                            Column(alignment: .leading, spacing: 3) {
                                Text(option.title).font(.label)
                                if !option.detail.isEmpty { Text(option.detail).font(.caption).foregroundColor(.onSurfaceMuted) }
                            }
                        }
                    }.accessibility { $0.role = .radio; $0.label = option.title; $0.help = option.detail }.buttonStyle(RadioItemStyle()).modifier(RovingItemModifier(id: AnyHashable(option.value), isTabStop: option.value == tabStop)))
                }
            }
        }
    }
}

private struct RadioItemStyle: ButtonStyle {
    func makeBody(configuration c: ButtonStyleConfiguration) -> some View {
        Row(alignment: .center) { AnyView(c.label) }
            .flex(1, shrink: 1).padding(7)
            .foregroundColor(c.isEnabled ? .onSurface : .onSurfaceDisabled)
            .background(c.isHovered ? c.theme.colors.stateLayerHover : .clear)
            .cornerRadius(6).border(c.isFocused ? c.theme.colors.focusRing : .clear, width: c.isFocused ? 2 : 0)
    }
}

private struct RadioMark: _PrimitiveView {
    let isSelected: Bool
    let isEnabled: Bool
    func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    func _makeLayoutNode() -> LayoutNode? { let layout = LayoutNode(); layout.width = 18; layout.height = 18; return layout }
    func _updateNode(_ node: Node) {
        node.draw = { [weak node] list, origin in
            guard let node else { return }
            let color = (isEnabled ? isSelected ? node.theme.colors.accent : node.theme.colors.onSurfaceMuted : SemanticColorRef.onSurfaceDisabled.resolve(node.theme)).multipliedAlpha(node.opacity)
            let x = Float(origin.x), y = Float(origin.y)
            list.addRoundedRect(UIRect(x: x, y: y, width: 18, height: 18), radius: 9, color: color)
            list.addRoundedRect(UIRect(x: x + 1.5, y: y + 1.5, width: 15, height: 15), radius: 7.5, color: node.theme.colors.surface)
            if isSelected { list.addRoundedRect(UIRect(x: x + 5, y: y + 5, width: 8, height: 8), radius: 4, color: color) }
        }
    }
}
