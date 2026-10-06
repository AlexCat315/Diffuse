import AIRuntime
import ContextMemory
import AssetPipeline
import AudioRuntime
import CapabilityRuntime
import EngineCore
import EngineKernel
import IntentRuntime
import ObservationBus
import PerceptionRuntime
import PluginRuntime
import SemanticPipeline
import RenderBackend
import RHIWGPU
import SceneRuntime
import GuavaUICompose
import GuavaUIRuntime
import Foundation
import SIMDCompat

extension EditorApplication {
    // MARK: - Engine module path resolution

    /// Resolves the directories containing engine `.swiftmodule` files so that
    /// dynamically compiled scripts can `import SceneRuntime`, `import
    /// SIMDCompat`, etc.
    ///
    /// Resolution order:
    /// 1. `GUAVA_ENGINE_MODULE_PATHS` environment variable (comma-separated).
    /// 2. Derived from the executable's build directory:
    ///    `<build>/<platform>/<configuration>/Modules`.
    static func scriptBuildConfiguration() -> ProjectScriptBuildConfiguration {
        ProjectScriptBuildConfiguration.discover(
            for: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        )
    }

    static func resolveEngineModulePaths() -> [String] {
        scriptBuildConfiguration().engineModulePaths
    }

    static func resolveEngineClangModuleMapPaths() -> [String] {
        scriptBuildConfiguration().clangModuleMapPaths
    }

    static func resolveEngineClangIncludePaths() -> [String] {
        scriptBuildConfiguration().clangIncludePaths
    }

    func reloadScriptsAfterSceneReplacement() {
        reloadProjectScripts(force: true, reportUnresolvedBindings: false)
        reloadDynamicScripts()
    }

    func reloadDynamicScripts() {
        do {
            let files = try dynamicScriptManager.scanScriptFiles()
            var options: [String: String] = [:]
            var aliases: [String: String] = [:]
            for file in files {
                options[file.identifier] = file.displayName
                for alias in file.legacyIdentifiers { aliases[alias] = file.identifier }
            }
            scene.setDynamicScriptOptions(options, aliases: aliases)
            store.dispatch(.forceUIRefresh)
            scriptWorkspace.markAllBuildsStarted()

            // Swift scripts are native code in the editor process. Project
            // discovery and language analysis remain available while
            // untrusted, but startup must never execute project code.
            guard dynamicScriptManager.projectTrustState.allowsExecution else { return }

            try dynamicScriptManager.compileAllScripts(
                onScriptCompletion: { [weak self] file, status in
                    guard let self else { return }
                    self.scriptWorkspace.recordBuildResult(scriptID: file.identifier,
                                                           status: status)
                    if case let .failed(message) = status {
                        self.logConsole("Failed to compile dynamic script",
                                        severity: .error,
                                        detail: "\(file.displayName): \(message)",
                                        target: .compilerDiagnostic(scriptID: file.identifier, sourceURL: file.url, output: message),
                                        nextStep: "Open the script, fix the reported errors, then Save and Compile.")
                    }
                },
                completion: { [weak self] in
                    guard let self else { return }
                    self.store.dispatch(.forceUIRefresh)
                    self.reportUnresolvedScriptBindings()
                }
            )
        } catch {
            logConsole("Failed to scan dynamic scripts",
                       severity: .error,
                       detail: String(describing: error))
        }
    }

    public func reloadProjectScripts(force: Bool = false,
                                     reportUnresolvedBindings: Bool = true) {
        do {
            guard let catalog = try projectScriptCatalogMonitor.loadIfChanged(force: force) else {
                return
            }
            let report = scene.applyProjectScriptCatalog(catalog)
            store.dispatch(.forceUIRefresh)
            if let session {
                let context = Self.workflowContext(for: store.state.workspace.mode,
                                                   scriptEntries: catalog.entries)
                let previousTask = pendingAISetupTask
                pendingAISetupTask = Task {
                    await previousTask?.value
                    await session.setWorkflowContext(context)
                }
            }
            let source = catalog.sourceURL?.path ?? "built-in catalog"
            logConsole("Reloaded script catalog",
                       detail: "\(report.registeredScriptCount) scripts (\(report.projectScriptCount) project) · \(source)")
            for diagnostic in catalog.diagnostics {
                logConsole("Script catalog: \(diagnostic.message)",
                           severity: diagnostic.severity == .error ? .error : .warning)
            }
            if reportUnresolvedBindings {
                for unresolved in report.unresolvedBindings {
                    logConsole("Unresolved script binding",
                               severity: .error,
                               detail: unresolved)
                }
            }
        } catch {
            if scene.scriptCatalogEntries.isEmpty {
                _ = scene.applyProjectScriptCatalog(.builtIn)
                store.dispatch(.forceUIRefresh)
            }
            logConsole("Failed to reload script catalog",
                       severity: .error,
                       detail: String(describing: error))
        }
    }

    private func reportUnresolvedScriptBindings() {
        for unresolved in scene.unresolvedScriptBindingDescriptions() {
            logConsole("Unresolved script binding",
                       severity: .error,
                       detail: unresolved)
        }
    }
}
