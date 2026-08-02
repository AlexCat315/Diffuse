@testable import EditorCore
import XCTest

final class EditorAISettingsTests: XCTestCase {
    func testEnvironmentCredentialsUseGuavaOverrideBeforeStandardVariable() {
        let credential = AIKeychain.environmentCredential(
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
            AIKeychain.environmentCredential(
                provider: .anthropic,
                environment: ["ANTHROPIC_API_KEY": " anthropic-key "]
            )?.key,
            "anthropic-key"
        )
        XCTAssertEqual(
            AIKeychain.environmentCredential(
                provider: .deepseek,
                environment: ["DEEPSEEK_API_KEY": "deepseek-key"]
            )?.variable,
            "DEEPSEEK_API_KEY"
        )
        XCTAssertNil(AIKeychain.environmentCredential(
            provider: .openai,
            environment: ["OPENAI_API_KEY": "  "]
        ))
        XCTAssertNil(AIKeychain.environmentCredential(
            provider: .none,
            environment: ["OPENAI_API_KEY": "ignored"]
        ))
    }
}
