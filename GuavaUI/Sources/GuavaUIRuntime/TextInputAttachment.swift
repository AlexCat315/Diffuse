import CoreGraphics
import EngineKernel

/// Shared attachment keys for focused text-input primitives.
public typealias TextInputAreaResolver = (Node, CGPoint) -> TextInputArea?
public typealias TextInputFocusChangeHandler = (Bool) -> Void
public typealias TextInputEditingChangeHandler = (Bool) -> Void

public enum TextInputAttachmentKey {
    /// `Node.attachments` entry carrying the current focused text input area.
    public static let area = "__text_input_area"
    /// `Node.attachments` entry carrying a commit-phase resolver that maps a
    /// laid-out node into the platform IME anchor rect.
    public static let areaResolver = "__text_input_area_resolver"
    /// `Node.attachments` entry carrying a focus change sink owned by the host
    /// view state rather than the draw path.
    public static let focusChangeHandler = "__text_input_focus_change_handler"
    /// `Node.attachments` entry carrying the current editing/composition state
    /// sink owned by the host view state.
    public static let editingChangeHandler = "__text_input_editing_change_handler"
}