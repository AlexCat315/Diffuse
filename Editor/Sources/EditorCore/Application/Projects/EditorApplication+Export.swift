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
            return output
        } catch {
            logConsole("Project export failed", severity: .error, detail: String(describing: error))
            return nil
        }
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
