import Foundation
import Testing
@testable import EditorCore

@Suite("Swift analysis cache identity")
struct AnalysisCacheTests {
    @Test("unknown or changed environments discard generated caches, matching environments retain them")
    func invalidatesOnlyWhenEnvironmentChanges() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = ScriptLanguageWorkspace(scriptsDirectoryURL: root.appendingPathComponent("Scripts"), engineModulePaths: [],
            clangModuleMapPaths: [], clangIncludePaths: [])
        _ = try workspace.synchronize([])
        let scratch = workspace.rootURL.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let stale = scratch.appendingPathComponent("stale.swiftmodule")
        try Data("stale cache".utf8).write(to: stale)
        let executable = root.appendingPathComponent("Toolchain/usr/bin/sourcekit-lsp")
        _ = try workspace.prepareScratch(executableURL: executable, environment: ["SWIFT_EXEC": "/host/toolchain-a/swiftc"])
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        let current = scratch.appendingPathComponent("current.swiftmodule")
        try Data("current cache".utf8).write(to: current)
        _ = try workspace.prepareScratch(executableURL: executable, environment: ["SWIFT_EXEC": "/host/toolchain-a/swiftc"])
        #expect(FileManager.default.fileExists(atPath: current.path))
        _ = try workspace.prepareScratch(executableURL: executable, environment: ["SWIFT_EXEC": "/host/toolchain-b/swiftc"])
        #expect(!FileManager.default.fileExists(atPath: current.path))
    }

    @Test("rebuilding a Guava module invalidates cached analysis")
    func changedEngineModule() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let products = root.appendingPathComponent("Products")
        let module = products.appendingPathComponent("ScriptRuntime.swiftmodule")
        try FileManager.default.createDirectory(at: module, withIntermediateDirectories: true)
        let binary = module.appendingPathComponent("arm64-apple-macos.swiftmodule")
        try Data("first".utf8).write(to: binary)
        let workspace = ScriptLanguageWorkspace(scriptsDirectoryURL: root.appendingPathComponent("Scripts"),
            engineModulePaths: [products.path], clangModuleMapPaths: [], clangIncludePaths: [])
        _ = try workspace.synchronize([])
        let executable = root.appendingPathComponent("sourcekit-lsp")
        let scratch = try workspace.prepareScratch(executableURL: executable, environment: [:])
        let cached = scratch.appendingPathComponent("cached.swiftmodule")
        try Data("old module".utf8).write(to: cached)
        try Data("second module build".utf8).write(to: binary)
        _ = try workspace.prepareScratch(executableURL: executable, environment: [:])
        #expect(!FileManager.default.fileExists(atPath: cached.path))
    }

    @Test("copying a project cannot reuse module caches that embed the old workspace path")
    func movedWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = ScriptLanguageWorkspace(scriptsDirectoryURL: root.appendingPathComponent("First/Scripts"), engineModulePaths: [],
            clangModuleMapPaths: [], clangIncludePaths: [])
        _ = try original.synchronize([])
        let executable = root.appendingPathComponent("sourcekit-lsp")
        let scratch = try original.prepareScratch(executableURL: executable, environment: [:])
        try Data("old workspace paths".utf8).write(to: scratch.appendingPathComponent("old.swiftmodule"))
        let copied = ScriptLanguageWorkspace(scriptsDirectoryURL: root.appendingPathComponent("Second/Scripts"), engineModulePaths: [],
            clangModuleMapPaths: [], clangIncludePaths: [])
        try FileManager.default.createDirectory(at: copied.scriptsDirectoryURL, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: original.scriptsDirectoryURL.appendingPathComponent(".guava"),
            to: copied.scriptsDirectoryURL.appendingPathComponent(".guava"))
        let next = try copied.prepareScratch(executableURL: executable, environment: [:])
        #expect(!FileManager.default.fileExists(atPath: next.appendingPathComponent("old.swiftmodule").path))
        #expect(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("old.swiftmodule").path))
    }

    @Test("workspace generation cannot write through a linked workspace or source directory")
    func refusesLinkedWorkspace() throws {
        for linkedDirectory in ["sourcekit-lsp", "Sources"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let workspace = ScriptLanguageWorkspace(scriptsDirectoryURL: root.appendingPathComponent("Scripts"), engineModulePaths: [],
                clangModuleMapPaths: [], clangIncludePaths: [])
            let outside = root.appendingPathComponent("Unrelated")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let keep = outside.appendingPathComponent("Package.swift")
            try Data("unrelated package".utf8).write(to: keep)
            let link = linkedDirectory == "Sources" ? workspace.rootURL.appendingPathComponent("Sources") : workspace.rootURL
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
            #expect(throws: ScriptLanguageSupportError.self) { try workspace.synchronize([]) }
            #expect(try String(contentsOf: keep, encoding: .utf8) == "unrelated package")
            #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path) == ["Package.swift"])
        }
    }

    @Test("cache cleanup refuses symbolic links and leaves their target untouched")
    func refusesLinkedCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = ScriptLanguageWorkspace(scriptsDirectoryURL: root.appendingPathComponent("Scripts"), engineModulePaths: [],
            clangModuleMapPaths: [], clangIncludePaths: [])
        _ = try workspace.synchronize([])
        let outside = root.appendingPathComponent("Unrelated")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: workspace.rootURL.appendingPathComponent(".build"), withDestinationURL: outside)
        #expect(throws: ScriptLanguageSupportError.self) { try workspace.prepareScratch(executableURL: root.appendingPathComponent("sourcekit-lsp"), environment: [:]) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
    }
}
