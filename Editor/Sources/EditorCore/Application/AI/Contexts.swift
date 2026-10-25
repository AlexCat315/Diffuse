import AIRuntime
import Foundation
import PluginRuntime

extension EditorApplication {
    /// The package context the active agent lists, read just before a request.
    /// A source that fails is left out and reported; the request still goes ahead.
    @MainActor
    func agentContextSections(target: EditorAgentTaskTarget) async -> [SessionContextSection] {
        guard let agent = agentCatalog.agent(id: store.state.assistant.aiSettings.agentID),
              !agent.packageContexts.isEmpty else { return [] }
        let selection = String(decoding: (try? JSONEncoder().encode(
            target.selectedEntityIDs.sorted().map { "scene:\($0)" })) ?? Data("[]".utf8), as: UTF8.self)
        var sections: [SessionContextSection] = []
        for package in pluginSession.contributions.contexts.snapshot.values.map(\.value) {
            for context in (try? package.manifest.contributes.decode(AIContextContributionPoint.self)) ?? []
            where agent.packageContexts.contains(context.id) {
                do {
                    let payload = try await readEntryPoint(pluginID: package.manifest.id, entryPoint: context.entryPoint,
                                                           event: "onAIChat",
                                                           input: ["workspace": target.workspace.rawValue, "selection": selection])
                    // The entry point returns its text as a JSON string.
                    let text = try JSONDecoder().decode(String.self, from: payload)
                    guard !text.isEmpty else { continue }
                    sections.append(SessionContextSection(title: context.title,
                                                          text: Self.prefix(text, bytes: context.byteLimit)))
                } catch {
                    logConsole("\(context.title) context was left out", severity: .warning,
                               detail: error.localizedDescription)
                }
            }
        }
        return sections
    }

    /// The longest prefix within `bytes` UTF-8 bytes that does not split a scalar.
    static func prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var cut = bytes
        while cut > 0 {
            if let prefix = String(text.utf8.prefix(cut)) { return prefix }
            cut -= 1
        }
        return ""
    }
}
