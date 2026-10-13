import Foundation
import GuavaUIComposeCore

extension DemoScene {
    private struct InputSnapshot: Encodable {
        let focused: String?
        let editor: TextInputClient.Snapshot?
    }

    var focusedID: String? {
        context.focusChain.focused.map {
            $0.attachments[LayoutDebugAttachmentKey.debugName] as? String ?? "field.\($0.id)"
        }
    }

    /// The IME and touch routing need only the focused editor, not a traversal
    /// and serialization of every semantic node and diagnostic control bound.
    func inputSnapshot() -> String {
        let value = InputSnapshot(focused: focusedID, editor: editorSnapshot)
        guard let data = try? JSONEncoder().encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
