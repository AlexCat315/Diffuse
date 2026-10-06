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
    /// Capture authoring state on the UI thread, then perform file copies and
    /// script compilation off-thread so progress remains visible and responsive.
    public func requestProjectExport(runAfterExport: Bool = false) {
        guard !store.operations.contains(where: { $0.kind == .exporting && $0.status == .running }) else { return }
        let output = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent("export", isDirectory: true)
        let authored = authoredSceneManifest()
        let assets: [EditorAsset]
        do {
            assets = try EditorAssetCatalog.loadProject(at: projectDirectory)
            if !(try dynamicScriptManager.scanScriptFiles()).isEmpty,
               !dynamicScriptManager.projectTrustState.allowsExecution {
                throw ScriptProjectTrustError.executionBlocked
            }
        } catch {
            logConsole("Project export failed", severity: .error, detail: String(describing: error),
                       target: .file(path: projectDirectory),
                       nextStep: "Check project assets and script trust in Settings, then export again.")
            return
        }
        let name = exportedApplicationName
        let source = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        let player = resolvePlayerExecutableURL()
        let configuration = Self.scriptBuildConfiguration()
        let operation = beginOperation(.exporting, message: L("Exporting project…"))
        Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<ProjectExportDescriptor, Error>
            do {
                result = .success(try ProjectExporter.export(manifest: authored.manifest,
                    appName: name, assets: assets, sourceProjectDirectory: source,
                    playerExecutableURL: player, scriptBuildConfiguration: configuration, to: output))
            } catch { result = .failure(error) }
            await MainActor.run {
                guard let self, !self.isShuttingDown else { return }
                switch result {
                case let .success(descriptor):
                    if player != nil { self.adHocSignExportedApplication(appName: descriptor.appName, in: output) }
                    else {
                        self.logConsole("Exported portable project data without an application", severity: .warning,
                            nextStep: "Build GuavaPlayer or set GUAVA_PLAYER_EXECUTABLE, then export again.")
                    }
                    self.finishOperation(operation, succeeded: true, message: L("Project exported"))
                    self.logConsole("Exported project bundle", detail: output.path)
                    if runAfterExport { _ = self.runExportedProject(at: output) }
                case let .failure(error):
                    self.finishOperation(operation, succeeded: false, message: L("Project export failed"),
                        nextStep: "Check Build Output and project assets, fix the errors, then export again.",
                        target: self.exportFailureTarget(error), detail: String(describing: error))
                }
            }
        }
    }

    private var exportedApplicationName: String {
        let name = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .standardizedFileURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Guava Game" : name
    }

    /// Exports a portable, runnable project bundle to `<projectDirectory>/export`
    /// (scene + assets + descriptor). Returns the output directory, or nil on failure.
    @discardableResult
    public func exportProject() -> URL? {
        let operation = beginOperation(.exporting, message: L("Exporting project…"))
        let output = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent("export", isDirectory: true)
        do {
            let authoredOutput = authoredSceneManifest()
            let manifest = authoredOutput.manifest
            // A failed scan must fail the export. Treating it as an empty
            // catalog produces a seemingly successful build with missing assets.
            let assets = try EditorAssetCatalog.loadProject(at: projectDirectory)
            let playerExecutableURL = resolvePlayerExecutableURL()
            if !(try dynamicScriptManager.scanScriptFiles()).isEmpty,
               !dynamicScriptManager.projectTrustState.allowsExecution {
                throw ScriptProjectTrustError.executionBlocked
            }
            let descriptor = try ProjectExporter.export(manifest: manifest,
                                                        appName: exportedApplicationName,
                                                        assets: assets,
                                                        sourceProjectDirectory: URL(fileURLWithPath: projectDirectory,
                                                                                    isDirectory: true),
                                                        playerExecutableURL: playerExecutableURL,
                                                        scriptBuildConfiguration: ProjectScriptBuildConfiguration(
                                                            engineModulePaths: Self.resolveEngineModulePaths(),
                                                            clangModuleMapPaths: Self.resolveEngineClangModuleMapPaths(),
                                                            clangIncludePaths: Self.resolveEngineClangIncludePaths(),
                                                            swiftCompilerPath: DynamicScriptManager.resolvedCompilerPath()
                                                        ),
                                                        to: output)
            if playerExecutableURL != nil {
                adHocSignExportedApplication(appName: descriptor.appName, in: output)
            } else {
                logConsole("Exported portable project data without an application",
                           severity: .warning,
                           detail: "Build GuavaPlayer or set GUAVA_PLAYER_EXECUTABLE to include a self-contained player")
            }
            logConsole("Exported project bundle",
                       detail: "\(descriptor.entityCount) entities, \(descriptor.assetCount) assets"
                           + (authoredOutput.usedPlaySnapshot ? ", authored pre-play state" : "")
                           + " → \(output.path)")
            finishOperation(operation, succeeded: true, message: L("Project exported"))
            return output
        } catch {
            finishOperation(operation, succeeded: false, message: L("Project export failed"),
                nextStep: "Check Build Output and project assets, fix the errors, then export again.",
                target: exportFailureTarget(error), detail: String(describing: error))
            return nil
        }
    }

    private func exportFailureTarget(_ error: Error) -> EditorIssueTarget {
        switch error as? ProjectExporterError {
        case .missingAsset(let path), .unsafeRelativePath(let path), .conflictingAssetDestination(let path):
            return .file(path: path)
        case .unresolvedScriptBindings(let ids):
            if let target = EditorIssueTarget.unresolvedBindingTarget(ids, in: authoredSceneManifest().manifest) {
                return target
            }
        case .conflictingScriptIdentifier(let id):
            return .script(id: id, line: 0, column: 0)
        default: break
        }
        return .file(path: projectDirectory)
    }

    @discardableResult
    public func runExportedProject(at projectURL: URL) -> Bool {
        let descriptor: ProjectExportDescriptor
        do {
            descriptor = try ProjectExporter.readDescriptor(from: projectURL)
        } catch {
            logConsole("Unable to run exported build",
                       severity: .error,
                       detail: "Invalid build descriptor: \(error)")
            return false
        }
        guard descriptor.schemaVersion == ProjectExporter.schemaVersion else {
            logConsole("Unable to run exported build",
                       severity: .error,
                       detail: "Unsupported build descriptor version \(descriptor.schemaVersion)")
            return false
        }
        let packagedExecutable = ProjectExporter.runnableExecutableURL(
            appName: descriptor.appName,
            in: projectURL
        )
        let executable: URL
        let arguments: [String]
        if FileManager.default.isExecutableFile(atPath: packagedExecutable.path) {
            executable = packagedExecutable
            #if os(macOS)
            arguments = []
            #else
            arguments = ["--project", projectURL.path]
            #endif
        } else if let player = resolvePlayerExecutableURL() {
            executable = player
            arguments = ["--project", projectURL.path]
        } else {
            logConsole("Unable to run exported build",
                       severity: .error,
                       detail: "GuavaPlayer is not installed next to the Editor. Set GUAVA_PLAYER_EXECUTABLE to its path.")
            return false
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        do {
            try process.run()
            launchedPlayerProcess = process
            logConsole("Started exported build", detail: projectURL.path)
            return true
        } catch {
            logConsole("Unable to run exported build",
                       severity: .error,
                       detail: String(describing: error))
            return false
        }
    }

    private func resolvePlayerExecutableURL() -> URL? {
        let environmentOverride = ProcessInfo.processInfo.environment["GUAVA_PLAYER_EXECUTABLE"]
            .map { URL(fileURLWithPath: $0) }
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        #if os(Windows)
        let playerExecutableName = "GuavaPlayer.exe"
        #else
        let playerExecutableName = "GuavaPlayer"
        #endif
        return [
            environmentOverride,
            executableDirectory.appendingPathComponent(playerExecutableName),
        ]
        .compactMap { $0 }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private func adHocSignExportedApplication(appName: String, in output: URL) {
        #if os(macOS)
        let appURL = ProjectExporter.applicationBundleURL(
            appName: appName,
            in: output
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--deep", "--sign", "-", "--timestamp=none", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                logConsole("Ad-hoc signed exported application", detail: appURL.lastPathComponent)
            } else {
                logConsole("Exported application could not be ad-hoc signed",
                           severity: .warning,
                           detail: "codesign exited with status \(process.terminationStatus)")
            }
        } catch {
            logConsole("Exported application could not be ad-hoc signed",
                       severity: .warning,
                       detail: String(describing: error))
        }
        #endif
    }
}
