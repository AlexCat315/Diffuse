import Foundation
import CapabilityRuntime
import IntentRuntime

/// Tool definition for the `find_entities` tool.
/// Lets the AI search by name substring or kind when the scene exceeds the entity prompt limit.
public enum FindEntitiesTool {
    /// Anthropic Messages API format.
    public static func definition() -> [String: Any] {
        [
            "name": "find_entities",
            "description": "Search scene entities by name substring, kind, component, or spatial proximity. Returns id, name, kind, components, position, eulerDegrees, scale, worldPosition, parentRef, and all authored property values (light color/range/angles, mesh visibility/material, audio, animation, physics, collider material/layers, script bindings) for each match. Use when you need to find entities that may not be visible in the truncated entity list.",
            "input_schema": schema(),
        ]
    }

    /// OpenAI / DeepSeek chat-completions format.
    public static func openAIDefinition() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "find_entities",
                "description": "Search scene entities by name substring, kind, component, or spatial proximity. Returns id, name, kind, components, position, eulerDegrees, scale, worldPosition, parentRef, and all authored property values (light color/range/angles, mesh visibility/material, audio, animation, physics, collider material/layers, script bindings) for each match. Use when you need to find entities that may not be visible in the truncated entity list.",
                "parameters": schema(),
            ] as [String: Any],
        ]
    }

    private static func schema() -> [String: Any] {
        CapabilityRegistry.aiDefault.descriptor(for: "scene.find_entities")?.inputSchema.jsonObject()
            ?? JSONSchema.object(properties: [:]).jsonObject()
    }
}
