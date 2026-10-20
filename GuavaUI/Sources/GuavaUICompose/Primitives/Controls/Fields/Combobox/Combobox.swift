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
    /// The last committed option, so a remote selection keeps its label after results change.
    var chosen: SelectOption<Value>?
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
/// Options are either a fixed list filtered locally, or a `ComboboxSearch`
/// whose results the component requests, debounces and cancels.
public struct Combobox<Value: Hashable>: View {
    public let selection: Binding<Value?>
    public var presentation = ComboboxPresentation()
    private let source: Source
    @State private var session = ComboboxSession<Value>()
    @State private var remote = ComboboxSearchSession<Value>()
    @State private var chromeWidth: Float = 0

    private enum Source {
        case options([SelectOption<Value>])
        case search(ComboboxSearch<Value>, selectedLabel: String?)
    }

    public init(selection: Binding<Value?>, options: [SelectOption<Value>],
                configure: (inout ComboboxPresentation) -> Void = { _ in }) {
        self.selection = selection; self.source = .options(options)
        configure(&presentation); presentation.validate()
        precondition(Set(options.map(\.value)).count == options.count, "Combobox values must be unique")
    }

    /// Remote options. `selectedLabel` names the current value while it is
    /// not among the loaded results (for example before the first search).
    public init(selection: Binding<Value?>, selectedLabel: String? = nil, search: ComboboxSearch<Value>,
                configure: (inout ComboboxPresentation) -> Void = { _ in }) {
        self.selection = selection; self.source = .search(search, selectedLabel: selectedLabel)
        configure(&presentation); presentation.validate()
    }
    public static func matching(_ options: [SelectOption<Value>], query: String) -> [SelectOption<Value>] {
        let terms = query.split(whereSeparator: \.isWhitespace)
        return options.filter { option in terms.allSatisfy { option.label.localizedCaseInsensitiveContains($0) } }
    }
    public var body: some View {
        let loaded = loadedResults
        return ThemeReader { theme in
            SurfaceReader { surface in
                TextScalerReader { scaler in
                    content(rows: ComboboxRowMetrics(theme: theme, scaler: scaler, surface: surface), loaded: loaded)
                }
            }
        }
    }
    /// The request phase and its results; local lists are always loaded.
    private struct Loaded { var phase: ComboboxSearchPhase = .loaded; var results: [SelectOption<Value>] = [] }
    private var loadedResults: Loaded {
        guard case .search = source else { return Loaded() }
        return Loaded(phase: remote.phase, results: remote.results)
    }
    /// Options for the current query: local filtering, or the latest remote results.
    private func matches(for query: String, loaded: Loaded) -> [SelectOption<Value>] {
        switch source {
        case .options(let options): Self.matching(options, query: query)
        case .search: loaded.results
        }
    }
    private func selectedLabel(loaded: Loaded) -> String? {
        guard let value = selection.wrappedValue else { return nil }
        switch source {
        case .options(let options): return options.first { $0.value == value }?.label
        case .search(_, let label):
            return loaded.results.first { $0.value == value }?.label
                ?? (session.chosen?.value == value ? session.chosen?.label : nil) ?? label
        }
    }
    private func search(_ query: String, immediately: Bool = false, force: Bool = false) {
        guard case .search(let search, _) = source else { return }
        remote.request(query, search: search, immediately: immediately, force: force)
    }
    private func content(rows: ComboboxRowMetrics, loaded: Loaded) -> some View {
        let matches = matches(for: session.query.stringValue, loaded: loaded)
        let selectedLabel = selectedLabel(loaded: loaded)
        let title = selectedLabel ?? presentation.placeholder
        var popover = Popover(isPresented: Binding(get: { session.isPresented }, set: { open in
            if open && !session.isPresented {
                session.query = ""; session.highlighted = selection.wrappedValue; session.focusRequest += 1
                // Remote data can change between opens: refresh, keeping the
                // previous results dimmed until the new ones arrive.
                search("", immediately: true, force: true)
            }
            if !open { remote.cancel() }
            session.isPresented = open
        }), isEnabled: presentation.isEnabled, width: presentation.width, surface: .content, overflow: .flip, onKey: { event, phase in
            guard phase != .capture else { return .ignored }
            let enabled = matches.filter(\.isEnabled).map(\.value)
            if let command = SelectionNavigation.command(for: event.scancode) {
                session.highlighted = command.destination(in: enabled, from: session.highlighted)
                return .handled
            }
            if event.scancode == Scancode.return || event.scancode == Scancode.keypadEnter {
                if let value = session.highlighted, enabled.contains(value) { choose(value, from: matches) }
                else if let first = enabled.first { choose(first, from: matches) }
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
                    search(query.stringValue)
                    session.highlighted = self.matches(for: query.stringValue, loaded: loaded).first(where: \.isEnabled)?.value
                })) { input in
                    input.behavior.clearable = true
                    input.navigation.focusRequestID = session.focusRequest
                    input.events.onSubmit = {
                        if let value = session.highlighted, matches.contains(where: { $0.value == value && $0.isEnabled }) { choose(value, from: matches) }
                        else if let first = matches.first(where: \.isEnabled) { choose(first.value, from: matches) }
                    }
                    input.events.onKeyDown = { event in
                        guard [Scancode.arrowUp, Scancode.arrowDown].contains(event.scancode),
                              let command = SelectionNavigation.command(for: event.scancode) else { return false }
                        session.highlighted = command.destination(in: matches.filter(\.isEnabled).map(\.value), from: session.highlighted)
                        return true
                    }
                }
                ComboboxResults(phase: loaded.phase, matches: matches, emptyText: presentation.emptyText,
                                listHeight: Float(min(presentation.maxVisibleRows, max(1, matches.count))) * rows.displayedHeight,
                                retry: { search(session.query.stringValue, immediately: true, force: true) }) {
                    List(matches, id: \.value, selection: Binding(get: { session.highlighted }, set: { value in
                        session.highlighted = value
                    }), rowHeight: rows.authoredHeight, onActivate: { if $0.isEnabled { choose($0.value, from: matches) } }) { option, _ in
                        Row(alignment: .center, spacing: 8) {
                            Text(option.label).truncated().font(.label).foregroundColor(option.isEnabled ? .onSurface : .onSurfaceDisabled)
                                .flex(1, shrink: 1).frame(minWidth: 0)
                            if option.value == selection.wrappedValue { Icon(UIIcons.Action.check, size: .small).flex(0, shrink: 0) }
                        }
                    }
                }
            }.padding(8).floatingSurface(.controlRadius)
        })
        popover.sizing = .anchor
        popover.triggerDescription = .init(label: title, value: selectedLabel ?? "", help: title)
        return popover.frame(width: presentation.width, minWidth: max(44, chromeWidth + 26))
            .compositionLocal(ActionControlAccessibility.role, .comboBox)
            .modifier(ComboboxSearchLifetime(session: remote))
    }
    private func choose(_ value: Value, from matches: [SelectOption<Value>]) {
        guard presentation.isEnabled, let option = matches.first(where: { $0.value == value && $0.isEnabled }) else { return }
        session.chosen = option
        selection.wrappedValue = value
        session.isPresented = false
    }
}
