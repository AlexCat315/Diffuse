import GuavaUIRuntime

/// Authored layout settings. Cursor, selection, IME and scrolling remain node-local.
public struct TextFieldLayout: Equatable {
    public var axis: TextField.Axis = .horizontal
    public var maxVisibleLines: Int = 6
    public var idealWidth: Float = 160
    public var wrapsLines = true
    public init() {}

    mutating func validate() { maxVisibleLines = max(1, maxVisibleLines) }
}

public struct TextFieldBehavior: Equatable {
    public var disabled = false
    public var readOnly = false
    public var secure = false
    public var clearable = false
    public var maxLength: Int?
    public init() {}

    mutating func validate() { maxLength = maxLength.map { max(0, $0) } }
}

/// Decoration is independent of editing behavior and can be copied as a group.
public struct TextFieldDecoration: Equatable {
    public var size: TextField.Size = .automatic
    public var showWordLimit = false
    public var prefix: String?
    public var suffix: String?
    public var prepend: String?
    public var append: String?
    public var textColor: Color?
    public var placeholderColor: Color?
    public var cursorColor: Color?
    public var selectionColor: Color?
    public init() {}
}

public struct TextFieldCodeEditing {
    public var diagnostics = TextDiagnostics.empty
    public var onRequestCompletion: TextCompletionProvider?
    public var onAcceptCompletion: ((TextCompletionItem) -> Void)?
    /// F1 requests documentation at the visible caret, also in read-only code.
    public var onRequestHover: ((TextFieldHoverAnchor) -> Void)?
    public var showsLineNumbers = false
    public var indentationWidth: Int?
    public var editHistory: TextEditHistory?
    public var lineNumberColor: Color?
    public var lineNumberGutterColor: Color?
    public var syntaxRevision: AnyHashable?
    public var syntaxColorAtUTF8Offset: ((TextBuffer, Int) -> Color?)?
    public init() {}

    mutating func validate() { indentationWidth = indentationWidth.map { max(1, min(8, $0)) } }
}

/// One-shot navigation requests, separate from the live caret/selection state.
public struct TextFieldNavigation {
    public var focusRequestID: AnyHashable?
    public var caretRequestID: AnyHashable?
    public var caretRequestIndex: Int?
    public init() {}
}

public struct TextFieldEvents {
    public var onSubmit: (() -> Void)?
    public var onKeyDown: ((KeyEvent) -> Bool)?
    public var onCancel: (() -> Void)?
    public var onChange: ((TextBuffer) -> Void)?
    public var onHoverChange: ((TextFieldHoverAnchor?) -> Void)?
    public var onCaretChange: ((TextFieldCaretState) -> Void)?
    public var onFocus: (() -> Void)?
    public var onBlur: (() -> Void)?
    public var onClear: (() -> Void)?
    public init() {}
}
