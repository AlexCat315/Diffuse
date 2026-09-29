import Foundation
import ScriptRuntime
import Testing
@testable import EditorCore

private final class BuildCoordinatorCompilerStub: DynamicScriptCompiling, @unchecked Sendable {
    func compile(sourcePath: String,
                 scriptID: String) throws -> DynamicScriptCompilationArtifact {
        if sourcePath.contains("slow") {
            Thread.sleep(forTimeInterval: 0.15)
        } else {
            Thread.sleep(forTimeInterval: 0.01)
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
            await coordinator.build(scriptID: "scripts.player", sourceURL: slow)
        }
        try? await Task.sleep(for: .milliseconds(25))
        let second = await coordinator.build(scriptID: "scripts.player", sourceURL: fast)
        let firstOutcome = await first.value

        #expect(firstOutcome == .superseded)
        #expect(second == .succeeded(stdout: "", stderr: ""))
        #expect(loader.loadedPaths == [fast.path + ".dylib"])
    }
}
