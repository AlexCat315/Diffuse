internal import EditorCore
internal import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

/// One gutter arrow: a declaration and where its hierarchy continues.
struct ScriptSymbolRelation: Equatable {
    enum Direction: Equatable { case up, down }
    let line: Int
    let direction: Direction
    let symbol: String
    let locations: [ScriptDefinitionLocation]

    var command: ScriptSemanticCommand { direction == .up ? .supertypes : .implementations }
}

/// Passive language facts about the selected script: its outline (for the
/// breadcrumb and outline menu), hierarchy relations (gutter arrows) and
/// whether the caret line has code actions (the bulb). It follows the script
/// workspace on its own, waits for edits to settle, and never edits source.
final class ScriptInsightSession: _ObservableObject, @unchecked Sendable {
    private let publisher = _ObservablePublisher<ScriptInsightSession>()
    private let app: EditorApplication
    private(set) var revision: UInt64 = 0
    private(set) var symbols: [ScriptDocumentSymbol] = []
    private(set) var relations: [ScriptSymbolRelation] = []
    /// The caret line, once it is known to have code actions.
    private(set) var fixLine: Int?
    private(set) var caretLine = 0
    /// UTF-8 ranges of the symbol at the caret, for the analyzed revision.
    private(set) var occurrences: [Range<Int>] = []
    private var observation: AnyHashable?
    private var analyzed: Key?
    private var analysisTask: Task<Void, Never>?
    private var fixTask: Task<Void, Never>?
    private var occurrenceTask: Task<Void, Never>?

    private struct Key: Equatable {
        let scriptID: String
        let revision: UInt64
    }

    /// Declarations queried per pass, so a long file cannot flood the server.
    private static let relationBudget = 48

    init(app: EditorApplication) {
        self.app = app
        observation = app.workstation.scripts._registerObserver { [weak self] in
            MainActor.assumeIsolated { self?.scriptsChanged() }
        }
        MainActor.assumeIsolated { scriptsChanged() }
    }

    deinit {
        if let observation { app.workstation.scripts._unregisterObserver(observation) }
        analysisTask?.cancel(); fixTask?.cancel(); occurrenceTask?.cancel()
    }

    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
    private func publish() { revision &+= 1; publisher.send() }

    /// Declarations enclosing `line`, outermost first.
    func path(atLine line: Int) -> [ScriptDocumentSymbol] {
        var path: [ScriptDocumentSymbol] = []
        var level = symbols
        while let symbol = level.first(where: { $0.range.start.line <= line && line <= $0.range.end.line }) {
            path.append(symbol); level = symbol.children
        }
        return path
    }

    func caretMoved(_ state: TextFieldCaretState) {
        guard let document = app.workstation.scripts.snapshot.selectedDocument else { return }
        let line = ScriptSourceCoordinates.position(in: document.source, atCharacterIndex: state.caretIndex).line
        requestOccurrences(document: document, caretIndex: state.caretIndex)
        guard line != caretLine || fixLine == nil else { return }
        let changed = line != caretLine
        caretLine = line
        if fixLine != nil, fixLine != line { fixLine = nil }
        if changed { publish() }
        requestFixes(document: document, line: line)
    }

    @MainActor
    private func scriptsChanged() {
        let snapshot = app.workstation.scripts.snapshot
        guard snapshot.languageServiceState == .ready, let document = snapshot.selectedDocument else {
            if analyzed != nil || !symbols.isEmpty || !relations.isEmpty {
                analysisTask?.cancel(); analyzed = nil
                symbols = []; relations = []; fixLine = nil; publish()
            }
            return
        }
        let key = Key(scriptID: document.file.identifier, revision: document.editRevision)
        guard key != analyzed else { return }
        let sameScript = analyzed?.scriptID == key.scriptID
        analyzed = key
        analysisTask?.cancel(); fixTask?.cancel()
        // Lines shift under an edit; stale arrows would point at the wrong code.
        relations = []; fixLine = nil; occurrences = []; occurrenceTask?.cancel()
        if !sameScript { symbols = []; caretLine = 0 }
        publish()
        analysisTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(sameScript ? 700 : 150))
            await self?.analyze(key)
        }
    }

    @MainActor
    private func analyze(_ key: Key) async {
        let manager = app.dynamicScriptManager
        guard !Task.isCancelled,
              let symbols = try? await manager.documentSymbols(scriptID: key.scriptID),
              !Task.isCancelled, analyzed == key else { return }
        self.symbols = symbols; publish()
        var relations: [ScriptSymbolRelation] = []
        for (symbol, parent) in Self.declarations(symbols).prefix(Self.relationBudget) {
            let position = symbol.selectionRange.start
            let own = { (location: ScriptDefinitionLocation) in
                !(location.scriptID == key.scriptID && location.span.start.line == position.line)
            }
            if Self.isType(symbol.kind) {
                let supers = (try? await manager.supertypes(scriptID: key.scriptID, at: position))?.filter(own) ?? []
                let subs = (try? await manager.subtypes(scriptID: key.scriptID, at: position))?.filter(own) ?? []
                if !supers.isEmpty { relations.append(.init(line: position.line, direction: .up, symbol: symbol.name, locations: supers)) }
                if !subs.isEmpty { relations.append(.init(line: position.line, direction: .down, symbol: symbol.name, locations: subs)) }
            } else if parent.map({ Self.isType($0.kind) }) == true {
                let implementations = (try? await manager.implementations(scriptID: key.scriptID, at: position))?.filter(own) ?? []
                if !implementations.isEmpty {
                    relations.append(.init(line: position.line, direction: .down, symbol: symbol.name, locations: implementations))
                }
            }
            guard !Task.isCancelled, analyzed == key else { return }
        }
        self.relations = relations; publish()
        if let document = app.workstation.scripts.snapshot.selectedDocument { requestFixes(document: document, line: caretLine) }
    }

    /// Asks for code actions on the caret line once the caret rests there.
    private func requestFixes(document: ScriptWorkspaceDocument, line: Int) {
        fixTask?.cancel()
        guard app.workstation.scripts.snapshot.languageServiceState == .ready, line < document.source.lineCount else { return }
        let start = document.source.characterIndex(forLine: line, character: 0)
        let end = line + 1 < document.source.lineCount ? document.source.characterIndex(forLine: line + 1, character: 0) : document.source.characterCount
        let span = ScriptLanguageSpan(start: ScriptSourceCoordinates.position(in: document.source, atCharacterIndex: start),
                                      end: ScriptSourceCoordinates.position(in: document.source, atCharacterIndex: max(start, end)))
        let key = Key(scriptID: document.file.identifier, revision: document.editRevision)
        fixTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled,
                  let actions = try? await self.app.dynamicScriptManager.codeActions(scriptID: key.scriptID, range: span),
                  !Task.isCancelled, self.analyzed == key, self.caretLine == line else { return }
            let next = actions.contains { $0.disabledReason == nil } ? line : nil
            if next != self.fixLine { self.fixLine = next; self.publish() }
        }
    }

    private func requestOccurrences(document: ScriptWorkspaceDocument, caretIndex: Int) {
        occurrenceTask?.cancel()
        guard app.workstation.scripts.snapshot.languageServiceState == .ready else { return }
        let source = document.source
        let position = ScriptSourceCoordinates.position(in: source, atCharacterIndex: caretIndex)
        let key = Key(scriptID: document.file.identifier, revision: document.editRevision)
        occurrenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            let spans = (try? await self.app.dynamicScriptManager.documentHighlights(scriptID: key.scriptID, at: position)) ?? []
            guard !Task.isCancelled, self.analyzed == key else { return }
            let next = spans.map { span in
                source.utf8Offset(forCharacterIndex: ScriptSourceCoordinates.characterIndex(in: source, at: span.start))
                    ..< source.utf8Offset(forCharacterIndex: ScriptSourceCoordinates.characterIndex(in: source, at: span.end))
            }.filter { !$0.isEmpty }
            // A lone match is the symbol itself; marking it adds nothing.
            let shown = next.count > 1 ? next : []
            if shown != self.occurrences { self.occurrences = shown; self.publish() }
        }
    }

    private static func isType(_ kind: Int) -> Bool { [5, 10, 11, 23].contains(kind) }

    /// Types and their direct members, each with its enclosing declaration.
    private static func declarations(_ symbols: [ScriptDocumentSymbol],
                                     parent: ScriptDocumentSymbol? = nil) -> [(ScriptDocumentSymbol, ScriptDocumentSymbol?)] {
        symbols.flatMap { symbol -> [(ScriptDocumentSymbol, ScriptDocumentSymbol?)] in
            let nested = isType(symbol.kind) ? declarations(symbol.children, parent: symbol) : []
            let relevant = isType(symbol.kind) || [6, 7, 12].contains(symbol.kind)
            return (relevant ? [(symbol, parent)] : []) + nested
        }
    }
}
