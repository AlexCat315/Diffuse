import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
#if canImport(AppKit)
import AppKit
#endif

/// A panel for creating, editing, compiling, and hot-reloading Swift scripts.
///
/// Layout:
/// ```
/// ┌──────────────────────────────────────────────────┐
/// │ Toolbar: [New] [Save] [Compile]  status indicator │
/// ├──────────┬───────────────────────────────────────┤
/// │ Scripts  │  Code editor (NSTextView)             │
/// │ list     │                                       │
/// │          │                                       │
/// ├──────────┴───────────────────────────────────────┤
/// │ Compilation output / errors                      │
/// └──────────────────────────────────────────────────┘
/// ```
struct ScriptPanel: View {
    let app: EditorApplication

    @State private var scriptFiles: [DynamicScriptManager.ScriptFile] = []
    @State private var selectedScriptID: String? = nil
    @State private var sourceText: String = ""
    @State private var isDirty: Bool = false
    @State private var status: DynamicScriptManager.CompilationStatus = .idle
    @State private var outputText: String = ""
    @State private var isCompiling: Bool = false

    init(app: EditorApplication) {
        self.app = app
        _scriptFiles = State(wrappedValue: (try? app.dynamicScriptManager.scanScriptFiles()) ?? [])
    }

    var body: some View {
        Box(direction: .column, alignItems: .stretch, spacing: 0) {
            toolbar
            Divider()
            splitContent
            if !outputText.isEmpty || status.isFailed {
                Divider()
                outputArea
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        EditorPanelToolbar {
            Button(action: newScript) {
                Text(L("New"))
            }
            .buttonStyle(GhostButtonStyle())

            Button(isEnabled: selectedScript != nil && isDirty,
                   action: save) {
                Text(L("Save"))
            }
            .buttonStyle(GhostButtonStyle())

            Button(isEnabled: selectedScript != nil && !isCompiling,
                   action: compile) {
                Text(isCompiling ? L("Compiling…") : L("Compile"))
            }
            .buttonStyle(GhostButtonStyle())

            Spacer(minLength: 0)

            statusIndicator
        }
    }

    private var statusIndicator: some View {
        let (label, color): (String, SemanticColorRef) = switch status {
        case .idle: (L("Ready"), .onSurfaceMuted)
        case .compiling: (L("Compiling"), .accent)
        case .succeeded: (L("Compiled"), .success)
        case .failed: (L("Error"), .error)
        }
        return Row(alignment: .center, spacing: 6) {
            Box { EmptyView() }
                .frame(width: 6, height: 6)
                .background(color)
                .cornerRadius(3)
            Text(label)
                .font(.caption)
                .foregroundColor(color)
        }
    }

    // MARK: - Split content

    private var splitContent: some View {
        Box(direction: .row, alignItems: .stretch, spacing: 0) {
            scriptList
                .frame(width: 200)
            Divider()
            codeEditor
        }
        .flex(1, shrink: 1)
    }

    private var scriptList: some View {
        ScrollView(.vertical) {
            if scriptFiles.isEmpty {
                Text(L("No scripts yet"))
                    .font(.caption)
                    .foregroundColor(.onSurfaceMuted)
                    .padding(10)
            } else {
                Column(alignment: .leading, spacing: 2) {
                    for file in scriptFiles {
                        ScriptFileRow(
                            file: file,
                            isSelected: file.identifier == selectedScriptID,
                            statusColor: statusColor(for: file.identifier),
                            action: { select(file) }
                        )
                    }
                }
                .padding(6)
            }
        }
        .background(.surfaceSunken)
    }

    private func statusColor(for scriptID: String) -> SemanticColorRef {
        switch status {
        case .succeeded: return .success
        case .failed: return .error
        case .compiling: return .accent
        case .idle: return .onSurfaceMuted
        }
    }

    private var codeEditor: some View {
        Box {
            if let selectedScript {
                CodeEditor(text: $sourceText)
                    .flex(1, shrink: 1)
            } else {
                EditorPanelEmptyState(
                    L("No script selected"),
                    detail: L("Select or create a Swift script to edit.")
                )
                .flex()
            }
        }
    }

    private var outputArea: some View {
        ScrollView(.vertical) {
            Text(outputText)
                .font(.caption)
                .foregroundColor(status.isFailed ? .error : .onSurfaceMuted)
                .padding(10)
                .frame(maxWidth: .infinity)
        }
        .background(.surfaceSunken)
        .frame(maxHeight: 120)
    }

    // MARK: - Actions

    private var selectedScript: DynamicScriptManager.ScriptFile? {
        scriptFiles.first { $0.identifier == selectedScriptID }
    }

    private func refresh() {
        do {
            scriptFiles = try app.dynamicScriptManager.scanScriptFiles()
        } catch {
            outputText = L("Failed to scan scripts: \(error.localizedDescription)")
        }
    }

    private func select(_ file: DynamicScriptManager.ScriptFile) {
        // Save current if dirty
        if isDirty, let current = selectedScript {
            try? app.dynamicScriptManager.writeSource(sourceText, at: current.url)
        }
        selectedScriptID = file.identifier
        do {
            sourceText = try app.dynamicScriptManager.readSource(at: file.url)
            isDirty = false
            status = .idle
            outputText = status.message ?? ""
        } catch {
            outputText = L("Failed to read script: \(error.localizedDescription)")
        }
    }

    private func newScript() {
        let name = "NewScript"
        let source = ScriptTemplate.default
        do {
            let url = try app.dynamicScriptManager.createScript(name: name, source: source)
            refresh()
            if let file = scriptFiles.first(where: { $0.url == url }) {
                select(file)
            }
        } catch {
            outputText = L("Failed to create script: \(error.localizedDescription)")
        }
    }

    private func save() {
        guard let file = selectedScript else { return }
        do {
            try app.dynamicScriptManager.writeSource(sourceText, at: file.url)
            isDirty = false
            outputText = L("Saved \(file.displayName).swift")
        } catch {
            outputText = L("Failed to save: \(error.localizedDescription)")
        }
    }

    private func compile() {
        guard let file = selectedScript else { return }
        // Auto-save before compiling
        if isDirty {
            do {
                try app.dynamicScriptManager.writeSource(sourceText, at: file.url)
                isDirty = false
            } catch {
                outputText = L("Failed to save before compile: \(error.localizedDescription)")
                return
            }
        }
        isCompiling = true
        status = .compiling
        outputText = L("Compiling \(file.displayName).swift…")

        app.dynamicScriptManager.compileAndLoad(
            scriptID: file.identifier,
            sourceURL: file.url
        ) { result in
            isCompiling = false
            status = result
            switch result {
            case .succeeded:
                app.scene.registerDynamicScriptOption(identifier: file.identifier,
                                                     displayName: file.displayName)
                app.store.dispatch(.forceUIRefresh)
                outputText = L("Compiled and registered \(file.identifier)")
            case .failed(let message):
                outputText = message
            case .compiling, .idle:
                break
            }
        }
    }
}

private struct ScriptFileRow: View {
    let file: DynamicScriptManager.ScriptFile
    let isSelected: Bool
    let statusColor: SemanticColorRef
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Row(alignment: .center, spacing: 6) {
                Box { EmptyView() }
                    .frame(width: 6, height: 6)
                    .background(statusColor)
                    .cornerRadius(3)
                Text(file.displayName, lineLimit: 1)
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .padding(horizontal: 6, vertical: 4)
            .background(isSelected ? .accent.opacity(0.15) : SemanticColorRef { _ in .clear })
            .cornerRadius(3)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Code editor (NSTextView wrapper)

#if canImport(AppKit)
private struct CodeEditor: View {
    let text: Binding<String>

    var body: some View {
        CodeEditorRepresentable(text: text)
    }
}

private struct CodeEditorRepresentable: _PrimitiveView {
    let text: Binding<String>

    func _makeNode() -> Node {
        let node = Node()
        let textView = NSTextView()
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = text.wrappedValue
        let delegate = CodeEditorDelegate()
        delegate.onChange = { [weak node] newValue in
            // Store the pending change; _updateNode will flush it to the binding.
            node?.attachments["pendingText"] = newValue
        }
        textView.delegate = delegate
        node.attachments["textView"] = textView
        node.attachments["delegate"] = delegate
        return node
    }

    func _updateNode(_ node: Node) {
        guard let textView = node.attachments["textView"] as? NSTextView else { return }
        // Push external changes into the text view only when they differ from
        // the current contents, so we don't clobber what the user is typing.
        if let pending = node.attachments["pendingText"] as? String {
            text.wrappedValue = pending
            node.attachments["pendingText"] = nil
        } else if textView.string != text.wrappedValue {
            textView.string = text.wrappedValue
        }
    }

    func _makeLayoutNode() -> LayoutNode? {
        LayoutNode()
    }
}

private final class CodeEditorDelegate: NSObject, NSTextViewDelegate {
    var onChange: ((String) -> Void)?
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        onChange?(textView.string)
    }
}
#else
private struct CodeEditor: View {
    let text: Binding<String>
    var body: some View {
        ScrollView {
            Text(text.wrappedValue)
                .font(.caption)
                .padding(10)
                .frame(maxWidth: .infinity)
        }
    }
}
#endif

// MARK: - Script templates

enum ScriptTemplate {
    static let `default` = #"""
import SceneRuntime
import SIMDCompat

// C ABI declarations (imported from the host engine)
@_silgen_name("guava_input_axis")
func guavaInputAxis(_ name: UnsafePointer<CChar>) -> Float
@_silgen_name("guava_input_just_pressed")
func guavaInputJustPressed(_ name: UnsafePointer<CChar>) -> Bool
@_silgen_name("guava_submit_character_command")
func guavaSubmitCharacterCommand(_ vx: Float, _ vy: Float, _ vz: Float,
                                  _ jump: Bool, _ jumpSpeed: Float, _ stance: UInt8)

func axis(_ name: String) -> Float {
    name.withCString { guavaInputAxis($0) }
}
func justPressed(_ name: String) -> Bool {
    name.withCString { guavaInputJustPressed($0) }
}

@_cdecl("guavaCreateScript")
public func guavaCreateScript(_ out: UnsafeMutableRawPointer) {
    let script = Script().onPrePhysics { _ in
        let speed: Float = 5
        let jumpSpeed: Float = 8
        var dir = SIMD3<Float>(axis("move_x"), 0, -axis("move_y"))
        if simd_length_squared(dir) > 0 { dir = simd_normalize(dir) }
        let wantsJump = justPressed("jump")
        guavaSubmitCharacterCommand(dir.x * speed, 0, dir.z * speed, wantsJump, jumpSpeed, 0)
    }
    out.assumingMemoryBound(to: Script.self).pointee = script
}
"""#
}
