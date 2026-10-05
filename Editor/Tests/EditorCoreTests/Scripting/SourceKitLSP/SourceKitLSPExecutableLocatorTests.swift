import Foundation
import Testing
@testable import EditorCore

@Suite("SourceKit-LSP executable lookup")
struct SourceKitLSPExecutableLocatorTests {
    @Test("resolves SourceKit-LSP from an explicit executable override")
    func resolvesExplicitSourceKitPath() throws {
        let executable = try makeStubExecutable(contents: "")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let url = try SourceKitLSPExecutableLocator.resolveExecutableURL(environment: [
            SourceKitLSPExecutableLocator.overrideEnvironmentKey: executable.path,
        ])

        #expect(url.path == executable.path)
    }

    @Test("reports the override path when it is not executable")
    func rejectsNonExecutableOverride() {
        #expect(throws: SourceKitLSPClientError.executableNotFound("/nonexistent/sourcekit-lsp")) {
            _ = try SourceKitLSPExecutableLocator.resolveExecutableURL(environment: [
                SourceKitLSPExecutableLocator.overrideEnvironmentKey: "/nonexistent/sourcekit-lsp",
            ])
        }
    }

    @Test("falls through to PATH before consulting xcrun")
    func findsFromPath() throws {
        let executable = try makeStubExecutable(contents: "")
        defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
        let url = try SourceKitLSPExecutableLocator.resolveExecutableURL(
            environment: ["PATH": executable.deletingLastPathComponent().path]
        )

        #expect(url.path == executable.path)
    }

    @Test("fails with a descriptive error when nothing can be found")
    func failsWhenAbsent() {
        // A PATH with no Swift toolchain defeats both the direct lookup and the
        // `xcrun --find` fallback.
        #expect(throws: SourceKitLSPClientError.executableNotFound("sourcekit-lsp")) {
            _ = try SourceKitLSPExecutableLocator.resolveExecutableURL(
                environment: ["PATH": "/nonexistent/bin"]
            )
        }
    }

    @Test("detects optional flags from a stub --help output")
    func probesCapabilities() throws {
        #if os(Windows)
        // POSIX shell stubs cannot execute on Windows. Exercise the same help
        // parser there; missing-process fallback is checked on every platform.
        let capabilities = SourceKitLSPExecutableLocator.capabilities(fromHelpOutput:
            "Usage: sourcekit-lsp [--default-workspace-type <type>] [--scratch-path <path>]")
        #else
        let script = """
        #!/bin/sh
        echo "Usage: sourcekit-lsp [--default-workspace-type <type>] [--scratch-path <path>]"
        """
        let url = try makeStubExecutable(contents: script)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let capabilities = SourceKitLSPExecutableLocator.probeCapabilities(executableURL: url)
        #endif

        #expect(capabilities.supportsDefaultWorkspaceType)
        #expect(capabilities.supportsScratchPath)
        #expect(!capabilities.supportsBypassWorkspaceTrust)
    }

    @Test("falls back to the optimistic set when --help cannot run")
    func fallsBackWhenProbeFails() {
        let capabilities = SourceKitLSPExecutableLocator.probeCapabilities(
            executableURL: URL(fileURLWithPath: "/nonexistent/sourcekit-lsp")
        )

        #expect(capabilities == .optimistic)
    }

    @Test("builds only arguments the toolchain advertises")
    func buildsMatchingArguments() {
        let capabilities = SourceKitLSPCapabilities(supportsDefaultWorkspaceType: true,
                                                    supportsScratchPath: true,
                                                    supportsBypassWorkspaceTrust: false)
        let workspace = URL(fileURLWithPath: "/tmp/ws", isDirectory: true)
        let scratch = URL(fileURLWithPath: "/tmp/ws/.build", isDirectory: true)

        let arguments = SourceKitLSPCommandLine.arguments(for: workspace,
                                                         scratchURL: scratch,
                                                         capabilities: capabilities)

        #expect(arguments == [
            "--default-workspace-type", "swiftPM",
            "--scratch-path", scratch.path,
        ])
        #expect(!arguments.contains("--bypass-workspace-trust"))
    }

    private func makeStubExecutable(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-lsp-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(Windows)
        let url = directory.appendingPathComponent("sourcekit-lsp.exe")
        #else
        let url = directory.appendingPathComponent("sourcekit-lsp")
        #endif
        try Data(contents.utf8).write(to: url)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        #endif
        return url
    }
}
