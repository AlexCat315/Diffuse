import Foundation
import GuavaUIRuntime

public struct ComboboxPresentation {
    public var placeholder = "Select an option"
    public var searchPlaceholder = "Search…"
    public var emptyText = "No matching options"
    public var width: Float = 280
    public var maxVisibleRows = 8
    public var isEnabled = true
    public var isClearable = true
    public init() {}
    mutating func validate() { width = max(120, width); maxVisibleRows = max(1, maxVisibleRows) }
}

private struct ComboboxSession<Value: Hashable> {
    var isPresented = false
    var query = TextBuffer.empty
    var highlighted: Value?
    var focusRequest = 0
}

private struct ComboboxRowMetrics {
    let authoredHeight: Float
    let displayedHeight: Float
    let triggerMinimum: Float
    init(theme: Theme, scaler: TextScaler, surface: UIEnvironment) {
        authoredHeight = max(32, theme.typography.label.lineHeight + 12)
        displayedHeight = max(scaler.scale(authoredHeight), surface.input.contains(.touch) ? surface.minimumControlExtent : 0)
        triggerMinimum = max(32, scaler.scale(theme.typography.label.lineHeight) + 12)
    }
}

/// Searchable typed selection. Query, highlight and overlay state are transient and separate from the value.
public struct Combobox<Value: Hashable>: View {
    public let selection: Binding<Value?>
    public let options: [SelectOption<Value>]
    public var presentation = ComboboxPresentation()
    @State private var session = ComboboxSession<Value>()
    @State private var chromeWidth: Float = 0
    public init(selection: Binding<Value?>, options: [SelectOption<Value>],
                configure: (inout ComboboxPresentation) -> Void = { _ in }) {
        self.selection = selection; self.options = options
        configure(&presentation); presentation.validate()
        precondition(Set(options.map(\.value)).count == options.count, "Combobox values must be unique")
    }
    public static func matching(_ options: [SelectOption<Value>], query: String) -> [SelectOption<Value>] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return options.filter { option in terms.allSatisfy { option.label.localizedCaseInsensitiveContains($0) } }
    }
    public var body: some View {
        ThemeReader { theme in
            SurfaceReader { surface in
                TextScalerReader { scaler in
                    content(rows: ComboboxRowMetrics(theme: theme, scaler: scaler, surface: surface))
                }
            }
        }
    }
    private func content(rows: ComboboxRowMetrics) -> some View {
        let matches = Self.matching(options, query: session.query.stringValue)
        let selectedLabel = options.first { $0.value == selection.wrappedValue }?.label
        let title = selectedLabel ?? presentation.placeholder
        var popover = Popover(isPresented: Binding(get: { session.isPresented }, set: { open in
            if open && !session.isPresented {
                session.query = ""; session.highlighted = selection.wrappedValue; session.focusRequest += 1
            }
            session.isPresented = open
        }), isEnabled: presentation.isEnabled, width: presentation.width, onKey: { event, phase in
            guard phase != .capture else { return .ignored }
            let enabled = matches.filter(\.isEnabled).map(\.value)
            if let command = SelectionNavigation.command(for: event.scancode) {
                session.highlighted = command.destination(in: enabled, from: session.highlighted)
                return .handled
            }
            if event.scancode == Scancode.return || event.scancode == Scancode.keypadEnter {
                if let value = session.highlighted, enabled.contains(value) { choose(value) }
                else if let first = enabled.first { choose(first) }
                return .handled
            }
            return .ignored
        }, label: {
            InlineLabelLayout(spacing: 8, onMinimumWidth: { width in
                if chromeWidth != Float(width) { chromeWidth = Float(width) }
            }) {
                Box {}
                Text(title).truncatingTail().font(.label).foregroundColor(selectedLabel == nil ? .placeholder : .onSurface)
                    .accessibilityHidden()
                Row(alignment: .center, spacing: 8) {
                if presentation.isClearable, selection.wrappedValue != nil {
                    Button(icon: .resource(UIIcons.Action.x), size: 12, isEnabled: presentation.isEnabled,
                           tooltip: "Clear selection") { selection.wrappedValue = nil }
                        .buttonStyle(.ghost).controlSize(.mini).accessibilityLabel("Clear selection")
                }
                Icon(UIIcons.Navigation.chevronDown, size: .small).accessibilityHidden()
                }
            }.padding(horizontal: 10, vertical: 4).frame(minHeight: rows.triggerMinimum).background(.surface).cornerRadius(.inputRadius).border(.border, width: 1)
        }, content: {
            Box(direction: .column, alignItems: .stretch, spacing: 6) {
                TextField(presentation.searchPlaceholder, text: Binding(get: { session.query }, set: { query in
                    session.query = query
                    session.highlighted = Self.matching(options, query: query.stringValue).first(where: \.isEnabled)?.value
                })) { input in
                    input.behavior.clearable = true
                    input.navigation.focusRequestID = session.focusRequest
                    input.events.onSubmit = {
                        if let value = session.highlighted, matches.contains(where: { $0.value == value && $0.isEnabled }) { choose(value) }
                        else if let first = matches.first(where: \.isEnabled) { choose(first.value) }
                    }
                    input.events.onKeyDown = { event in
                        guard [Scancode.arrowUp, Scancode.arrowDown].contains(event.scancode),
                              let command = SelectionNavigation.command(for: event.scancode) else { return false }
                        session.highlighted = command.destination(in: matches.filter(\.isEnabled).map(\.value), from: session.highlighted)
                        return true
                    }
                }
                if matches.isEmpty { Text(presentation.emptyText).font(.caption).foregroundColor(.onSurfaceMuted).padding(12) }
                else {
                    List(matches, id: \.value, selection: Binding(get: { session.highlighted }, set: { value in
                        session.highlighted = value
                    }), rowHeight: rows.authoredHeight, onActivate: { if $0.isEnabled { choose($0.value) } }) { option, _ in
                        Row(alignment: .center, spacing: 8) {
                            Text(option.label).truncated().font(.label).foregroundColor(option.isEnabled ? .onSurface : .onSurfaceDisabled)
                                .flex(1, shrink: 1).frame(minWidth: 0)
                            if option.value == selection.wrappedValue { Icon(UIIcons.Action.check, size: .small).flex(0, shrink: 0) }
                        }
                    }.frame(height: Float(min(presentation.maxVisibleRows, matches.count)) * rows.displayedHeight).flex(0, shrink: 0)
                }
            }.padding(8).glassSurface(.controlRadius)
        })
        popover.sizing = .anchor
        popover.triggerDescription = .init(label: title, value: selectedLabel ?? "", help: title)
        return popover.frame(width: presentation.width, minWidth: max(44, chromeWidth + 26))
    }
    private func choose(_ value: Value) {
        guard presentation.isEnabled, options.contains(where: { $0.value == value && $0.isEnabled }) else { return }
        selection.wrappedValue = value
        session.isPresented = false
    }
}
