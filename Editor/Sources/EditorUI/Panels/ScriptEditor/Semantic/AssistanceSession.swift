internal import EditorCore
internal import Foundation
internal import GuavaUI
internal import GuavaUIRuntime

enum ScriptSemanticCommand: CaseIterable, Equatable {
    case definition, references, rename, codeActions, signature, symbols, format, back, undo, redo

    var title: String {
        switch self {
        case .definition: "Go to Definition"
        case .references: "Find References"
        case .rename: "Rename Symbol"
        case .codeActions: "Quick Fix / Code Actions"
        case .signature: "Parameter Hints"
        case .symbols: "Document Outline"
        case .format: "Format Document"
        case .back: "Go Back"
        case .undo: "Undo Workspace Edit"
        case .redo: "Redo Workspace Edit"
        }
    }

    static func matching(_ event: KeyEvent) -> Self? {
        let modifiers = event.modifiers
        let primary = !modifiers.isDisjoint(with: [.gui, .ctrl])
        let shift = modifiers.contains(.shift)
        let alt = modifiers.contains(.alt)
        if event.scancode == Scancode.f12, modifiers.isDisjoint(with: [.gui, .ctrl, .alt]) { return shift ? .references : .definition }
        if event.scancode == Scancode.f2, modifiers.isEmpty { return .rename }
        if primary, event.scancode == Scancode.period, !alt { return .codeActions }
        if primary, shift, event.scancode == Scancode.space { return .signature }
        if primary, shift, event.scancode == Scancode.o { return .symbols }
        if alt, shift, event.scancode == Scancode.f { return .format }
        if alt, !primary, event.scancode == Scancode.arrowLeft { return .back }
        if primary, event.scancode == Scancode.z { return shift ? .redo : .undo }
        return nil
    }
}

struct ScriptSemanticLocation: Equatable {
    let scriptID: String?
    let fileURL: URL?
    let position: ScriptLanguagePosition
}

struct ScriptSemanticNavigation {
    private(set) var previous: [ScriptSemanticLocation] = []

    mutating func record(_ location: ScriptSemanticLocation) {
        guard previous.last != location else { return }
        previous.append(location)
        if previous.count > 100 { previous.removeFirst() }
    }

    mutating func back() -> ScriptSemanticLocation? { previous.popLast() }
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
                case .definition, .references:
                    let locations = command == .definition
                        ? try await manager.definition(scriptID: document.file.identifier, at: position)
                        : try await manager.references(scriptID: document.file.identifier, at: position)
                    guard self.isCurrent(token, document: document) else { return }
                    self.presentation.locations = locations
                    if command == .definition, locations.count == 1 { self.open(locations[0]) }
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
                    let edit = try await manager.formatting(scriptID: document.file.identifier)
                    guard self.isCurrent(token, document: document) else { return }
                    try self.app.workstation.scripts.applyLanguageEdit(edit)
                    self.presentation.message = L("Document formatted")
                case .back, .undo, .redo: break
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
        guard let previous = navigation.back() else { externalDocument = nil; dismiss(); return }
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
