import GuavaUIRuntime

public enum TextEditingCommands {
    static let undoKey = "text.undo"
    static let redoKey = "text.redo"
    static let canUndoKey = "text.canUndo"
    static let canRedoKey = "text.canRedo"
    public static var canUndo: Bool? { (FocusChainHolder.current?.commandTarget?.attachments[canUndoKey] as? () -> Bool)?() }
    public static var canRedo: Bool? { (FocusChainHolder.current?.commandTarget?.attachments[canRedoKey] as? () -> Bool)?() }
    @discardableResult public static func undo() -> Bool { perform(undoKey) }
    @discardableResult public static func redo() -> Bool { perform(redoKey) }
    private static func perform(_ key: String) -> Bool {
        guard let action = FocusChainHolder.current?.commandTarget?.attachments[key] as? () -> Void else { return false }
        action(); return true
    }
}
