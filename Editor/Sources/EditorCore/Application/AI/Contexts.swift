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
                    let text = try await contextText(context, in: package, content: target.content.rawValue,
                                                     selection: selection)
                    guard !text.isEmpty else { continue }
                    sections.append(SessionContextSection(title: context.title,
                                                          text: Self.prefix(text, bytes: context.byteLimit)))
                } catch StepError.toolMissing {
                    // Without the tool installed the source has nothing to say.
                    continue
                } catch {
                    logConsole("\(context.title) context was left out", severity: .warning,
                               detail: error.localizedDescription)
                }
            }
        }
        return sections
    }

    /// A plain entry point is called once; one with a process permission is
    /// driven through the step protocol, so the editor runs its commands.
    @MainActor
    private func contextText(_ context: AIContextContribution, in package: ValidatedPluginPackage,
                             content: String, selection: String) async throws -> String {
        guard let process = package.manifest.host.processes.first(where: { $0.entryPoints.contains(context.entryPoint) }) else {
            let payload = try await readEntryPoint(pluginID: package.manifest.id, entryPoint: context.entryPoint,
                                                   event: "onAIChat", input: ["content": content, "selection": selection])
            // The entry point returns its text as a JSON string.
            return try JSONDecoder().decode(String.self, from: payload)
        }
        let provider = StepProvider(pluginID: package.manifest.id, title: context.title, package: package.rootURL,
                                    entryPoint: context.entryPoint, activationEvent: "onAIChat", process: process)
        let plugin = try StepPlugins(runtime: pluginSession.runtime)
            .plugin(for: provider, workspace: URL(fileURLWithPath: projectDirectory, isDirectory: true))
        switch try await plugin.perform(["op": "context", "content": content, "selection": selection]) {
        case let .result(data): return try JSONDecoder().decode(String.self, from: data)
        case let .output(text): return text
        }
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
