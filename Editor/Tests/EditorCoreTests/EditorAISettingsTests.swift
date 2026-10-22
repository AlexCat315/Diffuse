@testable import EditorCore
import XCTest

final class EditorAISettingsTests: XCTestCase {
    func testEnvironmentCredentialsUseGuavaOverrideBeforeStandardVariable() {
        let credential = AICredentialStore.environmentCredential(
            provider: .openai,
            environment: [
                "OPENAI_API_KEY": "standard",
                "GUAVA_OPENAI_API_KEY": "override",
            ]
        )

        XCTAssertEqual(credential?.variable, "GUAVA_OPENAI_API_KEY")
        XCTAssertEqual(credential?.key, "override")
    }

    func testEnvironmentCredentialsSupportEveryRemoteProviderAndRejectBlanks() {
        XCTAssertEqual(
            AICredentialStore.environmentCredential(
                provider: .anthropic,
                environment: ["ANTHROPIC_API_KEY": " anthropic-key "]
            )?.key,
            "anthropic-key"
        )
        XCTAssertEqual(
            AICredentialStore.environmentCredential(
                provider: .deepseek,
                environment: ["DEEPSEEK_API_KEY": "deepseek-key"]
            )?.variable,
            "DEEPSEEK_API_KEY"
        )
        XCTAssertNil(AICredentialStore.environmentCredential(
            provider: .openai,
            environment: ["OPENAI_API_KEY": "  "]
        ))
        XCTAssertNil(AICredentialStore.environmentCredential(
            provider: .none,
            environment: ["OPENAI_API_KEY": "ignored"]
        ))
    }

    func testCredentialFileIsOwnerOnlyAndRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("Credentials/ai-providers.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        try AICredentialStore.save(key: "sk-one", provider: .anthropic, at: url)
        try AICredentialStore.save(key: "sk-two", provider: .openai, at: url)
        XCTAssertEqual(AICredentialStore.stored(at: url), ["anthropic": "sk-one", "openai": "sk-two"])
        let file = try FileManager.default.attributesOfItem(atPath: url.path)
        let folder = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((folder[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        try AICredentialStore.save(key: "", provider: .anthropic, at: url)
        XCTAssertEqual(AICredentialStore.stored(at: url), ["openai": "sk-two"])
    }
}
