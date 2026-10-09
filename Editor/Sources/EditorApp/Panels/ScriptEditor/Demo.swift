import Foundation
import EditorCore
import ScriptRuntime
import GuavaUIApp
import GuavaUICompose
import GuavaUIRuntime
import RHIWGPU
#if os(macOS)
import Darwin
#endif

/// A standalone host for the production editing surface and language client.
/// Its temporary project and preferences are independent of the user's project.
@MainActor
func runScriptEditorDemo(backendConfig: WGPUDeviceConfig) throws {
    // A profiling run can retain the existing runtime FPS output when launched
    // as a native .app, whose output would otherwise belong to LaunchServices.
    #if os(macOS)
    if let path = ProcessInfo.processInfo.environment["GUAVA_SCRIPT_EDITOR_DEMO_LOG_PATH"], let file = fopen(path, "a") {
        _ = dup2(fileno(file), STDOUT_FILENO); _ = dup2(fileno(file), STDERR_FILENO); fclose(file)
    }
    #endif
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GuavaScriptEditorDemo-\(UUID().uuidString)", isDirectory: true)
    let session = try ScriptEditorDemoSession(directory: root)
    let oldStore = AppStorageDefaults.store; AppStorageDefaults.store = MemoryAppStorageStore()
    defer {
        session.shutdown(); AppStorageDefaults.store = oldStore
        try? FileManager.default.removeItem(at: root)
    }
    try AppRuntime.run(config: AppConfig(title: "Guava — Swift Code Editor", backendConfig: backendConfig,
        frameDrivePolicy: .eventDriven, vsyncPresentMode: .fifo)) {
            ScriptEditorDemoView(session: session)
        }
}

/// All mutable state is UI-owned; asynchronous replies are checked against the
/// immutable source root before publishing. The workspace supplies real LSP
/// diagnostics, incremental didChange and file identity.
private final class ScriptEditorDemoSession: _ObservableObject, @unchecked Sendable {
    private let publisher = _ObservablePublisher<ScriptEditorDemoSession>()
    let manager: DynamicScriptManager
    let workspace: ScriptWorkspaceModel
    let history = TextEditHistory()
    private let hoverSequence = ScriptEditorHoverSequence()
    private var workspaceToken: AnyHashable?
    private(set) var revision: UInt64 = 0
    private(set) var navigation: EditorScriptNavigationRequest?
    var hover = ScriptEditorHoverPresentation.hidden { didSet { if hover != oldValue { publish() } } }
    var caretLabel = "Ln 1, Col 1" { didSet { if caretLabel != oldValue { publish() } } }
    static let sample = """
        import Foundation

        /// Greets a person by name.
        func greet(name: String) -> String {
            return "Hello, \\(name)"
        }

        let count: Int = "Change me to an integer"
        let message = greet(name: "Guava")
        let upper = message.
        """
    init(directory: URL) throws {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let build = ProjectScriptBuildConfiguration.discover(for: executable)
        manager = DynamicScriptManager(projectDirectory: directory.path, scriptRuntime: ScriptRuntime(),
            engineModulePaths: build.engineModulePaths, clangModuleMapPaths: build.clangModuleMapPaths,
            clangIncludePaths: build.clangIncludePaths, scriptTrustStorageURL: directory.appendingPathComponent("trust.json"),
            swiftCompilerPath: build.swiftCompilerPath)
        _ = try manager.createScript(name: "EditorDemo", source: Self.sample)
        workspace = try ScriptWorkspaceModel(manager: manager)
        workspaceToken = workspace._registerObserver { [weak self] in self?.publish() }
        workspace.startLanguageService()
    }
    var source: TextBuffer { workspace.snapshot.selectedDocument?.source ?? .empty }
    var sourceBinding: Binding<TextBuffer> {
        Binding(get: { self.source }, set: { self.cancelHover(); self.workspace.updateSelectedSource($0) })
    }
    var diagnostics: [ScriptLanguageDiagnostic] { workspace.snapshot.selectedDocument?.diagnostics ?? [] }
    var serviceLabel: String {
        switch workspace.snapshot.languageServiceState {
        case .inactive: "LSP inactive"
        case .starting: "Starting SourceKit-LSP…"
        case .ready: "SourceKit-LSP ready"
        case .unavailable(let message): "LSP unavailable: \(message)"
        }
    }
    func navigate(line: Int, column: Int = 0) {
        guard let id = workspace.snapshot.selectedScriptID else { return }
        navigation = EditorScriptNavigationRequest(scriptID: id, line: line, column: column); publish()
    }
    func resetSample() { cancelHover(); workspace.updateSelectedSource(TextBuffer(Self.sample)); navigate(line: 0) }
    func loadLarge() {
        cancelHover()
        let text = (0..<200_000).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        workspace.updateSelectedSource(TextBuffer(text)); navigate(line: 100_000, column: 23)
    }
    func completionProvider() -> TextCompletionProvider {
        { [weak self] request, reply in
            Task { @MainActor [weak self] in
                guard let self, let id = self.workspace.snapshot.selectedScriptID else { reply([]); return }
                let position = ScriptSourceCoordinates.position(in: request.buffer, atCharacterIndex: request.caretIndex)
                let result: ScriptCompletionResult
                do { result = try await self.manager.completion(scriptID: id, at: position) }
                catch { reply([]); return }
                guard self.source == request.buffer else { return }
                reply(ScriptCompletionConversion.items(result, for: request))
            }
        }
    }
    func requestHover(_ anchor: TextFieldHoverAnchor) {
        guard workspace.snapshot.languageServiceState == .ready, let id = workspace.snapshot.selectedScriptID,
              ScriptEditorHoverResolver.queryPosition(in: source, characterIndex: anchor.characterIndex) != nil else { cancelHover(); return }
        let buffer = source, sequence = hoverSequence, manager = manager
        let window = ScriptEditorHoverAnchor(windowX: anchor.windowX, windowY: anchor.windowY)
        hover = ScriptEditorHoverPresentation(anchor: window, isPending: true)
        Task { @MainActor [weak self] in
            guard let presentation = await ScriptEditorHoverResolver.resolve(scriptID: id, source: buffer,
                characterIndex: anchor.characterIndex, anchor: window, sequence: sequence,
                request: { try await manager.hover(scriptID: id, at: $0) }), let self, self.source == buffer else { return }
            self.hover = presentation
        }
    }
    func cancelHover() { hoverSequence.invalidateAll(); hover = .hidden }
    func shutdown() {
        cancelHover(); if let workspaceToken { workspace._unregisterObserver(workspaceToken) }
        workspaceToken = nil; workspace.shutdown()
    }
    private func publish() { revision &+= 1; publisher.send() }
    func _registerObserver(_ handler: @escaping () -> Void) -> AnyHashable { publisher.register(on: self, handler: handler) }
    func _unregisterObserver(_ token: AnyHashable) { publisher.unregister(token) }
}

private struct ScriptEditorDemoView: View {
    let session: ScriptEditorDemoSession
    private var revision: Observed<ScriptEditorDemoSession, UInt64>
    @State private var appearance: Appearance = .dark
    init(session: ScriptEditorDemoSession) { self.session = session; revision = Observed(\.revision, on: session) }
    var body: some View {
        let _ = revision.wrappedValue
        return LayerRoot {
            Box(direction: .column, alignItems: .stretch, spacing: 0) {
                Row(alignment: .center, spacing: 10) {
                    Text("Swift Code Editor").font(.bodyStrong)
                    Button("Reset sample", action: session.resetSample).buttonStyle(.secondary)
                    Button("Load 200,000 lines", action: session.loadLarge).buttonStyle(.secondary)
                    Button("Middle") { session.navigate(line: session.source.lineCount / 2, column: 23) }.buttonStyle(.ghost)
                    Button("Completion") {
                        let buffer = session.source, line = buffer.lineCount - 1
                        let range = buffer.lineRange(forLine: line)
                        session.navigate(line: line, column: buffer.utf16Offset(forCharacterIndex: range.upperBound) - buffer.utf16Offset(forCharacterIndex: range.lowerBound))
                    }.buttonStyle(.ghost)
                    Spacer()
                    Button(appearance == .dark ? "Light" : "Dark") { appearance = appearance == .dark ? .light : .dark }.buttonStyle(.ghost)
                }.padding(12).flex(0, shrink: 0)
                Divider()
                ScriptCodeEditor(source: session.sourceBinding,
                    hover: Binding(get: { session.hover }, set: { session.hover = $0 }),
                    caretLabel: Binding(get: { session.caretLabel }, set: { session.caretLabel = $0 }),
                    onChange: { _ in }, diagnostics: session.diagnostics, completionProvider: session.completionProvider(),
                    editHistory: session.history, navigation: session.navigation,
                    onHover: session.requestHover, onHoverEnd: session.cancelHover)
                    .flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0)
                Divider()
                Row(spacing: 16) {
                    Text(session.serviceLabel).font(.caption)
                    if case .unavailable = session.workspace.snapshot.languageServiceState {
                        Button("Retry LSP", action: session.workspace.retryLanguageService).buttonStyle(.secondary)
                    }
                    Text("\(session.source.lineCount.formatted()) lines · \(session.diagnostics.count) diagnostics").font(.caption)
                    Spacer()
                    Text("Ctrl+Space: complete · F1: hover").font(.caption).foregroundColor(.onSurfaceMuted)
                    Text(session.caretLabel).font(.caption)
                }.padding(horizontal: 12, vertical: 8).flex(0, shrink: 0)
                if let diagnostic = session.diagnostics.first {
                    Text(diagnostic.message, lineLimit: 2).font(.caption).foregroundColor(.error)
                        .padding(horizontal: 12, vertical: 4).flex(0, shrink: 0)
                }
            }.flex(1, shrink: 1, basis: 0).frame(minWidth: 0, minHeight: 0).background(.background)
        }.appearance(appearance)
    }
}
