import Foundation
import Testing
@testable import EditorCore

#if os(macOS) || os(Linux)
@Suite("Paired Swift toolchain resolution")
struct SwiftToolchainResolutionTests {
    private func withToolchain(_ body: (URL, [String: String]) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cove-toolchain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let binaries = root.appendingPathComponent("usr/bin")
        let resources = root.appendingPathComponent("usr/lib/swift")
        try FileManager.default.createDirectory(at: binaries, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let reply = try JSONSerialization.data(withJSONObject: ["compilerVersion": "Swift version 6.4.1", "paths": ["runtimeResourcePath": resources.path]])
        let compiler = binaries.appendingPathComponent("swiftc")
        try Data(("#!/bin/sh\ncat <<'COVE_TOOLCHAIN_REPLY'\n" + String(decoding: reply, as: UTF8.self) + "\nCOVE_TOOLCHAIN_REPLY\n").utf8).write(to: compiler)
        let server = binaries.appendingPathComponent("sourcekit-lsp")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: server)
        for executable in [compiler, server] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path) }
        var environment = ["PATH": "/usr/bin:/bin"]
        #if os(macOS)
        let sdk = root.appendingPathComponent("macOS.sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: sdk.appendingPathComponent("SDKSettings.json"))
        environment["SDKROOT"] = sdk.path
        #endif
        try body(root, environment)
    }

    @Test("directory selection fixes compiler, language server, resources and launch environment together")
    func pairedSelection() throws {
        try withToolchain { root, environment in
            let toolchain = try SwiftToolchainResolver.resolve(compilerOverride: root.path, environment: environment, preferences: .init())
            #expect(toolchain.compilerURL.path == root.appendingPathComponent("usr/bin/swiftc").path)
            #expect(toolchain.languageServerURL.path == root.appendingPathComponent("usr/bin/sourcekit-lsp").path)
            #expect(toolchain.rootURL.path == root.path)
            #expect(toolchain.environment["SOURCEKIT_TOOLCHAIN_PATH"] == root.path)
            #expect(toolchain.environment["SWIFT_EXEC"] == toolchain.compilerURL.path)
            #expect(toolchain.environment["PATH"]?.hasPrefix(root.appendingPathComponent("usr/bin").path) == true)
        }
    }

    @Test("explicit compiler beats persisted paths and mismatched LSP overrides fail closed")
    func explicitOverrides() throws {
        try withToolchain { root, environment in
            var preferences = SwiftToolchainPreferences()
            preferences.selectedPath = "/missing/persisted/path"
            let toolchain = try SwiftToolchainResolver.resolve(compilerOverride: root.path, environment: environment, preferences: preferences)
            #expect(toolchain.rootURL.path == root.path)
            var mismatched = environment
            mismatched["COVE_SOURCEKIT_LSP_PATH"] = "/bin/sh"
            #expect(throws: SwiftToolchainError.self) {
                try SwiftToolchainResolver.resolve(compilerOverride: root.path, environment: mismatched, preferences: .init())
            }
        }
    }

    @Test("missing paired server is not silently replaced by a different installation")
    func missingServer() throws {
        try withToolchain { root, environment in
            try FileManager.default.removeItem(at: root.appendingPathComponent("usr/bin/sourcekit-lsp"))
            #expect(throws: SwiftToolchainError.self) {
                try SwiftToolchainResolver.resolve(compilerOverride: root.path, environment: environment, preferences: .init())
            }
        }
    }
}
#endif
