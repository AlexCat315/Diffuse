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

    func testKeychainFailuresExplainTheNextStep() {
        let denied = AIKeychainError.operationFailed(-25293).errorDescription ?? ""
        XCTAssertTrue(denied.contains("refused access"))
        XCTAssertTrue(denied.contains("com.guava.editor.ai-provider"))
        XCTAssertEqual(AIKeychainError.operationFailed(-25308).errorDescription, denied)
        XCTAssertTrue((AIKeychainError.operationFailed(-128).errorDescription ?? "").contains("cancelled"))
        XCTAssertTrue((AIKeychainError.operationFailed(-1).errorDescription ?? "").contains("-1"))
    }
}
