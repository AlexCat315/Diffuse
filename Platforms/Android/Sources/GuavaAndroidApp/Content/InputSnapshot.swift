import Foundation
import GuavaUIComposeCore

extension HostedScene {
    private struct InputSnapshot: Encodable {
        let focused: String?
        let editor: TextInputClient.Snapshot?
    }

    /// The IME and touch routing need only the focused editor, not a traversal
    /// and serialization of every semantic node and diagnostic control bound.
    func inputSnapshot() -> String {
        let value = InputSnapshot(focused: focusedID, editor: editorSnapshot)
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
