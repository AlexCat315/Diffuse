internal import EditorCore
internal import GuavaUI
internal import GuavaUIRuntime
internal import PluginRuntime

/// Draws a plugin's component tree with the editor's own controls. Controls
/// read and write their values through the session; actions go back to the
/// plugin as events.
struct PluginNodeRenderer: @unchecked Sendable {
    let session: PluginViewSession

    func render(_ node: UINode) -> AnyView {
        var view = content(node)
        if let flex = node.flex { view = AnyView(view.flex(Float(flex)).frame(minWidth: 0)) }
        if let key = node.key { view = AnyView(view.id(key)) }
        return view
    }

    private func content(_ node: UINode) -> AnyView {
        switch node.kind {
        case let .column(stack): stackView(stack, direction: .column)
        case let .row(stack): stackView(stack, direction: .row)
        case let .scroll(child):
            // Content fills the viewport's width, so flexible children such as table cells share it.
            AnyView(ScrollView(.vertical, scrollbarGutter: .stable) { render(child).frame(width: .percent(100), minWidth: 0) }
                .flex().frame(minWidth: 0, minHeight: 0))
        case let .section(title, children):
            AnyView(Column(alignment: .leading, spacing: 4) {
                if let title {
                    Text(title.uppercased(), lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted)
                }
                for child in children { render(child) }
            }.padding(vertical: 4).frame(minWidth: 0))
        case .spacer:
            AnyView(Spacer(minLength: 0))
        case let .text(text):
            AnyView(Text(text.text).font(Self.font(text.style)).foregroundColor(Self.color(text.tone)).frame(minWidth: 0))
        case let .badge(text, tone):
            AnyView(EditorPanelBadge(text, foreground: Self.color(tone)))
        case let .icon(name, tone):
            AnyView(Icon(Self.icon(name), size: 12, color: Self.color(tone)))
        case let .progress(percent):
            if let percent {
                AnyView(ProgressView(value: Double(percent) / 100).frame(minWidth: 0))
            } else {
                AnyView(Spinner(size: 12))
            }
        case let .button(button): buttonView(button)
        case let .textField(field): textFieldView(field)
        case let .toggle(toggle): toggleView(toggle)
        case let .select(select): selectView(select)
        case let .disclosure(disclosure): disclosureView(disclosure)
        case let .table(table): tableView(table)
        }
    }

    private func stackView(_ stack: UINode.Stack, direction: FlexDirection) -> AnyView {
        let align: Align = switch stack.align {
        case .start: .flexStart
        case .center: .center
        case .end: .flexEnd
        case .stretch: .stretch
        }
        return AnyView(Box(direction: direction, alignItems: align, spacing: Float(stack.spacing)) {
            for child in stack.children { render(child) }
        }.padding(Float(stack.padding)).frame(minWidth: 0))
    }

    // MARK: Controls

    private func buttonView(_ button: UINode.Button) -> AnyView {
        let action = { send(button.action, arguments: button.arguments) }
        guard let title = button.title else {
            return AnyView(Button(icon: .resource(Self.icon(button.icon ?? "")), size: 12, isEnabled: !button.disabled,
                                  tooltip: "", action: action)
                .buttonStyle(ToggleButtonStyle(height: 24)).debugName("plugin-button-" + button.action))
        }
        let label = Button(isEnabled: !button.disabled, tooltip: "", action: action) {
            Row(alignment: .center, spacing: 6) {
                if let icon = button.icon { Icon(Self.icon(icon), size: 12) }
                Text(title, lineLimit: 1)
            }
        }
        let styled: AnyView = switch button.style {
        case .primary: AnyView(label.buttonStyle(.primary))
        case .secondary: AnyView(label.buttonStyle(.secondary))
        case .ghost: AnyView(label.buttonStyle(.ghost))
        case .danger: AnyView(label.buttonStyle(.destructive))
        }
        return AnyView(styled.controlSize(.small).debugName("plugin-button-" + button.action))
    }

    private func textFieldView(_ field: UINode.TextField) -> AnyView {
        let session = session
        let text = Binding(get: { TextBuffer(session.values[field.id]?.stringValue ?? "") }, set: { value in
            MainActor.assumeIsolated { session.setValue(.string(value.stringValue), for: field.id, change: field.change) }
        })
        return AnyView(TextField(field.placeholder ?? "", text: text) { input in
            input.behavior.secure = field.secure
            if let submit = field.submit {
                input.events.onSubmit = { send(submit, value: session.values[field.id]) }
            }
        }.frame(minWidth: 0).debugName("plugin-field-" + field.id))
    }

    private func toggleView(_ toggle: UINode.Toggle) -> AnyView {
        let session = session
        let isOn = Binding(get: { session.values[toggle.id]?.boolValue ?? toggle.value }, set: { value in
            MainActor.assumeIsolated { session.setValue(.bool(value), for: toggle.id) }
            if let action = toggle.action { send(action, value: .bool(value)) }
        })
        return AnyView(Toggle(isOn: isOn, label: toggle.label).debugName("plugin-toggle-" + toggle.id))
    }

    private func selectView(_ select: UINode.Select) -> AnyView {
        let session = session
        let selection = Binding(get: { session.values[select.id]?.stringValue ?? select.value }, set: { value in
            MainActor.assumeIsolated { session.setValue(.string(value), for: select.id) }
            if let action = select.action { send(action, value: .string(value)) }
        })
        return AnyView(Select(selection: selection, options: select.options.map { .init(value: $0.value, label: $0.label) },
                              width: 200).frame(width: 200).debugName("plugin-select-" + select.id))
    }

    private func disclosureView(_ disclosure: UINode.Disclosure) -> AnyView {
        AnyView(Column(alignment: .leading, spacing: 2) {
            Button(action: { send(disclosure.action, arguments: disclosure.arguments) }) {
                Row(alignment: .center, spacing: 6) {
                    Icon(disclosure.expanded ? UIIcons.Navigation.chevronDown : UIIcons.Navigation.chevronRight,
                         size: 9, color: .onSurfaceMuted)
                    Text(disclosure.title, lineLimit: 1).font(.label).foregroundColor(.onSurface)
                    Spacer(minLength: 0)
                }.frame(width: .percent(100), height: .points(24))
            }.buttonStyle(.plain).frame(width: .percent(100)).debugName("plugin-disclosure-" + disclosure.action)
            if disclosure.expanded {
                Column(alignment: .leading, spacing: 2) {
                    for child in disclosure.children { render(child) }
                }.padding(EdgeInsets(leading: 15)).frame(width: .percent(100), minWidth: 0)
            }
        }.frame(minWidth: 0))
    }

    private func tableView(_ table: UINode.Table) -> AnyView {
        func cells(_ values: [String], header: Bool) -> AnyView {
            let font: SemanticFontRef = header ? .caption : .body
            let color: SemanticColorRef = header ? .onSurfaceMuted : .onSurface
            return AnyView(Row(alignment: .center, spacing: 8) {
                for value in values {
                    AnyView(Text(value, lineLimit: 1).truncated().font(font).foregroundColor(color)
                        .flex(1, shrink: 1, basis: 0).frame(minWidth: 0))
                }
            }.padding(horizontal: 8).frame(width: .percent(100), height: .points(24), minWidth: 0))
        }
        return AnyView(Column(alignment: .leading, spacing: 0) {
            cells(table.columns, header: true)
            for row in table.rows {
                if let action = row.action {
                    AnyView(Button(action: { send(action, arguments: row.arguments) }) { cells(row.cells, header: false) }
                        .buttonStyle(.plain).frame(width: .percent(100)).debugName("plugin-row"))
                } else {
                    AnyView(cells(row.cells, header: false).debugName("plugin-row"))
                }
            }
        }.frame(minWidth: 0))
    }

    private func send(_ action: String, arguments: PluginJSON? = nil, value: PluginJSON? = nil) {
        let session = session
        MainActor.assumeIsolated { session.send(action: action, arguments: arguments, value: value) }
    }

    // MARK: Style

    private static func font(_ style: UINode.TextStyle) -> SemanticFontRef {
        switch style {
        case .body: .body
        case .caption: .caption
        case .label: .label
        case .strong: .bodyStrong
        case .mono: .mono
        case .title: .title
        }
    }

    private static func color(_ tone: UINode.Tone) -> SemanticColorRef {
        switch tone {
        case .normal: .onSurface
        case .muted: .onSurfaceMuted
        case .accent: .accent
        case .success: .success
        case .warning: .warning
        case .danger: .error
        }
    }

    /// Plugins name the host's toolbar icons.
    private static func icon(_ name: String) -> BundleImageResource {
        .svg(named: name, in: EditorAppResourceBundle.bundle, subdirectory: "ToolbarIcons")
    }
}
