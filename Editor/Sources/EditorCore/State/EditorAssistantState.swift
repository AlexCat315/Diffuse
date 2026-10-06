import Foundation
import IntentRuntime

/// Owns the editor assistant state and its persistence defaults.
public struct EditorAssistantState: Codable, Sendable {
    public var pendingConfirmationRequest: ConfirmationRequestBatch? = nil
    public var aiSettings: EditorAISettings = .default
    public var capabilitySettings: EditorCapabilitySettings = .default
    public var pluginManagement: EditorPluginManagementState = .idle
    public var aiStatusMessage: String? = nil
    public var aiWarnings: [String] = []
    public var chatMessages: [AIChatMessage] = []

    public init(_ configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
    }

    private enum CodingKeys: String, CodingKey {
        case pendingConfirmationRequest
        case capabilitySettings
        case aiStatusMessage
        case aiWarnings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pendingConfirmationRequest = try container.decodeIfPresent(
            ConfirmationRequestBatch.self, forKey: .pendingConfirmationRequest)
        capabilitySettings =
            try container.decodeIfPresent(EditorCapabilitySettings.self, forKey: .capabilitySettings)
            ?? capabilitySettings
        aiStatusMessage = try container.decodeIfPresent(String.self, forKey: .aiStatusMessage)
        aiWarnings = try container.decodeIfPresent([String].self, forKey: .aiWarnings) ?? aiWarnings
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(pendingConfirmationRequest, forKey: .pendingConfirmationRequest)
        try container.encode(capabilitySettings, forKey: .capabilitySettings)
        try container.encodeIfPresent(aiStatusMessage, forKey: .aiStatusMessage)
        try container.encode(aiWarnings, forKey: .aiWarnings)
    }
}
