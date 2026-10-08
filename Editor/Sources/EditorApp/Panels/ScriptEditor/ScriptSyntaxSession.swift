import Foundation
import EngineCore
import GuavaUICompose
import GuavaUIRuntime

/// UI-owned syntax snapshot. Editing adjusts its coordinates immediately;
/// native parsing runs on one serial worker and publishes only the latest root.
final class ScriptSyntaxSession: _ObservableObject, @unchecked Sendable {
    private let publisher = _ObservablePublisher<ScriptSyntaxSession>()
    private let worker = ScriptSyntaxWorker()
    private var requested: TextBuffer?
    private var tree: SyntaxTree?
    private var token: (range: Range<Int>, kind: SwiftSyntaxTokenKind)?
    private(set) var revision = 0
    private(set) var parsedBuffer: TextBuffer?
    private(set) var failure: Error?

    func request(_ buffer: TextBuffer) {
        guard requested != buffer else { return }
        if let previous = requested, let tree, let delta = buffer.editDelta(from: previous) {
            self.tree = tree.applying(syntaxEdit(delta, previous: previous, current: buffer))
        }
        requested = buffer; token = nil
        worker.request(buffer) { [weak self] buffer, tree, failure in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requested == buffer else { return }
                self.tree = tree; self.parsedBuffer = buffer; self.failure = failure
                self.token = nil; self.revision &+= 1; self.publisher.send()
            }
        }
    }
    func color(atUTF8Offset offset: Int, light: Bool) -> Color? {
        if let token, token.range.contains(offset) { return token.kind.color(light: light) }
        guard let tree else { return nil }
        token = SwiftSyntaxTokenMap.classify(tree.path(atUTF8Offset: offset))
        return token?.kind.color(light: light)
    }
    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}

struct ScriptSyntaxReader<Content: View>: View {
    private var observation: Observed<ScriptSyntaxSession, Int>
    let session: ScriptSyntaxSession
    let content: (ScriptSyntaxSession) -> Content
    init(_ session: ScriptSyntaxSession, @ViewBuilder content: @escaping (ScriptSyntaxSession) -> Content) {
        self.session = session; self.content = content
        observation = Observed(\.revision, on: session)
    }
    var body: some View { let _ = observation.wrappedValue; return content(session) }
}

/// The lock protects the pending mailbox only. Parser and native tree handles
/// belong exclusively to queue; delivery receives an independent tree copy.
private final class ScriptSyntaxWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "guava.swift-syntax", qos: .userInitiated)
    private let lock = NSLock()
    private let highlighter = TreeSitterHighlighter()
    private var pending: TextBuffer?
    private var scheduled = false
    func request(_ buffer: TextBuffer, deliver: @escaping @Sendable (TextBuffer, SyntaxTree?, Error?) -> Void) {
        lock.lock(); pending = buffer
        let start = !scheduled; scheduled = true; lock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                lock.lock(); let next = pending; pending = nil
                if next == nil { scheduled = false }
                lock.unlock()
                guard let next else { return }
                let succeeded = highlighter.synchronize(next)
                deliver(next, succeeded ? highlighter.tree?.copy() : nil, highlighter.failure)
            }
        }
    }
}

func syntaxEdit(_ delta: TextEditDelta, previous: TextBuffer, current: TextBuffer) -> SyntaxEdit {
    func point(_ buffer: TextBuffer, _ byte: Int) -> SyntaxPoint {
        let point = buffer.parserPoint(forUTF8Offset: byte)
        return SyntaxPoint(row: point.row, byteColumn: point.columnUTF8)
    }
    return SyntaxEdit(oldByteRange: delta.startUTF8Offset..<delta.oldEndUTF8Offset, newEndByte: delta.newEndUTF8Offset,
                      start: point(previous, delta.startUTF8Offset), oldEnd: point(previous, delta.oldEndUTF8Offset),
                      newEnd: point(current, delta.newEndUTF8Offset))
}
