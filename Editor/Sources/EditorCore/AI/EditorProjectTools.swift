import AIRuntime
import CapabilityRuntime
import Foundation
import ScriptRuntime

public struct EditorProjectToolError: Error, LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

private final class ProjectCompileReport: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [[String: Any]] = []

    func append(_ file: DynamicScriptManager.ScriptFile, _ status: DynamicScriptManager.CompilationStatus) {
        let message: String
        let succeeded: Bool
        switch status {
        case .succeeded: succeeded = true; message = "compiled and loaded"
        case let .failed(detail), let .blocked(detail): succeeded = false; message = detail
        case .cancelled: succeeded = false; message = "cancelled"
        default: succeeded = false; message = "not compiled"
        }
        lock.lock()
        defer { lock.unlock() }
        results.append(["filename": file.url.lastPathComponent, "identifier": file.identifier,
                        "ok": succeeded, "diagnostics": String(message.suffix(16_384))])
    }

    func data() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try JSONSerialization.data(withJSONObject: [
            "ok": results.allSatisfy { $0["ok"] as? Bool == true }, "scripts": results,
        ], options: [.sortedKeys])
    }
}

extension EditorApplication {
    func makeProjectToolExecutor() -> ProjectToolset.Executor {
        { [weak self] name, input in
            guard let self else { throw EditorProjectToolError("Editor is unavailable.") }
            return try await self.executeProjectTool(name: name, input: input)
        }
    }

    /// Shared implementation for the built-in assistant and the stdio MCP server.
    /// It exposes no shell, credentials, project trust override or arbitrary path.
    @MainActor
    public func executeProjectTool(name: String, input: Data) async throws -> Data {
        guard let definition = ProjectToolset.tools.first(where: { $0.name == name }) else {
            throw EditorProjectToolError("Unknown project tool: \(name)")
        }
        let task = agentTaskService.activeTask
        let profile = (task?.target.workspace ?? store.workspaceMode).profile
        guard profile.projectToolNames.contains(name) else {
            throw EditorProjectToolError("This tool is unavailable in the active authoring workflow.")
        }
        if !definition.readOnly, let target = task?.target { try validateAgentTaskTarget(target) }
        try JSONSchemaValidator.validate(data: input, against: definition.schema)
        let args = (try JSONSerialization.jsonObject(with: input) as? [String: Any] ?? [:])
            .filter { !($0.value is NSNull) }
        if !definition.readOnly {
            guard store.state.assistant.pendingConfirmationRequest == nil else {
                throw EditorProjectToolError(EditorAIRequestPolicy.pendingConfirmationMessage)
            }
            if name != "set_playback_state", store.state.timing.playbackState != .stopped {
                throw EditorProjectToolError("Stop simulation before changing project files or outputs.")
            }
            guard !projectToolBuildInProgress else {
                throw EditorProjectToolError("Wait for the current script compilation to finish.")
            }
        }

        var result: [String: Any] = ["ok": true]
        switch name {
        case "get_project_info":
            result.merge([
                "project_directory": projectDirectory,
                "scene_revision": scene.revision,
                "entity_count": scene.manifest().entityCount,
                "playback_state": store.state.timing.playbackState.rawValue,
                "pending_confirmation": store.state.assistant.pendingConfirmationRequest != nil,
                "script_build_in_progress": projectToolBuildInProgress,
                "script_execution_trusted": dynamicScriptManager.projectTrustState.allowsExecution,
                "ai_provider": store.state.assistant.aiSettings.provider.rawValue,
                "ai_credential_available": AIKeychain.hasKey(for: store.state.assistant.aiSettings.provider),
                "script_sdk_available": !ProjectScriptBuildConfiguration.discover(
                    for: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                ).engineModulePaths.isEmpty,
            ]) { _, new in new }
        case "get_scripting_api":
            result["documentation"] = Self.gameplayScriptingAPI
        case "get_runtime_state":
            let debug = scene.scene.resource(ScriptDebugState.self) ?? ScriptDebugState()
            result["entity_count"] = scene.scene.snapshot.entityCount
            let rendered = engine.currentRenderStats()
            result["render"] = ["frame_index": rendered.frameIndex,
                                "visible_mesh_instances": rendered.visibleMeshInstanceCount,
                                "draw_call_count": rendered.drawCallCount,
                                "viewport_valid": engine.currentViewportSurfaceState().isValid]
            result["unresolved_bindings"] = scene.unresolvedScriptBindingDescriptions(onlyEnabled: true)
            result["scripts"] = debug.entities.keys.sorted(by: { $0.rawValue < $1.rawValue })
                .filter { scene.scene.contains($0) }.prefix(100).map {
                    ["entity_id": "scene:\($0.rawValue)", "values": debug.entities[$0] ?? [:]] as [String: Any]
                }
        case "list_scripts":
            try validateProjectScriptsDirectory()
            result["scripts"] = try dynamicScriptManager.scanScriptFiles().map { file -> [String: Any] in
                let url = try projectScriptURL(filename: file.url.lastPathComponent)
                let document = scriptWorkspace.snapshot.documents.first { $0.file.identifier == file.identifier }
                return ["filename": url.lastPathComponent, "identifier": file.identifier,
                        "sha256": CapabilityDigest.sha256(try boundedScriptData(at: url)),
                        "unsaved_changes": document?.isDirty ?? false,
                        "diagnostics": String((document?.output ?? "").suffix(8192))]
            }
        case "read_script":
            let url = try projectScriptURL(filename: args["filename"] as? String ?? "")
            let data = try boundedScriptData(at: url)
            guard let source = String(data: data, encoding: .utf8) else {
                throw EditorProjectToolError("Script must contain UTF-8 source.")
            }
            result["filename"] = url.lastPathComponent
            result["source"] = source
            result["sha256"] = CapabilityDigest.sha256(data)
        case "write_script":
            let url = try projectScriptURL(filename: args["filename"] as? String ?? "")
            let source = args["source"] as? String ?? ""
            guard source.utf8.count <= 262_144 else { throw EditorProjectToolError("Source exceeds 256 KiB.") }
            if FileManager.default.fileExists(atPath: url.path) {
                guard scriptWorkspace.snapshot.documents.first(where: { ProjectFilePath.sameLocation($0.file.url, url) })?.isDirty != true else {
                    throw EditorProjectToolError("The editor has unsaved changes for \(url.lastPathComponent). Save or resolve them first.")
                }
                let current = CapabilityDigest.sha256(try boundedScriptData(at: url))
                guard args["expected_sha256"] as? String == current else {
                    throw EditorProjectToolError("Source changed or expected_sha256 is missing. Read the script again before replacing it.")
                }
                try dynamicScriptManager.writeSource(source, at: url)
                scriptWorkspace.refreshFromDisk()
            } else {
                guard args["expected_sha256"] == nil else { throw EditorProjectToolError("The expected source no longer exists.") }
                guard scriptWorkspace.createScript(name: url.deletingPathExtension().lastPathComponent, source: source) else {
                    throw EditorProjectToolError("Could not create script. Check editor diagnostics.")
                }
            }
            let file = try dynamicScriptManager.scriptFile(at: url)
            if let file { scene.registerDynamicScriptOption(identifier: file.identifier, displayName: file.displayName) }
            result["filename"] = url.lastPathComponent
            result["identifier"] = file?.identifier
            result["sha256"] = CapabilityDigest.sha256(Data(source.utf8))
            result["executed"] = false
            store.dispatch(.forceUIRefresh)
        case "compile_scripts":
            try validateProjectScriptsDirectory()
            guard dynamicScriptManager.projectTrustState.allowsExecution else {
                throw EditorProjectToolError(ScriptProjectTrustError.executionBlocked.localizedDescription)
            }
            guard !scriptWorkspace.snapshot.documents.contains(where: \.isDirty) else {
                throw EditorProjectToolError("Save unsaved script documents before compiling project files.")
            }
            projectToolBuildInProgress = true
            defer { projectToolBuildInProgress = false }
            let report = ProjectCompileReport()
            scriptWorkspace.markAllBuildsStarted()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    try dynamicScriptManager.compileAllScripts(onScriptCompletion: { [weak self] file, status in
                        report.append(file, status)
                        self?.scriptWorkspace.recordBuildResult(scriptID: file.identifier, status: status)
                        if case .succeeded = status {
                            self?.scene.registerDynamicScriptOption(identifier: file.identifier, displayName: file.displayName)
                        }
                    }, completion: { [weak self] in
                        self?.store.dispatch(.forceUIRefresh)
                        continuation.resume(with: Result { try report.data() })
                    })
                } catch { continuation.resume(throwing: error) }
            }
        case "save_scene":
            guard let url = saveSceneManifest() else { throw projectOutputError("Scene save failed.") }
            result["path"] = url.path
        case "export_project":
            guard let url = exportProject() else { throw projectOutputError("Project export failed.") }
            let descriptor = try ProjectExporter.readDescriptor(from: url)
            let executable = ProjectExporter.runnableExecutableURL(appName: descriptor.appName, in: url)
            result["path"] = url.path
            result["runnable"] = FileManager.default.isExecutableFile(atPath: executable.path)
            if result["runnable"] as? Bool == true { result["executable"] = executable.path }
        case "set_playback_state":
            guard let state = PlaybackState(rawValue: args["state"] as? String ?? "") else {
                throw EditorProjectToolError("Invalid playback state.")
            }
            applyPlaybackState(state)
            result["state"] = store.state.timing.playbackState.rawValue
        case "get_console_messages":
            result["messages"] = store.state.output.consoleEntries.suffix(args["limit"] as? Int ?? 20).map {
                ["severity": $0.severity.rawValue, "message": $0.message, "detail": String(($0.detail ?? "").suffix(8192))]
            }
        default: throw EditorProjectToolError("Unknown project tool: \(name)")
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    private func validateProjectScriptsDirectory() throws {
        let root = URL(fileURLWithPath: projectDirectory).resolvingSymlinksInPath().standardizedFileURL
        let scripts = dynamicScriptManager.scriptsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        guard ProjectFilePath.contains(scripts, in: root, includingRoot: false) else {
            throw EditorProjectToolError("Scripts directory escapes the project.")
        }
    }

    private func projectScriptURL(filename: String) throws -> URL {
        guard filename.range(of: "^[A-Za-z_][A-Za-z0-9_-]*\\.swift$", options: .regularExpression) != nil else {
            throw EditorProjectToolError("Use one top-level Swift filename without directories.")
        }
        try validateProjectScriptsDirectory()
        let scripts = dynamicScriptManager.scriptsDirectoryURL.resolvingSymlinksInPath().standardizedFileURL
        let url = scripts.appendingPathComponent(filename).resolvingSymlinksInPath().standardizedFileURL
        guard ProjectFilePath.sameLocation(url.deletingLastPathComponent(), scripts) else {
            throw EditorProjectToolError("Script escapes the project.")
        }
        return url
    }

    private func boundedScriptData(at url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard size.isRegularFile == true, (size.fileSize ?? Int.max) <= 262_144 else {
            throw EditorProjectToolError("Expected a regular Swift source file of at most 256 KiB.")
        }
        return try Data(contentsOf: url)
    }

    private func projectOutputError(_ fallback: String) -> EditorProjectToolError {
        EditorProjectToolError(store.state.output.consoleEntries.last(where: { $0.severity == .error })?.detail ?? fallback)
    }

    private static let gameplayScriptingAPI = """
    Each Scripts/*.swift file defines one GameScript: ScriptBehavior. Import Foundation, \
    SceneRuntime, ScriptRuntime, SIMDCompat and EngineKernel as needed. Lifecycle methods \
    are mutating onStart/onUpdate/onFixedUpdate/onLateUpdate/onDestroy(_ context: ScriptContext).
    Each entity binding has independent stored properties. Stable script identifiers are \
    returned by write_script/list_scripts; attach them using scene.set_script_property.
    context.entity, deltaTime (Double), floatParameter(_), stringParameter(_), input.
    context.createEntity(named:transform:) -> EntityID; context.destroyEntity(_).
    LocalTransform(translation: SIMD3<Float>, rotation: simd_quatf, scale: SIMD3<Float>).
    context.setComponent(Component, for: EntityID); component(Component.self, for: EntityID).
    context.setLocalTransform(LocalTransform, for: EntityID); localTransform(of: EntityID).
    RenderMeshComponent(meshIndex: 0, colorTint: SIMD3<Float>) renders a cube.
    CameraComponent(target: SIMD3<Float>) renders from its entity's transform translation.
    LightComponent(type: .directional, intensity: Float) adds a light to its entity.
    context.setResource(InputActionMap.guavaDefault); context.input.axis("move_x"/"move_y").
    InputActionMap.bind("restart", to: .key(Scancode.r)); input.isJustPressed("restart").
    context.setResource(custom Sendable resource); resource(Resource.self).
    context.drawUI { canvas in canvas.label("Score: 0", x: 24, y: 24, fontSize: 24) }.
    context.reportState(["score": "0", "phase": "playing"]) exposes values to get_runtime_state.
    canvas.rect(x:y:w:h:color:cornerRadius:), progressBar(x:y:w:h:value:maxValue:).
    Prefab.captureFull(from:root:) includes script bindings; context.instantiate(prefab).
    Source changes do not execute code. Compile only after the human trusts this project.
    Compile/export are for the host platform and need matching built Engine modules.
    """
}
