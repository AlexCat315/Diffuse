import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import EditorCore

@Suite("Swift toolchain installation safety")
struct SwiftToolchainInstallationTests {
    @Test("downloads require explicit confirmation without creating a cache")
    func confirmationBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let installation = SwiftToolchainInstallation(directory: root)
        await #expect(throws: SwiftToolchainError.confirmationRequired) {
            try await installation.install(version: "6.4.1", confirmed: false, onProgress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test("installer signature must be trusted and match Swift Open Source identity")
    func signatureTrust() {
        #expect(SwiftToolchainInstallation.isOfficialSignature("Status: signed by a certificate trusted by macOS\n1. Developer ID Installer: Swift Open Source (V9AUD2URP3)"))
        #expect(!SwiftToolchainInstallation.isOfficialSignature("Status: unsigned\n1. Developer ID Installer: Swift Open Source (V9AUD2URP3)"))
        #expect(!SwiftToolchainInstallation.isOfficialSignature("Status: signed by a certificate trusted\n1. Developer ID Installer: Other (1234567890)"))
    }

    @Test("only successful HTTPS responses from the official download host are accepted")
    func responseOrigin() throws {
        let official = try #require(URL(string: "https://download.swift.org/release.pkg"))
        let good = try #require(HTTPURLResponse(url: official, statusCode: 200, httpVersion: nil, headerFields: nil))
        try SwiftToolchainInstallation.validateResponse(good)
        for address in ["http://download.swift.org/release.pkg", "https://untrusted.invalid/release.pkg"] {
            let url = try #require(URL(string: address))
            let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            #expect(throws: SwiftToolchainError.self) { try SwiftToolchainInstallation.validateResponse(response) }
        }
        let notFound = try #require(HTTPURLResponse(url: official, statusCode: 404, httpVersion: nil, headerFields: nil))
        #expect(throws: SwiftToolchainError.self) { try SwiftToolchainInstallation.validateResponse(notFound) }
    }

    @Test("preferences round trip separately from project and default missing values")
    func preferencesRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(SwiftToolchainPreferences.load(from: root) == SwiftToolchainPreferences())
        var preferences = SwiftToolchainPreferences()
        preferences.selectedPath = "/host/Swift.xctoolchain"
        preferences.releaseVersion = "6.4.0"
        try preferences.save(to: root)
        #expect(SwiftToolchainPreferences.load(from: root) == preferences)
        try Data(#"{"selectedPath":"/host/Swift.xctoolchain"}"#.utf8).write(to: root.appendingPathComponent("preferences.json"))
        let partial = SwiftToolchainPreferences.load(from: root)
        #expect(partial.selectedPath == preferences.selectedPath)
        #expect(partial.releaseVersion == SwiftToolchainPreferences().releaseVersion)
    }
}
