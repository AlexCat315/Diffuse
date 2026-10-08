import Foundation

public extension Node {
    /// Programmatic and pointer focus remain available outside sequential Tab traversal.
    var isTabStop: Bool {
        get { attachments["__focus.tabStop"] as? Bool ?? true }
        set { attachments["__focus.tabStop"] = newValue }
    }
}
