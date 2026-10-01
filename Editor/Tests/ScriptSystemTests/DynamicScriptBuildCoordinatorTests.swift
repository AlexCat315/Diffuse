import Foundation
import ScriptRuntime
import Testing
@testable import EditorCore

private func waitSynchronously(_ semaphore: DispatchSemaphore, seconds: Double) -> DispatchTimeoutResult {
    semaphore.wait(timeout: .now() + seconds)
}

private final class BuildCoordinatorCompilerStub: DynamicScriptCompiling, @unchecked Sendable {
    func compile(sourcePath: String,
                 scriptID: String,
                 cancellation: ScriptCompilationCancellationToken) throws -> DynamicScriptCompilationArtifact {
        let iterations = sourcePath.contains("slow") ? 30 : 2
        for _ in 0..<iterations {
            if cancellation.isCancelled { throw ScriptCompileError.cancelled }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return DynamicScriptCompilationArtifact(
            outputPath: sourcePath + ".dylib",
            stdout: "",
            stderr: ""
        )
    }
}

private final class BuildCoordinatorLoaderStub: DynamicScriptLibraryLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var onLoad: (@Sendable () -> Void)?

    var loadedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func loadFactory(scriptID: String,
                     libraryPath: String) throws -> @Sendable () -> Script {
        lock.lock()
        storage.append(libraryPath)
        lock.unlock()
        onLoad?()
        return { Script() }
    }

    func unload(scriptID: String) {}
}

@Suite("Dynamic script build coordinator", .serialized)
struct DynamicScriptBuildCoordinatorTests {
    @Test("only the newest overlapping build may reach the loader")
    func newestBuildWins() async {
        let loader = BuildCoordinatorLoaderStub()
        let coordinator = DynamicScriptBuildCoordinator(
            compiler: BuildCoordinatorCompilerStub(),
            loader: loader,
            scriptRuntime: ScriptRuntime()
        )
        let root = FileManager.default.temporaryDirectory
        let slow = root.appendingPathComponent("slow.swift")
        let fast = root.appendingPathComponent("fast.swift")

        let first = Task {
            await coordinator.build(scriptID: "scripts.player",
                                    legacyIdentifiers: [],
                                    sourceURL: slow)
        }
        try? await Task.sleep(for: .milliseconds(25))
        let second = await coordinator.build(scriptID: "scripts.player",
                                             legacyIdentifiers: [],
                                             sourceURL: fast)
        let firstOutcome = await first.value

        #expect(firstOutcome == .superseded)
        #expect(second == .succeeded(stdout: "", stderr: ""))
        #expect(loader.loadedPaths == [fast.path + ".dylib"])
    }

    @Test("explicit cancellation terminates compilation before loading")
    func explicitCancellationStopsCompilation() async {
        let loader = BuildCoordinatorLoaderStub()
        let coordinator = DynamicScriptBuildCoordinator(
            compiler: BuildCoordinatorCompilerStub(),
            loader: loader,
            scriptRuntime: ScriptRuntime()
        )
        let slow = FileManager.default.temporaryDirectory.appendingPathComponent("slow.swift")
        let build = Task {
            await coordinator.build(scriptID: "scripts.cancelled",
                                    legacyIdentifiers: [],
                                    sourceURL: slow)
        }
        try? await Task.sleep(for: .milliseconds(25))
        await coordinator.cancel(scriptID: "scripts.cancelled")

        #expect(await build.value == .cancelled)
        #expect(loader.loadedPaths.isEmpty)
    }

    @MainActor
    @Test("cancellation after compilation prevents queued main-actor registration")
    func cancellationBeforeRegistration() async {
        let loaded = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        let loader = BuildCoordinatorLoaderStub()
        loader.onLoad = { loaded.signal() }
        let runtime = ScriptRuntime()
        let coordinator = DynamicScriptBuildCoordinator(
            compiler: BuildCoordinatorCompilerStub(), loader: loader, scriptRuntime: runtime
        )
        let build = Task.detached {
            await coordinator.build(scriptID: "scripts.cancelled-before-registration",
                                    legacyIdentifiers: [],
                                    sourceURL: FileManager.default.temporaryDirectory.appendingPathComponent("fast.swift"))
        }
        let cancellation = Task.detached {
            guard waitSynchronously(loaded, seconds: 2) == .success else { return }
            await coordinator.cancel(scriptID: "scripts.cancelled-before-registration")
            cancelled.signal()
        }
        // Keep the main actor occupied until cancellation is acknowledged.
        // This exercises the gap between a successful compile and registration.
        #expect(waitSynchronously(cancelled, seconds: 3) == .success)
        await cancellation.value
        #expect(await build.value == .cancelled)
        #expect(runtime.registeredScriptIdentifiers.isEmpty)
    }
}
