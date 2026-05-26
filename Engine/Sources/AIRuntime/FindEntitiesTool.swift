import Foundation

/// Tool definition for the `find_entities` tool.
/// Lets the AI search by name substring or kind when the scene exceeds the entity prompt limit.
public enum FindEntitiesTool {
    /// Anthropic Messages API format.
    public static func definition() -> [String: Any] {
        [
            "name": "find_entities",
            "description": "Search scene entities by name substring, kind, component, or spatial proximity. Returns id, name, kind, components, position, worldPosition, and parentRef for each match. Use when you need to find an entity that may not be visible in the truncated entity list.",
            "input_schema": schema(),
        ]
    }

    /// OpenAI / DeepSeek chat-completions format.
    public static func openAIDefinition() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "find_entities",
                "description": "Search scene entities by name substring, kind, component, or spatial proximity. Returns id, name, kind, components, position, worldPosition, and parentRef for each match. Use when you need to find an entity that may not be visible in the truncated entity list.",
                "parameters": schema(),
            ] as [String: Any],
        ]
    }

    private static func schema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "description": "Substring to match against entity names (case-insensitive). Omit to match all names.",
                ] as [String: Any],
                "kind": [
                    "type": "string",
                    "description": "Exact entity kind to filter by (e.g. 'Static Mesh', 'Camera', 'Point Light'). Omit to match all kinds.",
                ] as [String: Any],
                "component": [
                    "type": "string",
                    "description": "Component tag to filter by (e.g. 'light', 'camera', 'rigidbody', 'collider', 'audio_source', 'animation', 'script', 'constraint'). Only entities that have this component are returned.",
                ] as [String: Any],
                "near_position": [
                    "type": "array",
                    "items": ["type": "number"] as [String: Any],
                    "description": "[x, y, z] world-space centre point. When provided together with near_radius, only entities within that radius are returned.",
                ] as [String: Any],
                "near_radius": [
                    "type": "number",
                    "description": "Search radius in metres around near_position. Requires near_position. Entities beyond this distance are excluded.",
                ] as [String: Any],
                "limit": [
                    "type": "integer",
                    "description": "Maximum number of results to return (1–200, default 20).",
                ] as [String: Any],
            ] as [String: Any],
        ]
    }
}
