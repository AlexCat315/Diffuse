import EditorCore
import Foundation

/// Monotonic request counter shared between the panel and any in-flight hover
/// task.
///
/// Held by reference on purpose: the view is a struct that gets copied on every
/// recompose, so a plain `Int` captured by a task would compare against a stale
/// snapshot and never notice that the pointer moved on.
final class ScriptEditorHoverSequence: @unchecked Sendable {
    private(set) var current = 0

    func advance() -> Int {
        current += 1
        return current
    }

    /// Invalidates every request issued before now — used when the pointer
    /// leaves the field or the selection changes.
    func invalidateAll() { current += 1 }
}

/// Turns pointer pauses into a hover popup.
///
/// Two things make hover feel responsive: replies must be dropped when the user
/// has already moved on (otherwise popups flicker between results), and asking
/// about symbols that cannot exist wastes a round-trip per keystroke. Both are
/// handled here, leaving the panel with a single call site.
enum ScriptEditorHoverResolver {
    /// How long the pointer must settle before a request goes out.
    static let settleDelay: Duration = .milliseconds(320)

    /// The position worth asking about, or `nil` when the pointer rests on
    /// punctuation, whitespace, or outside any token.
    static func queryPosition(in source: String, characterIndex: Int) -> ScriptLanguagePosition? {
        guard ScriptSourceCoordinates.identifierRange(in: source, containing: characterIndex) != nil else {
            return nil
        }
        return ScriptSourceCoordinates.position(in: source, atCharacterIndex: characterIndex)
    }

    /// Awaits the settle delay, then queries the language server.
    ///
    /// - Returns: The presentation to adopt, or `nil` when a newer request has
    ///   superseded this one and the caller should leave its state untouched.
    @MainActor
    static func resolve(scriptID: String,
                        source: String,
                        characterIndex: Int,
                        anchor: ScriptEditorHoverAnchor,
                        sequence: ScriptEditorHoverSequence,
                        request: @escaping (ScriptLanguagePosition) async throws -> ScriptHoverResult?)
        async -> ScriptEditorHoverPresentation? {
        guard let position = queryPosition(in: source, characterIndex: characterIndex) else {
            return .hidden
        }
        let token = sequence.advance()

        try? await Task.sleep(for: settleDelay)
        guard sequence.current == token else { return nil }

        let result = try? await request(position)
        guard sequence.current == token else { return nil }

        guard let result, !result.isEmpty else {
            return ScriptEditorHoverPresentation(anchor: anchor,
                                                 content: nil,
                                                 isPending: false,
                                                 message: nil)
        }
        return ScriptEditorHoverPresentation(anchor: anchor,
                                             content: ScriptEditorHoverContent(result),
                                             isPending: false,
                                             message: nil)
    }
}
