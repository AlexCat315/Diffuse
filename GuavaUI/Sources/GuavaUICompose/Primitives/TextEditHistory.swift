import Foundation
import GuavaUIRuntime

/// Per-document text transactions. Selection is restored with the text; a new
/// edit after undo discards the redo branch. Adjacent typing/deletion coalesces.
public final class TextEditHistory {
    public struct Snapshot: Equatable {
        public var text: String
        public var cursor: Int
        public var anchor: Int?
        public init(text: String, cursor: Int, anchor: Int? = nil) {
            self.text = text; self.cursor = cursor; self.anchor = anchor
        }
    }
    public enum Kind { case typing, deletion, atomic }
    private struct Transaction {
        var before: Snapshot; var after: Snapshot; var kind: Kind; var time: Double
    }
    private let registrar = ObservableStateRegistrar()
    private var undoStack: [Transaction] = []
    private var redoStack: [Transaction] = []
    public private(set) var currentText: String?
    public var canUndo: Bool { registrar.access("undo"); return !undoStack.isEmpty }
    public var canRedo: Bool { registrar.access("redo"); return !redoStack.isEmpty }
    public init() {}
    private func notify(_ undo: Bool, _ redo: Bool) {
        if undo != !undoStack.isEmpty { registrar.invalidate("undo") }
        if redo != !redoStack.isEmpty { registrar.invalidate("redo") }
    }
    public func synchronize(_ text: String) {
        let oldUndo = !undoStack.isEmpty, oldRedo = !redoStack.isEmpty
        defer { notify(oldUndo, oldRedo) }
        if currentText != text { undoStack.removeAll(); redoStack.removeAll(); currentText = text }
    }
    public func breakGroup() { if !undoStack.isEmpty { undoStack[undoStack.count - 1].time = -.infinity } }
    public func record(before: Snapshot, after: Snapshot, kind: Kind, time: Double) {
        let oldUndo = !undoStack.isEmpty, oldRedo = !redoStack.isEmpty
        defer { notify(oldUndo, oldRedo) }
        guard before.text != after.text else { return }
        redoStack.removeAll()
        if let last = undoStack.last, kind != .atomic, last.kind == kind,
           time - last.time < 0.75, last.after == before,
           before.anchor == nil, after.anchor == nil {
            undoStack[undoStack.count - 1].after = after
            undoStack[undoStack.count - 1].time = time
        } else {
            undoStack.append(Transaction(before: before, after: after, kind: kind, time: time))
            if undoStack.count > 100 { undoStack.removeFirst() }
        }
        currentText = after.text
    }
    public func undo() -> Snapshot? {
        let oldUndo = !undoStack.isEmpty, oldRedo = !redoStack.isEmpty
        defer { notify(oldUndo, oldRedo) }
        guard let edit = undoStack.popLast() else { return nil }
        redoStack.append(edit); currentText = edit.before.text; breakGroup()
        return edit.before
    }
    public func redo() -> Snapshot? {
        let oldUndo = !undoStack.isEmpty, oldRedo = !redoStack.isEmpty
        defer { notify(oldUndo, oldRedo) }
        guard var edit = redoStack.popLast() else { return nil }
        edit.time = -.infinity; undoStack.append(edit); currentText = edit.after.text
        return edit.after
    }
}

extension TextField {
    func beginEdit(_ state: FieldState, kind: TextEditHistory.Kind) {
        if state.editDepth == 0 {
            state.history.synchronize(text.wrappedValue)
            normalizeIndices(state)
            state.editBefore = .init(text: text.wrappedValue, cursor: state.cursorIndex, anchor: state.selectionAnchor)
            state.editKind = kind
        }
        state.editDepth += 1
    }
    func endEdit(_ state: FieldState) {
        state.editDepth -= 1
        guard state.editDepth == 0, let before = state.editBefore else { return }
        state.history.record(before: before,
                             after: .init(text: text.wrappedValue, cursor: state.cursorIndex, anchor: state.selectionAnchor),
                             kind: state.editKind, time: ProcessInfo.processInfo.systemUptime)
        state.editBefore = nil
    }
    func restoreHistory(_ state: FieldState, redo: Bool) {
        state.history.synchronize(text.wrappedValue)
        guard let snapshot = redo ? state.history.redo() : state.history.undo() else { return }
        state.clearComposition()
        text.wrappedValue = snapshot.text
        state.cursorIndex = snapshot.cursor; state.selectionAnchor = snapshot.anchor
        state.preferredCaretX = nil
        recordCaretActivity(state); onChange?(snapshot.text)
    }
}
