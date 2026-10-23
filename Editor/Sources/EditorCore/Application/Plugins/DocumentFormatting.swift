import Foundation
import PluginRuntime

public enum DocumentFormattingError: LocalizedError, Equatable {
    case unavailable
    case inputTooLarge
    case unexpectedResult

    public var errorDescription: String? {
        switch self {
        case .unavailable: "No enabled plugin formats this language."
        case .inputTooLarge: "The document exceeds the 64 KiB formatting limit."
        case .unexpectedResult: "The formatter returned an unexpected result."
        }
    }
}

extension EditorApplication {
    /// Runs the language's format entry point when its package is mounted.
    /// A language without a contribution, or a disabled package, leaves the
    /// document unchanged.
    @MainActor
    public func formatDocument(languageID: String, text: String) async throws -> String? {
        guard let format = LanguageCatalog.format(forLanguageID: languageID),
              let binding = pluginSession.bindings[format.pluginID],
              let client = pluginSession.hostClient else {
            return nil
        }
        guard text.utf8.count <= 64 * 1_024 else { throw DocumentFormattingError.inputTooLarge }
        let input = try JSONEncoder().encode(["text": text])
        let capabilityID = format.pluginID + "." + format.entryPoint
        let data = try await Task.detached(priority: .userInitiated) {
            let result = try client.prepareCapability(binding: binding,
                                                      capabilityID: capabilityID,
                                                      input: input,
                                                      querySnapshot: nil)
            guard case let .read(data) = result else {
                throw DocumentFormattingError.unexpectedResult
            }
            return data
        }.value
        // Read results cross the host as JSON; the capability returns the
        // formatted text as a JSON string.
        guard let formatted = try? JSONDecoder().decode(String.self, from: data) else {
            throw DocumentFormattingError.unexpectedResult
        }
        return formatted
    }
}
