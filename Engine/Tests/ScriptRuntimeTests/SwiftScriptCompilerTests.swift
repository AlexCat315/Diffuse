#if os(macOS) || os(Linux)
import Foundation
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

    @Test("creates output directory before compiling a script")
    func createsOutputDirectoryBeforeCompilation() throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: testDirectory) }
        try fileManager.createDirectory(at: testDirectory, withIntermediateDirectories: true)

        let sourceURL = testDirectory.appendingPathComponent("MinimalScript.swift")
        try """
        @_cdecl("guava_test_script")
        public func guavaTestScript() {}
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let outputDirectory = testDirectory.appendingPathComponent("nested/.build", isDirectory: true)
        let compiler = SwiftScriptCompiler(outputDirectory: outputDirectory)
        let result = try compiler.compile(sourcePath: sourceURL.path, scriptID: "test-script")

        #expect(fileManager.fileExists(atPath: result.outputPath))
    }

    @Test("passes Clang module maps to swiftc")
    func importsClangModuleWhileCompiling() throws {
        let fileManager = FileManager.default
        let testDirectory = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: testDirectory) }
        let includeDirectory = testDirectory.appendingPathComponent("include", isDirectory: true)
        try fileManager.createDirectory(at: includeDirectory, withIntermediateDirectories: true)

        let headerURL = includeDirectory.appendingPathComponent("test_bridge.h")
        try "int guava_test_bridge_value(void);".write(to: headerURL, atomically: true, encoding: .utf8)
        let moduleMapURL = includeDirectory.appendingPathComponent("TestBridge.modulemap")
        try "module TestBridge { header \"test_bridge.h\" export * }"
            .write(to: moduleMapURL, atomically: true, encoding: .utf8)

        let sourceURL = testDirectory.appendingPathComponent("ImportsBridge.swift")
        try """
        import TestBridge
        @_cdecl("guava_test_script")
        public func guavaTestScript() { _ = guava_test_bridge_value() }
        """.write(to: sourceURL, atomically: true, encoding: .utf8)

        let compiler = SwiftScriptCompiler(
            clangModuleMapPaths: [moduleMapURL.path],
            clangIncludePaths: [includeDirectory.path],
            outputDirectory: testDirectory.appendingPathComponent(".build", isDirectory: true)
        )
        let result = try compiler.compile(sourcePath: sourceURL.path, scriptID: "module-test")

        #expect(fileManager.fileExists(atPath: result.outputPath))
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
        @_cdecl("guava_test_script")
        public func guavaTestScript(_ output: UnsafeMutableRawPointer) {
            output.assumingMemoryBound(to: Script.self).pointee = Script()
                .onUpdate { context in _ = context.deltaTime }
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
    }
}
#endif