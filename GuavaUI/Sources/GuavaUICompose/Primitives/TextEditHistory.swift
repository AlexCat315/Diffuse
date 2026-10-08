import Foundation
import GuavaUIRuntime

/// Per-document text transactions. Selection is restored with the text; a new
/// edit after undo discards the redo branch. Adjacent typing/deletion coalesces.
public final class TextEditHistory {
    public struct Snapshot: Equatable {
        public var buffer: TextBuffer
        public var cursor: Int
        public var anchor: Int?
        public init(buffer: TextBuffer, cursor: Int, anchor: Int? = nil) {
            self.buffer = buffer; self.cursor = cursor; self.anchor = anchor
        }
    }
    public enum Kind { case typing, deletion, atomic }
    private struct Transaction {
        var before: Snapshot; var after: Snapshot; var kind: Kind; var time: Double
    }
    private let registrar = ObservableStateRegistrar()
    private var undoStack: [Transaction] = []
    private var redoStack: [Transaction] = []
    public private(set) var currentBuffer: TextBuffer?
    public var canUndo: Bool { registrar.access("undo"); return !undoStack.isEmpty }
    public var canRedo: Bool { registrar.access("redo"); return !redoStack.isEmpty }
    public init() {}
    private func notify(_ undo: Bool, _ redo: Bool) {
        if undo != !undoStack.isEmpty { registrar.invalidate("undo") }
        if redo != !redoStack.isEmpty { registrar.invalidate("redo") }
    }
    public func synchronize(_ buffer: TextBuffer) {
        let oldUndo = !undoStack.isEmpty, oldRedo = !redoStack.isEmpty
        defer { notify(oldUndo, oldRedo) }
        if currentBuffer != buffer { undoStack.removeAll(); redoStack.removeAll(); currentBuffer = buffer }
    }
    public func breakGroup() { if !undoStack.isEmpty { undoStack[undoStack.count - 1].time = -.infinity } }
    public func record(before: Snapshot, after: Snapshot, kind: Kind, time: Double) {
        let oldUndo = !undoStack.isEmpty, oldRedo = !redoStack.isEmpty
        defer { notify(oldUndo, oldRedo) }
        guard before.buffer != after.buffer else { return }
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
        currentBuffer = after.buffer
    }
    public func undo() -> Snapshot? {
        let oldUndo = !undoStack.isEmpty, oldRedo = !redoStack.isEmpty
        defer { notify(oldUndo, oldRedo) }
        guard let edit = undoStack.popLast() else { return nil }
        redoStack.append(edit); currentBuffer = edit.before.buffer; breakGroup()
        return edit.before
    }
    public func redo() -> Snapshot? {
        let oldUndo = !undoStack.isEmpty, oldRedo = !redoStack.isEmpty
        defer { notify(oldUndo, oldRedo) }
        guard var edit = redoStack.popLast() else { return nil }
        edit.time = -.infinity; undoStack.append(edit); currentBuffer = edit.after.buffer
        return edit.after
    }
}

extension TextField {
    func beginEdit(_ state: FieldState, kind: TextEditHistory.Kind) {
        if state.transaction.depth == 0 {
            state.transaction.history.synchronize(text.wrappedValue)
            normalizeIndices(state)
            state.transaction.before = .init(buffer: text.wrappedValue, cursor: state.selection.cursorIndex, anchor: state.selection.anchor)
            state.transaction.kind = kind
        }
        state.transaction.depth += 1
    }
    func endEdit(_ state: FieldState) {
        state.transaction.depth -= 1
        guard state.transaction.depth == 0, let before = state.transaction.before else { return }
        state.transaction.history.record(before: before,
                             after: .init(buffer: text.wrappedValue, cursor: state.selection.cursorIndex, anchor: state.selection.anchor),
                             kind: state.transaction.kind, time: ProcessInfo.processInfo.systemUptime)
        state.transaction.before = nil
    }
    func restoreHistory(_ state: FieldState, redo: Bool) {
        state.transaction.history.synchronize(text.wrappedValue)
        guard let snapshot = redo ? state.transaction.history.redo() : state.transaction.history.undo() else { return }
        state.clearComposition()
        text.wrappedValue = snapshot.buffer
        state.selection.cursorIndex = snapshot.cursor; state.selection.anchor = snapshot.anchor
        state.selection.preferredCaretX = nil
        recordCaretActivity(state); events.onChange?(snapshot.buffer)
    }
}
