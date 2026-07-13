import CapabilityRuntime
import Foundation

/// Provider adapters for the dynamic capability exposure protocol. All schemas
/// originate from CapabilityRegistry contracts.
public enum CapabilityToolset {
    public static let searchToolName = "search_capabilities"
    public static let submitToolName = "submit_plan"

    public static func anthropicTools(snapshot: CapabilityExposureSnapshot,
                                      registry: CapabilityRegistry = .default) -> [[String: Any]] {
        frameworkContracts(registry: registry).map { name, contract in
            ["name": name,
             "description": contract.description,
             "input_schema": contract.inputSchema.jsonObject()]
        } + snapshot.contracts
            .filter { !$0.id.hasPrefix("system.") }
            .map { $0.anthropicToolDefinition() }
    }

    public static func openAITools(snapshot: CapabilityExposureSnapshot,
                                   registry: CapabilityRegistry = .default) -> [[String: Any]] {
        frameworkContracts(registry: registry).map { name, contract in
            ["type": "function",
             "function": [
                "name": name,
                "description": contract.description,
                "parameters": contract.inputSchema.jsonObject(),
             ] as [String: Any]]
        } + snapshot.contracts
            .filter { !$0.id.hasPrefix("system.") }
            .map { $0.openAIToolDefinition() }
    }

    public static func openAIResponsesTools(snapshot: CapabilityExposureSnapshot,
                                            registry: CapabilityRegistry = .default) -> [[String: Any]] {
        frameworkContracts(registry: registry).map { name, contract in
            contract.openAIResponsesToolDefinition(name: name)
        } + snapshot.contracts
            .filter { !$0.id.hasPrefix("system.") }
            .map { $0.openAIResponsesToolDefinition() }
    }

    public static func searchResult(contracts: [CapabilityContract]) -> String {
        let entries: [[String: Any]] = contracts.map {
            [
                "id": $0.id,
                "version": $0.version,
                "tool_name": $0.toolName,
                "title": $0.title,
                "description": $0.description,
                "domain": $0.domain,
                "access": $0.access.rawValue,
                "schema_hash": $0.schemaHash,
            ]
        }
        let object: [String: Any] = ["count": entries.count, "capabilities": entries]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }

    private static func frameworkContracts(registry: CapabilityRegistry)
        -> [(String, CapabilityContract)] {
        guard registry.integrityErrors.isEmpty else { return [] }
        return [
            (searchToolName, "system.search_capabilities"),
            (submitToolName, "system.submit_plan"),
        ].compactMap { toolName, capabilityID in
            registry.descriptor(for: capabilityID).map { (toolName, $0.contract) }
        }
    }
}
