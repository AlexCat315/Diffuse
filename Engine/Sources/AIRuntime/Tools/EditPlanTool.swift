import CapabilityRuntime
import Foundation
import IntentRuntime

/// Compatibility multi-step tool. Its schema is assembled exclusively from the
/// same capability contracts used by validation, MCP, and permission planning.
public enum EditPlanTool {
    public static func definition(registry: CapabilityRegistry = .aiDefault) -> [String: Any] {
        [
            "name": "execute_edit_plan",
            "description": "Propose an ordered scene edit plan. This call never bypasses capability validation or confirmation.",
            "input_schema": schema(registry: registry),
        ]
    }

    public static func openAIDefinition(registry: CapabilityRegistry = .aiDefault) -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "execute_edit_plan",
                "description": "Propose an ordered scene edit plan. This call never bypasses capability validation or confirmation.",
                "parameters": schema(registry: registry),
            ] as [String: Any],
        ]
    }

    public static func schema(registry: CapabilityRegistry = .aiDefault) -> [String: Any] {
        jsonSchema(registry: registry).jsonObject()
    }

    /// The typed form is used by registries and transports that need to retain
    /// the contract metadata instead of immediately serializing it.
    public static func jsonSchema(registry: CapabilityRegistry = .aiDefault) -> JSONSchema {
        let stepSchemas = registry.integrityErrors.isEmpty
            ? SceneEditOp.allCases.compactMap { operation -> JSONSchema? in
            guard let descriptor = registry.descriptor(for: operation.capabilityID),
                  descriptor.isAIExposed,
                  !descriptor.access.isWrite || descriptor.inputSchema.isStrictCapabilityInput
            else { return nil }
            var properties = descriptor.inputSchema.properties
            properties["op"] = .string(
                description: "Compatibility operation name.",
                allowedValues: [operation.rawValue]
            )
            return .object(properties: properties,
                           required: Array(Set(descriptor.inputSchema.required + ["op"])),
                           additionalProperties: false)
        } : []
        // An invalid/empty registry must not degrade to an untyped `items: {}`
        // schema. `maxItems: 0` preserves read-only/no-op plans and rejects all
        // mutation steps until registry integrity is restored.
        let stepItemSchema = stepSchemas.isEmpty ? JSONSchema.null() : .choice(stepSchemas)
        let maximumSteps = stepSchemas.isEmpty ? 0 : 100

        return .object(
            properties: [
                "summary": .string(description: "One-line description of the complete plan."),
                "reasoning": .string(description: "Brief explanation for diagnostics."),
                "scene_revision": .integer(
                    description: "Scene revision returned by get_scene_entities; stale plans are rejected.",
                    minimum: 0
                ),
                "steps": .array(of: stepItemSchema,
                                description: "Ordered capability invocations.",
                                maximumItems: maximumSteps),
            ],
            required: ["summary", "scene_revision", "steps"],
            additionalProperties: false
        )
    }
}
