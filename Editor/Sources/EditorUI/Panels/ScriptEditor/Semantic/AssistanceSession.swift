internal import EditorCore
internal import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

enum ScriptSemanticCommand: CaseIterable, Equatable {
    case definition, implementations, supertypes, references, rename, codeActions, signature, symbols, format,
         back, forward, undo, redo

    var title: String {
        switch self {
        case .definition: "Go to Definition"
        case .implementations: "Go to Implementations"
        case .supertypes: "Go to Super Type"
        case .references: "Find References"
        case .rename: "Rename Symbol"
        case .codeActions: "Quick Fix / Code Actions"
        case .signature: "Parameter Hints"
        case .symbols: "Document Outline"
        case .format: "Format Document"
        case .back: "Go Back"
        case .forward: "Go Forward"
        case .undo: "Undo Workspace Edit"
        case .redo: "Redo Workspace Edit"
        }
    }

    /// One chord per command feeds both key handling and every tooltip.
    /// Back/forward and the hierarchy jumps follow JetBrains on macOS.
    var shortcut: EditorShortcut {
        switch self {
        case .definition: EditorShortcut(.f12, [])
        case .implementations: EditorShortcut(.letter("b"), [.primary, .option])
        case .supertypes: EditorShortcut(.letter("u"))
        case .references: EditorShortcut(.f12, [.shift])
        case .rename: EditorShortcut(.f2, [])
        case .codeActions: EditorShortcut(.period)
        case .signature: EditorShortcut(.space, [.primary, .shift])
        case .symbols: EditorShortcut(.letter("o"), [.primary, .shift])
        case .format: EditorShortcut(.letter("f"), [.option, .shift])
        case .back: EditorShortcut(.leftBracket)
        case .forward: EditorShortcut(.rightBracket)
        case .undo: EditorShortcut(.letter("z"))
        case .redo: EditorShortcut(.letter("z"), [.primary, .shift])
        }
    }

    /// Localized title with its chord, for tooltips and menus.
    var help: String { "\(L(title)) (\(shortcut.label))" }

    static func matching(_ event: KeyEvent) -> Self? {
        allCases.first { $0.shortcut.matches(event) }
    }
}

struct ScriptSemanticLocation: Equatable {
    let scriptID: String?
    let fileURL: URL?
    let position: ScriptLanguagePosition
}

/// Browser-style history: a jump records where it left from and clears the
/// forward stack; back and forward trade the current place between stacks.
struct ScriptSemanticNavigation {
    private(set) var previous: [ScriptSemanticLocation] = []
    private(set) var next: [ScriptSemanticLocation] = []

    mutating func record(_ location: ScriptSemanticLocation) {
        next.removeAll()
        guard previous.last != location else { return }
        previous.append(location)
        if previous.count > 100 { previous.removeFirst() }
    }

    mutating func back(from current: ScriptSemanticLocation?) -> ScriptSemanticLocation? {
        guard let target = previous.popLast() else { return nil }
        if let current { next.append(current) }
        return target
    }

    mutating func forward(from current: ScriptSemanticLocation?) -> ScriptSemanticLocation? {
        guard let target = next.popLast() else { return nil }
        if let current { previous.append(current) }
        return target
    }
}

struct ScriptSemanticExternalDocument {
    let url: URL
    let source: TextBuffer
    let navigation: EditorScriptNavigationRequest
}

struct ScriptSemanticPresentation {
    var title = ""
    var message: String?
    var locations: [ScriptDefinitionLocation] = []
    var actions: [ScriptCodeAction] = []
    var symbols: [ScriptDocumentSymbol] = []
    var renameText: TextBuffer?
    var signature: ScriptSignatureHelp?
    var isBusy = false
    var isVisible: Bool { isBusy || message != nil || !locations.isEmpty || !actions.isEmpty || !symbols.isEmpty || renameText != nil }
}

final class ScriptSemanticSession: _ObservableObject, @unchecked Sendable {
    private let publisher = _ObservablePublisher<ScriptSemanticSession>()
    let app: EditorApplication
    private(set) var revision: UInt64 = 0
    private(set) var presentation = ScriptSemanticPresentation()
    private(set) var externalDocument: ScriptSemanticExternalDocument?
    private(set) var navigation = ScriptSemanticNavigation()
    private var caret = TextFieldCaretState.initial
    private var requestID = UUID()
    private var requestTask: Task<Void, Never>?
    private var signatureTask: Task<Void, Never>?

    init(app: EditorApplication) { self.app = app }

    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
    private func publish() { revision &+= 1; publisher.send() }

    var canQuery: Bool { externalDocument == nil && app.workstation.scripts.snapshot.languageServiceState == .ready }

    func canPerform(_ command: ScriptSemanticCommand) -> Bool {
        switch command {
        case .back: return !navigation.previous.isEmpty || externalDocument != nil
        case .forward: return !navigation.next.isEmpty
        case .undo: return app.workstation.scripts.canUndoLanguageEdit
        case .redo: return app.workstation.scripts.canRedoLanguageEdit
        default: return canQuery
        }
    }

    func handleKey(_ event: KeyEvent) -> Bool {
        guard let command = ScriptSemanticCommand.matching(event), canPerform(command) else { return false }
        perform(command)
        return true
    }

    func dismiss() {
        requestTask?.cancel(); requestID = UUID()
        presentation = .init(); publish()
    }

    func sourceChanged() {
        requestTask?.cancel(); signatureTask?.cancel(); requestID = UUID()
        presentation = .init(); publish()
    }

    func selectedProjectDocument() {
        externalDocument = nil
        caret = .initial
        dismiss()
    }

    func updateCaret(_ state: TextFieldCaretState) {
        caret = state
        signatureTask?.cancel()
        guard canQuery, state.selectedRange == nil,
              let document = app.workstation.scripts.snapshot.selectedDocument else { return }
        let start = max(0, state.caretIndex - 300)
        let prefix = document.source.substring(characterRange: start..<min(document.source.characterCount, state.caretIndex))
        guard let opening = prefix.lastIndex(of: "("),
              prefix[opening...].filter({ $0 == "(" }).count > prefix[opening...].filter({ $0 == ")" }).count else {
            if presentation.signature != nil { presentation.signature = nil; publish() }
            return
        }
        let position = ScriptSourceCoordinates.position(in: document.source, atCharacterIndex: state.caretIndex)
        signatureTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
                guard let self else { return }
                let signature = try await self.app.dynamicScriptManager.signatureHelp(scriptID: document.file.identifier, at: position)
                guard !Task.isCancelled, self.app.workstation.scripts.snapshot.selectedDocument?.source == document.source,
                      self.caret == state else { return }
                self.presentation.signature = signature; self.publish()
            } catch {}
        }
    }

    func perform(_ command: ScriptSemanticCommand) {
        if command == .back { goBack(); return }
        if command == .forward { goForward(); return }
        if command == .undo || command == .redo {
            do {
                if command == .undo { try app.workstation.scripts.undoLanguageEdit() }
                else { try app.workstation.scripts.redoLanguageEdit() }
            } catch { show(error) }
            return
        }
        guard canQuery, let document = app.workstation.scripts.snapshot.selectedDocument else { return }
        requestTask?.cancel()
        let token = UUID(); requestID = token
        presentation = ScriptSemanticPresentation(title: command.title, isBusy: true)
        publish()
        let position = ScriptSourceCoordinates.position(in: document.source, atCharacterIndex: caret.caretIndex)
        let selection = caret.selectedRange ?? caret.caretIndex..<caret.caretIndex
        let span = ScriptLanguageSpan(start: ScriptSourceCoordinates.position(in: document.source, atCharacterIndex: selection.lowerBound),
                                      end: ScriptSourceCoordinates.position(in: document.source, atCharacterIndex: selection.upperBound))
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let manager = self.app.dynamicScriptManager
                switch command {
                case .definition, .implementations, .supertypes, .references:
                    let id = document.file.identifier
                    let locations = switch command {
                    case .definition: try await manager.definition(scriptID: id, at: position)
                    case .implementations: try await manager.implementations(scriptID: id, at: position)
                    case .supertypes: try await manager.supertypes(scriptID: id, at: position)
                    default: try await manager.references(scriptID: id, at: position)
                    }
                    guard self.isCurrent(token, document: document) else { return }
                    self.presentation.locations = locations
                    if command != .references, locations.count == 1 { self.open(locations[0]) }
                    else if locations.isEmpty { self.presentation.message = L("No results") }
                case .rename:
                    let preparation = try await manager.prepareRename(scriptID: document.file.identifier, at: position)
                    guard self.isCurrent(token, document: document) else { return }
                    if let preparation {
                        self.presentation.renameText = TextBuffer(preparation.placeholder ?? document.source.substring(characterRange:
                            ScriptSourceCoordinates.characterIndex(in: document.source, at: preparation.range.start)..<ScriptSourceCoordinates.characterIndex(in: document.source, at: preparation.range.end)))
                    } else { self.presentation.message = L("This symbol cannot be renamed") }
                case .codeActions:
                    let actions = try await manager.codeActions(scriptID: document.file.identifier, range: span)
                    guard self.isCurrent(token, document: document) else { return }
                    self.presentation.actions = actions
                    if actions.isEmpty { self.presentation.message = L("No code actions available") }
                case .signature:
                    let signature = try await manager.signatureHelp(scriptID: document.file.identifier, at: position)
                    guard self.isCurrent(token, document: document) else { return }
                    self.presentation.signature = signature
                    if signature == nil { self.presentation.message = L("No parameter hints available") }
                case .symbols:
                    let symbols = try await manager.documentSymbols(scriptID: document.file.identifier)
                    guard self.isCurrent(token, document: document) else { return }
                    self.presentation.symbols = symbols
                    if symbols.isEmpty { self.presentation.message = L("No symbols found") }
                case .format:
                    let edit = try await manager.formatting(scriptID: document.file.identifier, range: selection.isEmpty ? nil : span)
                    guard self.isCurrent(token, document: document) else { return }
                    try self.app.workstation.scripts.applyLanguageEdit(edit)
                    self.presentation.message = L("Document formatted")
                case .back, .forward, .undo, .redo: break
                }
                guard self.requestID == token else { return }
                self.presentation.isBusy = false; self.publish()
            } catch {
                guard self.requestID == token else { return }
                self.show(error)
            }
        }
    }

    private func isCurrent(_ token: UUID, document: ScriptWorkspaceDocument) -> Bool {
        !Task.isCancelled && requestID == token && app.workstation.scripts.snapshot.selectedScriptID == document.file.identifier
            && app.workstation.scripts.snapshot.selectedDocument?.source == document.source
    }

    func updateRename(_ text: TextBuffer) { presentation.renameText = text; publish() }

    func confirmRename() {
        guard let newName = presentation.renameText?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !newName.isEmpty,
              let document = app.workstation.scripts.snapshot.selectedDocument else { return }
        let position = ScriptSourceCoordinates.position(in: document.source, atCharacterIndex: caret.caretIndex)
        let token = requestID
        presentation.isBusy = true; publish()
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let edit = try await self.app.dynamicScriptManager.rename(scriptID: document.file.identifier, at: position, newName: newName)
                guard self.isCurrent(token, document: document) else { return }
                try self.app.workstation.scripts.applyLanguageEdit(edit)
                self.dismiss()
            } catch { if self.requestID == token { self.show(error) } }
        }
    }

    func apply(_ action: ScriptCodeAction) {
        guard action.disabledReason == nil, let document = app.workstation.scripts.snapshot.selectedDocument else { return }
        let token = requestID
        presentation.isBusy = true; publish()
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resolved = action.needsResolution ? try await self.app.dynamicScriptManager.resolveCodeAction(action) : action
                guard self.isCurrent(token, document: document) else { return }
                if let edit = try Self.applicableEdit(resolved) {
                    try self.app.workstation.scripts.applyLanguageEdit(edit); self.dismiss()
                } else { self.presentation.message = L("This action has no applicable edits"); self.presentation.isBusy = false; self.publish() }
            } catch { if self.requestID == token { self.show(error) } }
        }
    }

    static func applicableEdit(_ action: ScriptCodeAction) throws -> ScriptWorkspaceEdit? {
        if let reason = action.disabledReason { throw ScriptLanguageEditError.disabledAction(reason) }
        return action.edit
    }

    func open(_ location: ScriptDefinitionLocation) {
        guard let current = currentLocation else { return }
        requestTask?.cancel()
        let token = UUID(); requestID = token
        presentation = .init(title: ScriptSemanticCommand.definition.title, isBusy: true)
        publish()
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.navigate(ScriptSemanticLocation(scriptID: location.scriptID, fileURL: URL(string: location.documentURI), position: location.span.start))
                guard self.requestID == token else { return }
                self.navigation.record(current)
                self.presentation = .init(); self.publish()
            } catch { if self.requestID == token { self.show(error) } }
        }
    }

    /// Results found elsewhere (a gutter marker): one target opens at once,
    /// several are listed like Find References.
    func show(_ locations: [ScriptDefinitionLocation], title: String) {
        if locations.count == 1 { open(locations[0]); return }
        requestTask?.cancel(); requestID = UUID()
        presentation = ScriptSemanticPresentation(title: title, locations: locations)
        if locations.isEmpty { presentation.message = L("No results") }
        publish()
    }

    func open(_ symbol: ScriptDocumentSymbol) {
        guard let id = app.workstation.scripts.snapshot.selectedScriptID else { return }
        open(ScriptDefinitionLocation(documentURI: "", scriptID: id, span: symbol.selectionRange))
    }

    private var currentLocation: ScriptSemanticLocation? {
        if let externalDocument {
            return ScriptSemanticLocation(scriptID: nil, fileURL: externalDocument.url,
                position: ScriptSourceCoordinates.position(in: externalDocument.source, atCharacterIndex: caret.caretIndex))
        }
        guard let document = app.workstation.scripts.snapshot.selectedDocument else { return nil }
        return ScriptSemanticLocation(scriptID: document.file.identifier, fileURL: document.file.url,
            position: ScriptSourceCoordinates.position(in: document.source, atCharacterIndex: caret.caretIndex))
    }

    @MainActor
    private func navigate(_ location: ScriptSemanticLocation) async throws {
        if let id = location.scriptID {
            guard app.workstation.scripts.select(scriptID: id) else { throw CocoaError(.fileWriteUnknown) }
            externalDocument = nil
            app.navigateToIssue(.script(id: id, line: location.position.line, column: location.position.character))
        } else if let url = location.fileURL {
            let source: String
            if url.isFileURL {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard let size = attributes[.size] as? NSNumber, size.intValue <= 16 * 1024 * 1024 else {
                    throw CocoaError(.fileReadTooLarge)
                }
                source = try String(contentsOf: url, encoding: .utf8)
            } else if let content = try await app.dynamicScriptManager.referenceDocument(documentURI: url.absoluteString) {
                source = content
            } else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            try Task.checkCancellation()
            externalDocument = ScriptSemanticExternalDocument(url: url, source: TextBuffer(source),
                navigation: EditorScriptNavigationRequest(scriptID: url.absoluteString, line: location.position.line, column: location.position.character))
        } else { throw CocoaError(.fileReadUnsupportedScheme) }
        caret = .initial
    }

    private func goBack() {
        guard let previous = navigation.back(from: currentLocation) else { externalDocument = nil; dismiss(); return }
        travel(to: previous)
    }

    private func goForward() {
        guard let next = navigation.forward(from: currentLocation) else { return }
        travel(to: next)
    }

    private func travel(to previous: ScriptSemanticLocation) {
        requestTask?.cancel()
        let token = UUID(); requestID = token
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.navigate(previous)
                guard self.requestID == token else { return }
                self.dismiss()
            } catch { if self.requestID == token { self.show(error) } }
        }
    }

    private func show(_ error: Error) {
        presentation.isBusy = false; presentation.message = error.localizedDescription; publish()
    }
}
