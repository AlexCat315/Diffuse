#if os(macOS) || os(Linux)
import Foundation
import SceneRuntime
import SIMDCompat
import Testing
@testable import ScriptRuntime

@Suite("Swift script compiler")
struct SwiftScriptCompilerTests {
    @Test("discovers Linux C intermediates once and excludes other configurations")
    func discoversNativeModuleMaps() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appendingPathComponent("out/Products/Debug-linux-x86_64")
        try FileManager.default.createDirectory(at: products, withIntermediateDirectories: true)
        func write(_ relativePath: String, _ contents: String) throws -> String {
            let file = root.appendingPathComponent("out/Intermediates.noindex/" + relativePath)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: file, atomically: true, encoding: .utf8)
            return file.path
        }
        _ = try write("GeneratedModuleMaps/CJoltBridge.modulemap", "module CJoltBridge { export * }")
        _ = try write("GuavaEngine.build/Debug-linux-x86_64/CJoltBridge.build/module.modulemap", "module CJoltBridge { export * }")
        _ = try write("GuavaEngine.build/Debug-linux-x86_64/CNativeBridge.build/module.modulemap", "module CNativeBridge { export * }")
        _ = try write("GuavaEngine.build/Release-linux-x86_64/CReleaseBridge.build/module.modulemap", "module CReleaseBridge { export * }")
        _ = try write("GeneratedModuleMaps/ContextMemory.modulemap", "module ContextMemory { header \"ContextMemory-Swift.h\" }")
        let alias = root.appendingPathComponent(".build/debug")
        try FileManager.default.createDirectory(at: alias.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: products)
        let maps = SwiftScriptCompiler.discoverClangModuleMapPaths(in: alias)
        #expect(maps.count == 2)
        #expect(maps.contains { $0.hasSuffix("GeneratedModuleMaps/CJoltBridge.modulemap") })
        #expect(maps.contains { $0.hasSuffix("Debug-linux-x86_64/CNativeBridge.build/module.modulemap") })
    }

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
        let readyFile = directory.appendingPathComponent("compiler-started")
        try "#!/bin/sh\ntrap '' TERM\ntouch \"$(dirname \"$0\")/compiler-started\"\nexec /bin/sleep 10\n".write(to: fakeCompiler,
                                                        atomically: true,
                                                        encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fakeCompiler.path)
        let source = directory.appendingPathComponent("GameScript.swift")
        try "struct GameScript {}\n".write(to: source, atomically: true, encoding: .utf8)
        let compiler = SwiftScriptCompiler(swiftcPath: fakeCompiler.path,
                                           outputDirectory: directory.appendingPathComponent("out"))
        let token = ScriptCompilationCancellationToken()
        let compilation = Task.detached {
            Result {
                try compiler.compile(sourcePath: source.path,
                                     scriptID: "slow",
                                     cancellation: token)
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while !FileManager.default.fileExists(atPath: readyFile.path), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: readyFile.path), "The compiler must be running before cancellation")
        let started = ContinuousClock.now
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

        var moduleMapPaths = SwiftScriptCompiler.discoverClangModuleMapPaths(in: productsDirectory)

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
        struct GameScript: ScriptBehavior, ScriptAuthoring {
            static var definition: ScriptDefinition {
                ScriptDefinition(properties: [ScriptProperty("step", defaultValue: .number(1), minimum: 0)])
            }
            private var updateCount = 0

            mutating func onUpdate(_ context: ScriptContext) {
                updateCount += 1
                _ = context.translate(by: SIMD3<Float>(Float(updateCount) * (context.floatParameter("step") ?? 0), 0, 0))
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
        let factory = try loader.loadFactory(scriptID: "engine-script", libraryPath: result.outputPath)
        let definition = loader.definition(scriptID: "engine-script")
        #expect(definition.properties.first?.key == "step")
        let handle = scripts.register(named: "engine-script", definition: definition, factory)
        loader.unload(scriptID: "engine-script")

        var runtime = SceneRuntime()
        runtime.setScriptDriver(scripts)
        let firstEntity = runtime.createEntity()
        let secondEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: firstEntity)
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: secondEntity)
        _ = runtime.setComponent(ScriptComponent(handle), for: firstEntity)
        _ = runtime.setComponent(ScriptComponent(ScriptBinding(handle, parametersJSON: #"{"step":2}"#)), for: secondEntity)
        _ = runtime.tick(deltaTime: 0.1)
        _ = runtime.tick(deltaTime: 0.1)

        #expect(runtime.localTransform(for: firstEntity)?.translation == SIMD3<Float>(3, 0, 0))
        #expect(runtime.localTransform(for: secondEntity)?.translation == SIMD3<Float>(6, 0, 0))
        loader.unload(scriptID: "engine-script")

        let runtimeOnlySource = testDirectory.appendingPathComponent("RuntimeOnly.swift")
        try """
        import ScriptRuntime
        import SIMDCompat
        struct GameScript: ScriptBehavior {
            mutating func onUpdate(_ context: ScriptContext) {
                context.translate(by: SIMD3<Float>(1, 0, 0))
            }
        }
        """.write(to: runtimeOnlySource, atomically: true, encoding: .utf8)
        let runtimeOnlyResult = try compiler.compile(sourcePath: runtimeOnlySource.path, scriptID: "runtime-only")
        let runtimeOnlyFactory = try loader.loadFactory(scriptID: "runtime-only", libraryPath: runtimeOnlyResult.outputPath)
        #expect(loader.definition(scriptID: "runtime-only").properties.isEmpty)
        let runtimeOnlyHandle = scripts.register(named: "runtime-only", definition: loader.definition(scriptID: "runtime-only"), runtimeOnlyFactory)
        let runtimeOnlyEntity = runtime.createEntity()
        _ = runtime.setComponent(ScriptComponent(runtimeOnlyHandle), for: runtimeOnlyEntity)
        _ = runtime.tick(deltaTime: 0.1)
        #expect(runtime.localTransform(for: runtimeOnlyEntity)?.translation == SIMD3<Float>(1, 0, 0))
    }
}
#endif
