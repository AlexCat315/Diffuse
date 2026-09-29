import Foundation
import Testing
@testable import EditorCore

@Suite("SourceKit-LSP executable lookup")
struct SourceKitLSPExecutableLocatorTests {
    @Test("resolves SourceKit-LSP from an explicit executable override")
    func resolvesExplicitSourceKitPath() throws {
        let url = try SourceKitLSPExecutableLocator.resolveExecutableURL(environment: [
            SourceKitLSPExecutableLocator.overrideEnvironmentKey:
                "/Library/Developer/CommandLineTools/usr/bin/sourcekit-lsp",
        ])

        #expect(url.path == "/Library/Developer/CommandLineTools/usr/bin/sourcekit-lsp")
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
        let url = try SourceKitLSPExecutableLocator.resolveExecutableURL(
            environment: ["PATH": "/Library/Developer/CommandLineTools/usr/bin"]
        )

        #expect(url.lastPathComponent == "sourcekit-lsp")
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
}
