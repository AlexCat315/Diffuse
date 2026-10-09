import Foundation
import GuavaUIRuntime

public struct TextCompletionRequest: Sendable {
    public let buffer: TextBuffer
    public let caretIndex: Int
    public let prefix: String
    public let prefixRange: Range<Int>
    public var utf8Offset: Int { buffer.utf8Offset(forCharacterIndex: caretIndex) }
    public init(buffer: TextBuffer, caretIndex: Int) {
        self.buffer = buffer; self.caretIndex = min(buffer.characterCount, max(0, caretIndex))
        var start = self.caretIndex
        while start > 0, let character = buffer.character(at: start - 1),
              character.isLetter || character.isNumber || character == "_" { start -= 1 }
        prefixRange = start..<self.caretIndex
        prefix = buffer.substring(characterRange: prefixRange)
    }
}
public struct TextCompletionItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public var detail: String?
    public var insertText: String
    public var filterText: String?
    public var replacement: Range<Int>?
    public var additionalEdits: [TextCompletionEdit] = []
    public init(id: String, label: String, insertText: String) {
        self.id = id; self.label = label; self.insertText = insertText
    }
}
public struct TextCompletionEdit: Sendable, Equatable {
    public let range: Range<Int>
    public let text: String
    public init(range: Range<Int>, text: String) { self.range = range; self.text = text }
}
public typealias TextCompletionProvider = (TextCompletionRequest, @escaping @MainActor @Sendable ([TextCompletionItem]) -> Void) -> Void

/// Nonmodal completion list. Keyboard focus stays in the editor, while its
/// highlighted row and scroll window follow Up/Down, Return, Tab and Escape.
public struct CompletionPopover: View {
    public let items: [TextCompletionItem]
    public let selectedIndex: Int
    public let onAccept: (TextCompletionItem) -> Void
    public init(items: [TextCompletionItem], selectedIndex: Int, onAccept: @escaping (TextCompletionItem) -> Void) {
        self.items = items; self.selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1)); self.onAccept = onAccept
    }
    public var body: some View {
        let start = max(0, min(selectedIndex - 5, items.count - 10))
        return Box(direction: .column, alignItems: .stretch, spacing: 0) {
            for pair in Array(items.dropFirst(start).prefix(10).enumerated()) {
                CompletionRow(item: pair.element, isSelected: start + pair.offset == selectedIndex,
                              onAccept: { onAccept(pair.element) })
            }
            if items.count > 10 {
                Text("\(selectedIndex + 1) / \(items.count)").font(.caption).foregroundColor(.onSurfaceMuted)
                    .padding(horizontal: 10, vertical: 4)
            }
        }.padding(3).background(.surfaceFloating).border(.border, width: 1).cornerRadius(6)
            .accessibility { $0.role = .list; $0.label = "Completions" }
    }
}
private struct CompletionRow: _PrimitiveView {
    let item: TextCompletionItem
    let isSelected: Bool
    let onAccept: () -> Void
    func _makeNode() -> Node {
        let node = Node(); node.isHitTestable = true; node.isFocusable = true
        node.isTabStop = false; node.automaticallyFocusOnPointerDown = false
        return node
    }
    func _makeLayoutNode() -> LayoutNode? { let layout = LayoutNode(); layout.alignItems = .stretch; return layout }
    func _updateNode(_ node: Node) {
        node.accessibility = AccessibilitySemantics(.listItem) { $0.label = item.label; $0.state.isSelected = isSelected }
        node.accessibilityActions.activate = onAccept
        InteractionRegistryHolder.current?.setPointer(node) { event, phase, _ in
            guard event.button == .left else { return .ignored }
            if phase == .down { onAccept() }; return .handled
        }
    }
    var _children: [any View] {
        [Row(alignment: .center, spacing: 10) {
            Text(item.label, lineLimit: 1).font(.body).foregroundColor(.onSurface).flex(1, shrink: 1)
            if let detail = item.detail { Text(detail, lineLimit: 1).font(.caption).foregroundColor(.onSurfaceMuted) }
        }.padding(horizontal: 9, vertical: 5).background(isSelected ? SemanticColorRef.selection : .surfaceFloating).cornerRadius(3)]
    }
}

/// Callback delivery and the scheduler are confined to the UI executor.
/// Sendable permits an async provider to retain its main-actor reply closure.
final class TextCompletionSession: NodeResource, AnyAnimationController, @unchecked Sendable {
    private weak var node: Node?
    private weak var owningStore: PortalStore?
    private weak var state: TextField.FieldState?
    private var field: TextField?
    private let portal = PortalResource()
    private var request: TextCompletionRequest?
    private var generation: UInt64 = 0
    private var elapsed = 0.0
    private var candidates: [TextCompletionItem] = []
    private(set) var items: [TextCompletionItem] = []
    private(set) var selectedIndex = 0
    private var anchor = CGRect.zero
    var isFinished = true
    func mount(node: Node) { self.node = node }
    func unmount(node: Node) { dismiss(); self.node = nil; field = nil; state = nil }
    func configure(field: TextField, state: TextField.FieldState) {
        self.field = field; self.state = state
        if let node {
            let current = node.compositionValue(of: PortalStoreEnvironment.key) ?? PortalStoreHolder.current
            if owningStore == nil || current !== PortalStoreHolder.shared { owningStore = current }
        }
        if field.codeEditing.onRequestCompletion == nil || field.behavior.readOnly || field.behavior.disabled { dismiss() }
        if let request, request.buffer != field.text.wrappedValue || request.caretIndex != state.selection.cursorIndex { dismiss() }
    }
    func activity(explicit: Bool = false) {
        guard let field, let state, let node, !state.composition.isActive,
              state.selection.anchor == nil, field.codeEditing.onRequestCompletion != nil,
              FocusChainHolder.current?.focused === node else { dismiss(); return }
        let next = TextCompletionRequest(buffer: field.text.wrappedValue, caretIndex: state.selection.cursorIndex)
        let dot = next.caretIndex > 0 && next.buffer.character(at: next.caretIndex - 1) == "."
        guard explicit || !next.prefix.isEmpty || dot else { dismiss(); return }
        generation &+= 1; elapsed = 0
        if let request, request.buffer != next.buffer {
            candidates = TextCompletionRebase.candidates(candidates, from: request, to: next)
        } else if request?.prefixRange.lowerBound != next.prefixRange.lowerBound { candidates = [] }
        request = next
        filter()
        isFinished = false; AnimatorScheduler.current.register(self)
        if explicit { elapsed = 0.3; tick(deltaTime: 0) }
    }
    func tick(deltaTime: Double) {
        guard !isFinished else { return }
        elapsed += max(0, deltaTime)
        guard elapsed >= 0.3, let request, let provider = field?.codeEditing.onRequestCompletion else { return }
        isFinished = true
        let token = generation
        provider(request) { [weak self] candidates in
            guard let self, self.generation == token, let state = self.state,
                  self.field?.text.wrappedValue == request.buffer, state.selection.cursorIndex == request.caretIndex,
                  self.node != nil else { return }
            self.candidates = candidates; self.filter()
        }
    }
    private func filter() {
        let prefix = request?.prefix ?? ""
        items = candidates.filter { prefix.isEmpty || ($0.filterText ?? $0.label).lowercased().hasPrefix(prefix.lowercased()) }
        selectedIndex = min(max(0, selectedIndex), max(0, items.count - 1))
        present()
    }
    private func present() {
        guard let node, !items.isEmpty else { if let node { portal.unmount(node: node) }; return }
        let store = owningStore ?? node.compositionValue(of: PortalStoreEnvironment.key) ?? PortalStoreHolder.current
        portal.present(in: store, position: CGPoint(x: anchor.minX, y: anchor.maxY + 3), width: 380,
            content: AnyView(CompletionPopover(items: items, selectedIndex: selectedIndex) { [weak self] item in self?.accept(item) }))
        portal.setDismissal(anchor: { [weak self] in self?.node?.absoluteFrame ?? .zero }, dismiss: { [weak self] in self?.dismiss() })
    }
    func updateAnchor(_ rect: CGRect) {
        anchor = rect
        portal.updatePosition(CGPoint(x: rect.minX, y: rect.maxY + 3))
        portal.setDismissal(anchor: { rect }, dismiss: { [weak self] in self?.dismiss() })
    }
    func handleKey(_ event: KeyEvent) -> Bool {
        if event.scancode == Scancode.space, !event.modifiers.isDisjoint(with: .ctrl) { activity(explicit: true); return true }
        guard !items.isEmpty else { return false }
        switch event.scancode {
        case Scancode.arrowUp: selectedIndex = (selectedIndex + items.count - 1) % items.count; present()
        case Scancode.arrowDown: selectedIndex = (selectedIndex + 1) % items.count; present()
        case Scancode.return, Scancode.keypadEnter, Scancode.tab: accept(items[selectedIndex])
        case Scancode.escape: dismiss()
        default: return false
        }
        return true
    }
    private func accept(_ item: TextCompletionItem) {
        guard let field, let state, let request, field.text.wrappedValue == request.buffer else { dismiss(); return }
        let range = item.replacement ?? request.prefixRange
        guard range.lowerBound >= 0, range.upperBound <= request.buffer.characterCount else { dismiss(); return }
        let edits = (item.additionalEdits + [TextCompletionEdit(range: range, text: item.insertText)])
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        for index in edits.indices {
            let edit = edits[index]
            guard edit.range.lowerBound >= 0, edit.range.upperBound <= request.buffer.characterCount else { dismiss(); return }
            if index > 0, edits[index - 1].range.upperBound > edit.range.lowerBound || edits[index - 1].range == edit.range {
                dismiss(); return
            }
        }
        var next = request.buffer
        let beforeCaret = item.additionalEdits.filter { $0.range.upperBound <= range.lowerBound }
            .reduce(0) { $0 + $1.text.utf8.count - (request.buffer.utf8Offset(forCharacterIndex: $1.range.upperBound)
                                                   - request.buffer.utf8Offset(forCharacterIndex: $1.range.lowerBound)) }
        let caretByte = request.buffer.utf8Offset(forCharacterIndex: range.lowerBound) + item.insertText.utf8.count + beforeCaret
        for edit in edits.reversed() { next = next.replace(characterRange: edit.range, with: edit.text) }
        if let maximum = field.behavior.maxLength, next.characterCount > maximum { dismiss(); return }
        dismiss()
        field.beginEdit(state, kind: .atomic)
        defer { field.endEdit(state) }
        field.text.wrappedValue = next; state.clearComposition()
        state.selection.anchor = nil; state.selection.cursorIndex = next.characterIndex(forUTF8Offset: caretByte)
        field.recordCaretActivity(state); field.events.onChange?(next)
        dismiss()
        field.codeEditing.onAcceptCompletion?(item)
    }
    func dismiss() {
        generation &+= 1; isFinished = true; request = nil; candidates = []; items = []; selectedIndex = 0
        if let node { portal.unmount(node: node) }
    }
    func cancel() { dismiss() }
    func finishImmediately() { dismiss() }
}
