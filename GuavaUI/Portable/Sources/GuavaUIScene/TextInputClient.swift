/// A focused editor's UTF-16 view for platform input methods.
/// The editor owns text, grapheme boundaries, history and composition.
public struct TextInputClient {
    public struct Snapshot: Codable, Sendable, Equatable {
        public var text: String
        public var selectionStart: Int
        public var selectionEnd: Int
        public var compositionStart: Int
        public var compositionEnd: Int
        public var isSecure = false
        public var isReadOnly = false
        public var isMultiline = false
        public init(text: String, selectionStart: Int, selectionEnd: Int,
                    compositionStart: Int = -1, compositionEnd: Int = -1) {
            self.text = text; self.selectionStart = selectionStart; self.selectionEnd = selectionEnd
            self.compositionStart = compositionStart; self.compositionEnd = compositionEnd
        }
    }
    public let snapshot: () -> Snapshot
    public let select: (Int, Int) -> Void
    public let deleteSurrounding: (Int, Int) -> Void
    public init(snapshot: @escaping () -> Snapshot, select: @escaping (Int, Int) -> Void,
                deleteSurrounding: @escaping (Int, Int) -> Void) {
        self.snapshot = snapshot; self.select = select; self.deleteSurrounding = deleteSurrounding
    }
}
