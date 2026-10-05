import Foundation
import ScriptRuntime

struct DynamicScriptCompilationArtifact: Sendable, Equatable {
    let outputPath: String
    let stdout: String
    let stderr: String
}

protocol DynamicScriptCompiling: Sendable {
    func compile(sourcePath: String,
                 scriptID: String,
                 cancellation: ScriptCompilationCancellationToken) throws -> DynamicScriptCompilationArtifact
}

struct SwiftScriptCompilerDriver: DynamicScriptCompiling {
    let compiler: SwiftScriptCompiler

    func compile(sourcePath: String,
                 scriptID: String,
                 cancellation: ScriptCompilationCancellationToken) throws -> DynamicScriptCompilationArtifact {
        let result = try compiler.compile(sourcePath: sourcePath,
                                          scriptID: scriptID,
                                          cancellation: cancellation)
        return DynamicScriptCompilationArtifact(outputPath: result.outputPath,
                                                stdout: result.stdout,
                                                stderr: result.stderr)
    }
}

protocol DynamicScriptLibraryLoading: Sendable {
    func loadFactory(scriptID: String,
                     libraryPath: String) throws -> @Sendable () -> Script
    func unload(scriptID: String)
}

extension SwiftScriptLoader: DynamicScriptLibraryLoading {}

enum DynamicScriptBuildOutcome: Sendable, Equatable {
    case succeeded(stdout: String, stderr: String)
    case failed(message: String)
    case cancelled
    case superseded
}

/// Serializes dynamic-library mutation while allowing a newer request to
/// supersede a compiler process that is already running.
///
/// Compilation happens outside the actor so another call can publish its token
/// immediately. Only the newest token for a script is allowed to load and
/// register an artifact; an older result is discarded without touching the
/// last known-good runtime generation.
actor DynamicScriptBuildCoordinator {
    private struct ActiveCompilation: Sendable {
        let requestID: UInt64
        let cancellation: ScriptCompilationCancellationToken
    }

    private let compiler: any DynamicScriptCompiling
    private let loader: any DynamicScriptLibraryLoading
    private let scriptRuntime: ScriptRuntime

    private var nextRequestID: UInt64 = 0
    private var newestRequestByScriptID: [String: UInt64] = [:]
    private var activeCompilations: [String: ActiveCompilation] = [:]
    private var explicitlyCancelledRequestIDs: Set<UInt64> = []
    private var loadedArtifactPaths: [String: String] = [:]
    private var registeredIdentifiers: [String: Set<String>] = [:]
    private var retiredArtifactPaths: Set<String> = []
    private var cleanupTask: Task<Void, Never>?

    init(compiler: any DynamicScriptCompiling,
         loader: any DynamicScriptLibraryLoading,
         scriptRuntime: ScriptRuntime) {
        self.compiler = compiler
        self.loader = loader
        self.scriptRuntime = scriptRuntime
    }

    func build(scriptID: String,
               legacyIdentifiers: [String],
               sourceURL: URL) async -> DynamicScriptBuildOutcome {
        activeCompilations[scriptID]?.cancellation.cancel()
        nextRequestID &+= 1
        let requestID = nextRequestID
        newestRequestByScriptID[scriptID] = requestID
        let cancellation = ScriptCompilationCancellationToken()
        activeCompilations[scriptID] = ActiveCompilation(requestID: requestID,
                                                         cancellation: cancellation)
        defer {
            if activeCompilations[scriptID]?.requestID == requestID {
                activeCompilations.removeValue(forKey: scriptID)
            }
            explicitlyCancelledRequestIDs.remove(requestID)
        }
        let compiler = self.compiler

        let compilation = await Task.detached(priority: .userInitiated) {
            Result {
                try compiler.compile(sourcePath: sourceURL.path,
                                     scriptID: scriptID,
                                     cancellation: cancellation)
            }
        }.value

        let wasExplicitlyCancelled = explicitlyCancelledRequestIDs.contains(requestID)

        guard newestRequestByScriptID[scriptID] == requestID else {
            if case let .success(artifact) = compilation {
                try? FileManager.default.removeItem(atPath: artifact.outputPath)
            }
            return .superseded
        }
        if wasExplicitlyCancelled {
            if case let .success(artifact) = compilation {
                try? FileManager.default.removeItem(atPath: artifact.outputPath)
            }
            return .cancelled
        }

        switch compilation {
        case .failure(let error):
            if wasExplicitlyCancelled || (error as? ScriptCompileError) == .cancelled {
                return .cancelled
            }
            return .failed(message: error.localizedDescription)
        case .success(let artifact):
            do {
                let factory = try loader.loadFactory(scriptID: scriptID,
                                                     libraryPath: artifact.outputPath)
                guard newestRequestByScriptID[scriptID] == requestID else {
                    loader.unload(scriptID: scriptID)
                    retireArtifact(at: artifact.outputPath)
                    return .superseded
                }

                let nextIdentifiers = Set([scriptID] + legacyIdentifiers)
                let previousIdentifiers = registeredIdentifiers[scriptID] ?? []
                let didRegister = await MainActor.run {
                    // Cancellation can arrive after swiftc exits while the
                    // registration waits behind UI work on the main actor.
                    guard !cancellation.isCancelled else { return false }
                    for identifier in previousIdentifiers.subtracting(nextIdentifiers) {
                        scriptRuntime.unregister(named: identifier)
                    }
                    for identifier in nextIdentifiers {
                        scriptRuntime.register(named: identifier, factory)
                    }
                    return true
                }
                guard didRegister else {
                    if newestRequestByScriptID[scriptID] == requestID {
                        loader.unload(scriptID: scriptID)
                    }
                    retireArtifact(at: artifact.outputPath)
                    return newestRequestByScriptID[scriptID] == requestID ? .cancelled : .superseded
                }
                registeredIdentifiers[scriptID] = nextIdentifiers
                if let previous = loadedArtifactPaths.updateValue(artifact.outputPath,
                                                                  forKey: scriptID),
                   previous != artifact.outputPath {
                    retireArtifact(at: previous)
                }
                cleanupRetiredArtifacts()
                // MainActor.run is a suspension point. A newer request may
                // have arrived while registration was being scheduled; keep
                // this valid generation as the last-known-good fallback, but
                // never let its completion overwrite the newer build state.
                guard newestRequestByScriptID[scriptID] == requestID else {
                    return .superseded
                }
                return .succeeded(stdout: artifact.stdout, stderr: artifact.stderr)
            } catch {
                try? FileManager.default.removeItem(atPath: artifact.outputPath)
                return .failed(message: error.localizedDescription)
            }
        }
    }

    func cancel(scriptID: String) {
        guard let active = activeCompilations[scriptID] else { return }
        explicitlyCancelledRequestIDs.insert(active.requestID)
        active.cancellation.cancel()
    }

    func unload(scriptID: String) async {
        activeCompilations[scriptID]?.cancellation.cancel()
        activeCompilations.removeValue(forKey: scriptID)
        nextRequestID &+= 1
        newestRequestByScriptID[scriptID] = nextRequestID
        let identifiers = registeredIdentifiers.removeValue(forKey: scriptID) ?? Set([scriptID])
        await MainActor.run {
            for identifier in identifiers {
                scriptRuntime.unregister(named: identifier)
            }
        }
        loader.unload(scriptID: scriptID)
        if let path = loadedArtifactPaths.removeValue(forKey: scriptID) {
            retireArtifact(at: path)
        }
        cleanupRetiredArtifacts()
    }

    private func retireArtifact(at path: String) {
        retiredArtifactPaths.insert(path)
        scheduleRetiredArtifactCleanup()
    }

    /// On Windows an old DLL cannot be deleted until the runtime releases the
    /// final callback that retains it. Retry briefly after subsequent frames and
    /// keep any remaining path recorded for the next build/unload operation.
    private func scheduleRetiredArtifactCleanup() {
        guard cleanupTask == nil else { return }
        cleanupTask = Task { [weak self] in
            for _ in 0..<12 {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                await self.cleanupRetiredArtifacts()
                if await self.retiredArtifactPaths.isEmpty { break }
            }
            await self?.finishCleanupTask()
        }
    }

    private func cleanupRetiredArtifacts() {
        var removedPaths: [String] = []
        for path in retiredArtifactPaths {
            do {
                if FileManager.default.fileExists(atPath: path) {
                    try FileManager.default.removeItem(atPath: path)
                }
                removedPaths.append(path)
            } catch {
                // The mapped image is still leased by an active script. Keep it
                // in the retirement set and retry after the runtime advances.
            }
        }
        retiredArtifactPaths.subtract(removedPaths)
    }

    private func finishCleanupTask() {
        cleanupTask = nil
    }
}
