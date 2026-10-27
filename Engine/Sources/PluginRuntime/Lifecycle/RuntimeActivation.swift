import Foundation
import CapabilityRuntime

extension PluginManager {
    var availableCapabilities: [String: Int] {
        var values = hostCapabilities
        for inspection in enabledInspections {
            for contract in inspection.contracts { values[contract.id] = contract.version }
        }
        return values
    }

    static func activationEvents(for entry: Entry) -> Set<String> {
        let manifest = entry.package.manifest
        var result = Set(manifest.activation)
        for service in (try? manifest.contributes.decode(PluginServiceContributionPoint.self)) ?? [] {
            result.insert("onService:" + service.id)
        }
        for language in (try? manifest.contributes.decode(LanguageContributionPoint.self)) ?? [] {
            if language.server != nil || language.format != nil { result.insert("onLanguage:" + language.id) }
        }
        for provider in (try? manifest.contributes.decode(AIProviderContributionPoint.self)) ?? [] {
            result.insert("onAIProvider:" + provider.id)
        }
        for task in (try? manifest.contributes.decode(TaskContributionPoint.self)) ?? [] {
            result.insert("onCommand:" + task.id)
        }
        for vcs in (try? manifest.contributes.decode(VersionControlContributionPoint.self)) ?? [] {
            result.insert("onCommand:" + vcs.id)
        }
        for command in (try? manifest.contributes.decode(CommandContributionPoint.self)) ?? [] {
            result.insert("onCommand:" + command.id)
        }
        for panel in (try? manifest.contributes.decode(PanelContributionPoint.self)) ?? [] where panel.entryPoint != nil {
            result.insert("onView:" + panel.id)
        }
        for view in (try? manifest.contributes.decode(DocumentViewContributionPoint.self)) ?? [] {
            result.insert("onView:" + view.id)
        }
        // Harnesses and context sources serve chat turns.
        if !((try? manifest.contributes.decode(AIHarnessContributionPoint.self)) ?? []).isEmpty
            || !((try? manifest.contributes.decode(AIContextContributionPoint.self)) ?? []).isEmpty { result.insert("onAIChat") }
        for contract in entry.inspection.contracts {
            let name = String(contract.id.dropFirst(manifest.id.count + 1))
            if name == "components" { result.insert("onStartup") }
            if manifest.exposesToAI(entryPoint: name) {
                result.insert("onAIChat")
                result.insert("onAITool:" + contract.id)
            }
        }
        return result
    }

    static func matches(_ declaration: String, _ event: String) -> Bool {
        guard declaration.hasPrefix("onWorkspaceContains:"), event.hasPrefix("onWorkspaceContains:") else {
            return declaration == event
        }
        let pattern = String(declaration.dropFirst("onWorkspaceContains:".count))
        let path = String(event.dropFirst("onWorkspaceContains:".count))
        var expression = "^"
        for character in pattern {
            switch character {
            case "*": expression += ".*"
            case "?": expression += "."
            default: expression += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return path.range(of: expression + "$", options: .regularExpression) != nil
    }

    @MainActor
    func activateEntry(_ id: String, visiting: Set<String>) async throws {
        guard let entry = lock.withLock({ entries[id] }), entry.scope != nil else {
            throw PluginManagerError.notEnabled(id)
        }
        if entry.binding != nil || entry.package.runtime == nil { return }
        guard !visiting.contains(id) else { throw PluginManagerError.activationCycle(id) }
        var visited = visiting
        visited.insert(id)
        do {
            guard let driver = lock.withLock({ driver }), let authorization = entry.authorization else {
                throw PluginManagerError.runtimeUnavailable
            }
            for requirement in entry.package.manifest.requires {
                let provider: String? = switch requirement.kind {
                case .plugin: requirement.id
                case .capability: enabledInspections.first { $0.contracts.contains { $0.id == requirement.id } }?.manifest.id
                }
                if let provider { try await activateEntry(provider, visiting: visited) }
            }
            let generation = lock.withLock { epoch }
            let activated = try await driver.activate(entry.package.rootURL, authorization)
            let binding = activated.binding
            let accepted = lock.withLock {
                guard binding.inspection == entry.inspection, !stopped,
                      epoch == generation, entries[id] === entry else { return false }
                entry.binding = binding; entry.failure = nil
                return true
            }
            guard accepted else {
                try? activated.registration?.dispose()
                try? await driver.deactivate(binding)
                throw PluginAuthorizationError.noLongerValid
            }
            if let registration = activated.registration { try entry.scope?.own(registration) }
        } catch {
            // A failed activation must not leave its declarations usable while
            // dependent packages assume its runtime is available.
            try? await withdraw(dependentClosure(of: id), failure: String(describing: error))
            throw error
        }
    }
}
