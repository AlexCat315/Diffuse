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

/// Searchable typed selection. Query, highlight and overlay state are transient and separate from the value.
public struct Combobox<Value: Hashable>: View {
    public let selection: Binding<Value?>
    public let options: [SelectOption<Value>]
    public var presentation = ComboboxPresentation()
    @State private var session = ComboboxSession<Value>()
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
        let matches = Self.matching(options, query: session.query.stringValue)
        let title = options.first { $0.value == selection.wrappedValue }?.label ?? presentation.placeholder
        Popover(isPresented: Binding(get: { session.isPresented }, set: { open in
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
            Row(alignment: .center, spacing: 8) {
                Text(title).lineLimit(1).font(.label).foregroundColor(selection.wrappedValue == nil ? .placeholder : .onSurface)
                Spacer()
                if presentation.isClearable, selection.wrappedValue != nil {
                    Button(icon: .resource(UICommonIcons.close), size: 12, isEnabled: presentation.isEnabled,
                           tooltip: "Clear selection") { selection.wrappedValue = nil }
                        .buttonStyle(.ghost).controlSize(.mini)
                }
                Icon(UICommonIcons.chevronDown, size: 10)
            }.padding(horizontal: 10).frame(height: 32).background(.surface).cornerRadius(6).border(.border, width: 1)
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
                    }), rowHeight: 32, onActivate: { if $0.isEnabled { choose($0.value) } }) { option, _ in
                        Row(alignment: .center, spacing: 8) {
                            Text(option.label).font(.label).foregroundColor(option.isEnabled ? .onSurface : .onSurfaceDisabled)
                            Spacer()
                            if option.value == selection.wrappedValue { Icon(UICommonIcons.checkmark, size: 12) }
                        }
                    }.frame(height: Float(min(presentation.maxVisibleRows, matches.count)) * 32).flex(0, shrink: 0)
                }
            }.padding(8).background(.surfaceFloating).cornerRadius(8).border(.border, width: 1)
        }).frame(width: presentation.width)
    }
    private func choose(_ value: Value) {
        guard presentation.isEnabled, options.contains(where: { $0.value == value && $0.isEnabled }) else { return }
        selection.wrappedValue = value
        session.isPresented = false
    }
}
