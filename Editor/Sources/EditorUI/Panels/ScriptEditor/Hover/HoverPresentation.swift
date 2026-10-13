import EditorCore
import GuavaUIRuntime

/// Window-space point the hover popup should hang from — normally just below
/// the glyph the pointer is resting on.
struct ScriptEditorHoverAnchor: Equatable {
    var windowX: Float = 0
    var windowY: Float = 0
}

/// Popup body split into a signature and optional prose.
///
/// Splitting here keeps the drawing pass dumb: it lays out two blocks with
/// different font slots instead of parsing the server's markup again every
/// frame.
struct ScriptEditorHoverContent: Equatable {
    var declaration: String
    var detail: String?

    init(declaration: String, detail: String? = nil) {
        self.declaration = declaration
        self.detail = detail
    }

    init(_ result: ScriptHoverResult) {
        // ``ScriptMarkdownText`` already joined the declaration and prose with a
        // blank line, so splitting on it recovers the two parts.
        let blocks = result.plainText
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        declaration = blocks.first ?? ""
        detail = blocks.count > 1 ? blocks.dropFirst().joined(separator: "\n") : nil
    }
}

/// Everything the hover overlay needs to render, and nothing else.
struct ScriptEditorHoverPresentation: Equatable {
    var anchor: ScriptEditorHoverAnchor?
    var content: ScriptEditorHoverContent?
    /// True while a request is in flight, so the popup can show a placeholder
    /// instead of flickering empty and then filling in.
    var isPending = false
    /// Shown when the server had nothing to say — kept distinct from "no hover"
    /// so the popup can be dismissed rather than stuck loading.
    var message: String?

    static let hidden = ScriptEditorHoverPresentation()

    var isVisible: Bool { content != nil || message != nil }

    /// Blocks handed to the drawing pass, in order.
    ///
    /// A pending request deliberately yields nothing — showing an empty bubble
    /// for 300 ms reads as a glitch, whereas having the popup appear when the
    /// answer lands reads as responsive.
    var textBlocks: [ScriptHoverTextBlock] {
        if let content {
            var blocks = [ScriptHoverTextBlock(text: content.declaration, role: .signature)]
            if let detail = content.detail, !detail.isEmpty {
                blocks.append(ScriptHoverTextBlock(text: detail, role: .body))
            }
            return blocks
        }
        if let message {
            return [ScriptHoverTextBlock(text: message, role: .body)]
        }
        return []
    }
}

struct ScriptHoverTextBlock: Equatable {
    let text: String
    let role: ScriptHoverTextRole
}

enum ScriptHoverTextRole: Equatable {
    /// Declaration line — fixed-width, primary foreground.
    case signature
    /// Prose, status notes, and messages.
    case body
}
