internal import GuavaUIRuntime

final class TextGutterSession: _ObservableObject, NodeResource {
    private let publisher = _ObservablePublisher<TextGutterSession>()
    private weak var node: Node?
    private weak var state: TextField.FieldState?
    private(set) var field: TextField?
    let folds = TextFoldSession()
    private(set) var controls: [TextGutterControl] = []
    private(set) var markersByLine: [Int: [TextGutterMarker]] = [:]
    private(set) var revision = 0
    private var buffer: TextBuffer?
    private var previousBreakpoints: [TextBreakpoint] = []
    var selectedControl: AnyHashable?

    func mount(node: Node) { self.node = node }
    func unmount(node: Node) { field = nil; controls = []; markersByLine = [:]; self.node = nil; state = nil }
    func configure(_ field: TextField, state: TextField.FieldState) {
        self.field = field; self.state = state
        markersByLine = Dictionary(grouping: field.codeEditing.gutter.markers, by: \.line)
        synchronizeSource()
        publish()
    }
    func synchronizeSource() {
        guard let field else { return }
        let next = field.text.wrappedValue
        if let buffer, buffer != next, let binding = field.codeEditing.gutter.breakpoints,
           binding.wrappedValue == previousBreakpoints {
            let rebased = TextLineRebase(buffer, next).map { change in
                binding.wrappedValue.compactMap { point -> TextBreakpoint? in
                    guard let line = change.line(point.line), line >= 0, line < next.lineCount else { return nil }
                    return TextBreakpoint(line: line, state: point.state)
                }
            } ?? (buffer.hasSameContents(as: next) ? binding.wrappedValue : [])
            if binding.wrappedValue != rebased { binding.wrappedValue = rebased; field.codeEditing.gutter.onBreakpointsChange?(rebased) }
        }
        previousBreakpoints = field.codeEditing.gutter.breakpoints?.wrappedValue ?? []
        self.buffer = next; folds.synchronize(field.codeEditing.folding, buffer: next)
    }
    func update(_ controls: [TextGutterControl]) {
        guard self.controls != controls else { return }
        self.controls = controls; publish()
    }
    private func publish() { revision &+= 1; publisher.send() }
    private var available: Bool {
        node?.acceptsSubtreeInput == true && field?.behavior.disabled == false && state?.composition.isActive != true
            && field?.codeEditing.showsLineNumbers == true && field?.layout.axis == .vertical && field?.behavior.secure == false
    }
    func toggleBreakpoint(_ line: Int) {
        guard available, let field, let binding = field.codeEditing.gutter.breakpoints else { return }
        var next = binding.wrappedValue
        if next.contains(where: { $0.line == line }) { next.removeAll { $0.line == line } }
        else { next.append(TextBreakpoint(line: line)) }
        binding.wrappedValue = next.sorted { $0.line < $1.line }
        field.codeEditing.gutter.onBreakpointsChange?(binding.wrappedValue)
        returnToEditor(); node?.markRenderDirty(); publish()
    }
    func toggleBreakpointEnabled(_ line: Int) {
        guard available, let field, let binding = field.codeEditing.gutter.breakpoints,
              let index = binding.wrappedValue.firstIndex(where: { $0.line == line }) else { return }
        var next = binding.wrappedValue
        next[index].state = next[index].state == .disabled ? .enabled : .disabled
        binding.wrappedValue = next; field.codeEditing.gutter.onBreakpointsChange?(next)
        returnToEditor(); node?.markRenderDirty(); publish()
    }
    func activateMarker(_ id: String) {
        guard available, let marker = field?.codeEditing.gutter.markers.first(where: { $0.id == id }) else { return }
        marker.action()
    }
    func toggleFold(_ line: Int) {
        guard available, let field, let state, let region = folds.regions[line] else { return }
        folds.toggle(line)
        let cursorLine = field.text.wrappedValue.lineIndex(forCharacterIndex: state.selection.cursorIndex)
        if folds.collapsed.contains(line), cursorLine > line, region.lines.contains(cursorLine) {
            state.selection.cursorIndex = field.text.wrappedValue.lineRange(forLine: line).upperBound
            state.selection.anchor = nil
        }
        field.recordCaretActivity(state); returnToEditor(); node?.markRenderDirty(); publish()
    }
    func returnToEditor() {
        guard let node else { return }
        FocusChainHolder.current?.focus(node, visible: FocusChainHolder.current?.isFocusVisible ?? false)
        // Restoring editing focus is not a text-completion gesture. Focus
        // callbacks may have scheduled a request at the unchanged caret.
        node.firstResource(TextCompletionSession.self)?.dismiss()
    }
    func handleKey(_ event: KeyEvent) -> Bool {
        guard available, let field, let state else { return false }
        let line = field.text.wrappedValue.lineIndex(forCharacterIndex: state.selection.cursorIndex)
        if event.scancode == Scancode.f9, event.modifiers.isDisjoint(with: [.gui, .ctrl, .alt]), field.codeEditing.gutter.breakpoints != nil {
            if event.modifiers.isDisjoint(with: .shift) { toggleBreakpoint(line) }
            else { toggleBreakpointEnabled(line) }
            return true
        }
        if !event.modifiers.isDisjoint(with: .alt), !event.modifiers.isDisjoint(with: [.gui, .ctrl]),
           event.scancode == Scancode.arrowLeft || event.scancode == Scancode.arrowRight {
            let candidates = folds.regions.values.filter { $0.lines.contains(line) }
                .sorted { $0.lines.count < $1.lines.count }
            guard let region = candidates.first else { return false }
            let header = region.lines.lowerBound
            if folds.collapsed.contains(header) == (event.scancode == Scancode.arrowLeft) { return true }
            toggleFold(header); return true
        }
        if event.scancode == Scancode.escape, FocusChainHolder.current?.focused !== node {
            returnToEditor(); return true
        }
        // Removing a newline at a folded boundary first reveals what would be
        // edited, rather than silently deleting an invisible closing character.
        if !field.behavior.readOnly, state.selection.anchor == nil,
           event.scancode == Scancode.backspace || event.scancode == Scancode.delete {
            let target = event.scancode == Scancode.backspace ? state.selection.cursorIndex - 1 : state.selection.cursorIndex + 1
            let targetLine = field.text.wrappedValue.lineIndex(forCharacterIndex: max(0, min(field.text.wrappedValue.characterCount, target)))
            if folds.reveal(targetLine) { field.recordCaretActivity(state); node?.markRenderDirty(); publish(); return true }
        }
        return false
    }
    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}
