@testable import AIRuntime
import Foundation
import Testing

@Suite("Plugin changes in an AI session")
struct PluginSessionUpdateTests {
    @Test("capability replacement preserves conversation and model configuration")
    func keepsConversation() async throws {
        let session = Session(config: SessionConfig(apiKey: "fixture", model: "fixture-model",
            baseURL: URL(string: "https://example.invalid")!, apiFormat: .anthropic))
        await session.recordTurn(ConversationTurn(kind: .userText("Keep this conversation")))
        await session.replacePluginCapabilities(nil, querySnapshotProvider: nil)
        let history = await session.historySnapshot()
        #expect(history.count == 1)
        let turn = try #require(history.first)
        guard case let .userText(text) = turn.kind else { Issue.record("lost user turn"); return }
        #expect(text == "Keep this conversation")
        #expect(await session.config.model == "fixture-model")
    }
}
