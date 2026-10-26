internal import EditorCore
internal import Foundation
internal import CoveUI
internal import CoveUIRuntime

struct DocumentSyntaxSegment: Sendable, Equatable {
    let range: Range<Int>
    let token: LanguageSyntaxRule.Token
}

/// UI-owned syntax snapshot for a plugin-declared grammar. Parsing runs on
/// one serial worker and only the latest buffer may publish.
final class DocumentSyntaxSession: _ObservableObject, @unchecked Sendable {
    private let publisher = _ObservablePublisher<DocumentSyntaxSession>()
    private var worker: DocumentSyntaxWorker?
    private var rules: [LanguageSyntaxRule] = []
    private var requested: TextBuffer?
    private(set) var revision = 0
    private(set) var parsedBuffer: TextBuffer?
    private(set) var segments: [DocumentSyntaxSegment] = []
    var isEmpty: Bool { worker == nil }

    init(languageID: String?, languages: LanguageCatalog = .bundled) {
        configure(languages.syntaxRules(forLanguageID: languageID))
    }

    func configure(_ rules: [LanguageSyntaxRule]) {
        guard self.rules != rules else { return }
        self.rules = rules
        worker = DocumentGrammar(rules: rules).map(DocumentSyntaxWorker.init)
        requested = nil; parsedBuffer = nil; segments = []
        revision &+= 1
    }

    func request(_ buffer: TextBuffer) {
        guard requested != buffer else { return }
        requested = buffer
        guard let worker else { return }
        if buffer.characterCount > 1_000_000 {
            segments = []
            parsedBuffer = buffer
            revision &+= 1
            publisher.send()
            return
        }
        let rules = rules
        worker.request(buffer) { [weak self] buffer, segments in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.requested == buffer, self.rules == rules else { return }
                self.segments = segments
                self.parsedBuffer = buffer
                self.revision &+= 1
                self.publisher.send()
            }
        }
    }

    func color(atUTF8Offset offset: Int, light: Bool, palette: [String: Color] = [:]) -> Color? {
        var lower = 0
        var upper = segments.count
        while lower < upper {
            let middle = (lower + upper) / 2
            let segment = segments[middle]
            if offset < segment.range.lowerBound {
                upper = middle
            } else if offset >= segment.range.upperBound {
                lower = middle + 1
            } else {
                return segment.token.category.color(light: light, palette: palette)
            }
        }
        return nil
    }

    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}

struct DocumentSyntaxReader<Content: View>: View {
    private var observation: Observed<DocumentSyntaxSession, Int>
    let session: DocumentSyntaxSession
    let content: (DocumentSyntaxSession) -> Content

    init(_ session: DocumentSyntaxSession, @ViewBuilder content: @escaping (DocumentSyntaxSession) -> Content) {
        self.session = session
        self.content = content
        observation = Observed(\.revision, on: session)
    }

    var body: some View {
        let _ = observation.wrappedValue
        return content(session)
    }
}

/// The lock protects the pending mailbox only; regex objects stay on the
/// queue and the delivery handoff is immutable.
private final class DocumentSyntaxWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "cove.document-syntax", qos: .userInitiated)
    private let lock = NSLock()
    private let grammar: DocumentGrammar
    private var pending: TextBuffer?
    private var scheduled = false

    init(grammar: DocumentGrammar) {
        self.grammar = grammar
    }

    func request(_ buffer: TextBuffer,
                 deliver: @escaping @Sendable (TextBuffer, [DocumentSyntaxSegment]) -> Void) {
        lock.lock()
        pending = buffer
        let start = !scheduled
        scheduled = true
        lock.unlock()
        guard start else { return }
        queue.async { [self] in
            while true {
                lock.lock()
                let next = pending
                pending = nil
                if next == nil { scheduled = false }
                lock.unlock()
                guard let next else { return }
                let segments = grammar.tokens(in: next.stringValue).map {
                    DocumentSyntaxSegment(range: $0.range, token: $0.token)
                }
                deliver(next, segments)
            }
        }
    }
}
