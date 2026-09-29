import EditorCore
import Foundation
import GuavaUICompose
import GuavaUIRuntime
#if canImport(AppKit)
import AppKit
#endif

/// A panel for managing, compiling, and hot-reloading Swift scripts.
///
/// Editing itself happens in the user's external editor (VS Code, Xcode, etc.);
/// this panel is responsible for listing scripts, kicking off compilation,
/// showing diagnostics, and registering hot-reloaded scripts with the runtime.
///
/// Layout:
/// ```
/// ┌──────────────────────────────────────────────────┐
/// │ Toolbar: [New] [Edit] [Reveal] [Compile]  status  │
/// ├──────────┬───────────────────────────────────────┤
/// │ Scripts  │  Script detail (name / path / status)  │
/// │ list     │                                       │
/// ├──────────┴───────────────────────────────────────┤
/// │ Compilation output / errors                      │
/// └──────────────────────────────────────────────────┘
/// ```
struct ScriptPanel: View {
    let app: EditorApplication

    @State private var scriptFiles: [DynamicScriptManager.ScriptFile] = []
    @State private var selectedScriptID: String? = nil
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

            Button(isEnabled: selectedScript != nil,
                   action: editInExternalEditor) {
                Text(L("Edit"))
            }
            .buttonStyle(GhostButtonStyle())

            Button(isEnabled: selectedScript != nil,
                   action: revealInFinder) {
                Text(L("Reveal"))
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
            detailPane
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

    private var detailPane: some View {
        Box {
            if let selectedScript {
                ScriptDetailView(
                    file: selectedScript,
                    status: status,
                    isCompiling: isCompiling,
                    onEdit: editInExternalEditor,
                    onReveal: revealInFinder,
                    onCompile: compile
                )
                .flex(1, shrink: 1)
            } else {
                EditorPanelEmptyState(
                    L("No script selected"),
                    detail: L("Select or create a Swift script to manage.")
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
        selectedScriptID = file.identifier
        status = .idle
        outputText = ""
    }

    private func newScript() {
        let baseName = "NewScript"
        let source = ScriptTemplate.default
        do {
            let url = try app.dynamicScriptManager.createScript(name: baseName, source: source)
            refresh()
            if let file = scriptFiles.first(where: { $0.url == url }) {
                select(file)
                openInExternalEditor(url: url)
            }
        } catch {
            outputText = L("Failed to create script: \(error.localizedDescription)")
        }
    }

    private func editInExternalEditor() {
        guard let file = selectedScript else { return }
        openInExternalEditor(url: file.url)
    }

    private func openInExternalEditor(url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #else
        outputText = L("Open this file in your editor: \(url.path)")
        #endif
    }

    private func revealInFinder() {
        guard let file = selectedScript else { return }
        #if canImport(AppKit)
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
        #else
        outputText = L("Script path: \(file.url.path)")
        #endif
    }

    private func compile() {
        guard let file = selectedScript else { return }
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
                Text(file.displayName)
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

// MARK: - Script detail

private struct ScriptDetailView: View {
    let file: DynamicScriptManager.ScriptFile
    let status: DynamicScriptManager.CompilationStatus
    let isCompiling: Bool
    let onEdit: () -> Void
    let onReveal: () -> Void
    let onCompile: () -> Void

    var body: some View {
        ScrollView(.vertical) {
            Column(alignment: .leading, spacing: 14) {
                infoSection
                actionSection
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
    }

    private var infoSection: some View {
        Column(alignment: .leading, spacing: 8) {
            Text(file.displayName)
                .font(.headline)
            infoRow(label: L("Identifier"), value: file.identifier)
            infoRow(label: L("Path"), value: file.url.path)
            infoRow(label: L("Status"), value: statusText)
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        Row(alignment: .center, spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundColor(.onSurfaceMuted)
                .frame(width: 80)
            Text(value)
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
    }

    private var statusText: String {
        switch status {
        case .idle: return L("Ready")
        case .compiling: return L("Compiling…")
        case .succeeded: return L("Compiled and registered")
        case .failed(let message): return L("Failed: \(message)")
        }
    }

    private var actionSection: some View {
        Row(alignment: .center, spacing: 8) {
            Button(action: onEdit) {
                Text(L("Edit in External Editor"))
            }
            .buttonStyle(GhostButtonStyle())

            Button(action: onReveal) {
                Text(L("Reveal in Finder"))
            }
            .buttonStyle(GhostButtonStyle())

            Button(isEnabled: !isCompiling, action: onCompile) {
                Text(isCompiling ? L("Compiling…") : L("Compile & Reload"))
            }
            .buttonStyle(GhostButtonStyle())
        }
    }
}

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
