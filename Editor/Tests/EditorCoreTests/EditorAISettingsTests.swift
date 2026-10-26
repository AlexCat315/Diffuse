@testable import EditorCore
import XCTest

final class EditorAISettingsTests: XCTestCase {
    func testEnvironmentCredentialsUseOnlyTheDeclaredVariable() {
        let credential = AICredentialStore.environmentCredential(
            variable: "COVE_OPENAI_API_KEY",
            environment: [
                "OPENAI_API_KEY": "standard",
                "COVE_OPENAI_API_KEY": "override",
            ]
        )

        XCTAssertEqual(credential?.variable, "COVE_OPENAI_API_KEY")
        XCTAssertEqual(credential?.key, "override")
    }

    func testEnvironmentCredentialsSupportEveryRemoteProviderAndRejectBlanks() {
        XCTAssertEqual(
            AICredentialStore.environmentCredential(
                variable: "ANTHROPIC_API_KEY",
                environment: ["ANTHROPIC_API_KEY": " anthropic-key "]
            )?.key,
            "anthropic-key"
        )
        XCTAssertEqual(
            AICredentialStore.environmentCredential(
                variable: "DEEPSEEK_API_KEY",
                environment: ["DEEPSEEK_API_KEY": "deepseek-key"]
            )?.variable,
            "DEEPSEEK_API_KEY"
        )
        XCTAssertNil(AICredentialStore.environmentCredential(
            variable: "OPENAI_API_KEY",
            environment: ["OPENAI_API_KEY": "  "]
        ))
        XCTAssertNil(AICredentialStore.environmentCredential(
            variable: nil,
            environment: ["OPENAI_API_KEY": "ignored"]
        ))
    }

    func testCredentialFileIsOwnerOnlyAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("Credentials/ai-providers.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try AICredentialStore.save(["api-key": "sk-one", "organization": "org-1"], providerID: "anthropic", at: url)
        try AICredentialStore.save(["api-key": "sk-two"], providerID: "openai", at: url)
        XCTAssertEqual(AICredentialStore.stored(at: url), ["anthropic": ["api-key": "sk-one", "organization": "org-1"],
                                                          "openai": ["api-key": "sk-two"]])
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        let folder = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try AICredentialStore.save(["organization": ""], providerID: "anthropic", at: url)
        XCTAssertEqual(AICredentialStore.stored(at: url)["anthropic"], ["api-key": "sk-one"])
        try AICredentialStore.save(["api-key": ""], providerID: "anthropic", at: url)
        XCTAssertEqual(AICredentialStore.stored(at: url), ["openai": ["api-key": "sk-two"]])
    }
}
