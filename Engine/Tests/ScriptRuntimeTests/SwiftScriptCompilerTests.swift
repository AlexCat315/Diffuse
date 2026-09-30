#if os(macOS) || os(Linux)
import Foundation
import SceneRuntime
import SIMDCompat
import Testing
@testable import ScriptRuntime

@Suite("Swift script compiler")
struct SwiftScriptCompilerTests {
    @Test("resolves compiler executables through PATH")
    func resolvesCompilerFromPATH() throws {
        let compilerURL = try SwiftScriptCompiler.resolveExecutableURL(for: "swiftc")

        #expect(compilerURL.isFileURL)
        #expect(FileManager.default.isExecutableFile(atPath: compilerURL.path))
    }

    @Test("honors cancellation before launching swiftc")
    func honorsPreflightCancellation() throws {
        let token = ScriptCompilationCancellationToken()
        token.cancel()
        let compiler = SwiftScriptCompiler(
            outputDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        #expect(throws: ScriptCompileError.cancelled) {
            try compiler.compile(sourcePath: "/unused.swift",
                                 scriptID: "cancelled",
                                 cancellation: token)
        }
    }

    @Test("cancellation terminates an in-flight compiler process")
    func terminatesRunningCompiler() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fakeCompiler = directory.appendingPathComponent("slow-swiftc")
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: fakeCompiler,
                                                        atomically: true,
                                                        encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fakeCompiler.path)
        let source = directory.appendingPathComponent("GameScript.swift")
        try "struct GameScript {}\n".write(to: source, atomically: true, encoding: .utf8)
        let compiler = SwiftScriptCompiler(swiftcPath: fakeCompiler.path,
                                           outputDirectory: directory.appendingPathComponent("out"))
        let token = ScriptCompilationCancellationToken()
        let started = ContinuousClock.now
        let compilation = Task.detached {
            Result {
                try compiler.compile(sourcePath: source.path,
                                     scriptID: "slow",
                                     cancellation: token)
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        token.cancel()

        switch await compilation.value {
        case .failure(let error as ScriptCompileError):
            #expect(error == .cancelled)
        default:
            Issue.record("Expected the running compiler to be cancelled")
        }
        #expect(started.duration(to: .now) < .seconds(3))
    }

    @Test("compiles scripts that import SceneRuntime and ScriptRuntime")
    func compilesEngineModulesWithTheirClangDependencies() throws {
        let fileManager = FileManager.default
        let engineRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productCandidates = [
            engineRoot.appendingPathComponent(".build/out/Products/Debug", isDirectory: true),
            engineRoot.appendingPathComponent(".build/arm64-apple-macosx/debug", isDirectory: true),
            engineRoot.appendingPathComponent(".build/debug", isDirectory: true),
        ]
        let productsDirectory = productCandidates.first {
            fileManager.fileExists(atPath: $0.appendingPathComponent("SceneRuntime.swiftmodule").path)
        } ?? productCandidates[0]

        let generatedMapsDirectory = engineRoot
            .appendingPathComponent(".build/out/Intermediates.noindex/GeneratedModuleMaps", isDirectory: true)
        let generatedMaps = (try? fileManager.contentsOfDirectory(
            at: generatedMapsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        var moduleMapPaths = generatedMaps
            .filter { $0.pathExtension == "modulemap" && $0.lastPathComponent.hasPrefix("C") }
            .map(\.path)

        let bridgeRoot = engineRoot.appendingPathComponent("Sources/Bridge", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: bridgeRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.lastPathComponent == "module.modulemap" {
                moduleMapPaths.append(url.path)
            }
        }

        let clangIncludePaths = Set(moduleMapPaths.map {
            URL(fileURLWithPath: $0).deletingLastPathComponent().path
        })
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: testDirectory) }
        try fileManager.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        let sourceURL = testDirectory.appendingPathComponent("EngineScript.swift")
        try """
        import SceneRuntime
        import ScriptRuntime
        import SIMDCompat
        struct GameScript: ScriptBehavior {
            private var updateCount = 0

            mutating func onUpdate(_ context: ScriptContext) {
                updateCount += 1
                _ = context.translate(by: SIMD3<Float>(Float(updateCount), 0, 0))
            }
        }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let compiler = SwiftScriptCompiler(
            includePaths: [productsDirectory.path],
            clangModuleMapPaths: moduleMapPaths,
            clangIncludePaths: Array(clangIncludePaths),
            outputDirectory: testDirectory.appendingPathComponent(".build", isDirectory: true)
        )
        let result = try compiler.compile(sourcePath: sourceURL.path, scriptID: "engine-script")

        #expect(fileManager.fileExists(atPath: result.outputPath))

        let loader = SwiftScriptLoader()
        let scripts = ScriptRuntime()
        let handle = scripts.register(named: "engine-script",
                          try loader.loadFactory(scriptID: "engine-script",
                                     libraryPath: result.outputPath))
        loader.unload(scriptID: "engine-script")

        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)
        let firstEntity = runtime.createEntity()
        let secondEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: firstEntity)
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: secondEntity)
        _ = runtime.setComponent(ScriptComponent(handle), for: firstEntity)
        _ = runtime.setComponent(ScriptComponent(handle), for: secondEntity)
        _ = runtime.tick(deltaTime: 0.1)
        _ = runtime.tick(deltaTime: 0.1)

        #expect(runtime.localTransform(for: firstEntity)?.translation == SIMD3<Float>(3, 0, 0))
        #expect(runtime.localTransform(for: secondEntity)?.translation == SIMD3<Float>(3, 0, 0))
        loader.unload(scriptID: "engine-script")
    }
}
#endif
