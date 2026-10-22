@testable import AIRuntime
import Foundation
import Testing

@Test func completionTextReadsEveryProviderFormat() throws {
    let anthropic = #"{"content":[{"type":"text","text":"Hello "},{"type":"tool_use","id":"x"},{"type":"text","text":"world"}]}"#
    #expect(try Session.completionText(from: Data(anthropic.utf8), format: .anthropic) == "Hello world")
    let chat = #"{"choices":[{"message":{"role":"assistant","content":"Fix typo"}}]}"#
    #expect(try Session.completionText(from: Data(chat.utf8), format: .openAICompatible) == "Fix typo")
    let responses = #"{"output":[{"type":"reasoning"},{"type":"message","content":[{"type":"output_text","text":"Done"}]}]}"#
    #expect(try Session.completionText(from: Data(responses.utf8), format: .openAIResponses) == "Done")
    #expect(throws: (any Error).self) { try Session.completionText(from: Data("[]".utf8), format: .anthropic) }
}

@Test func versionControlToolsAreDeclaredForTheAgent() {
    for name in ["vcs_status", "vcs_diff", "vcs_log"] {
        #expect(ProjectToolset.definition(named: name)?.readOnly == true)
    }
    #expect(ProjectToolset.definition(named: "vcs_commit")?.readOnly == false)
}
