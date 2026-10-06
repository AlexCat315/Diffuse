import Foundation

/// System cursor styles a `Shell` is expected to support. The set is the
/// intersection of macOS / Windows / Linux defaults so callers can rely on
/// every value being honoured (or no-op'd silently) on every backend.
public enum SystemCursor: Sendable, Hashable {
    case arrow
    /// Pointing finger — typical for clickable buttons / links.
    case pointer
    /// I-beam — typical for editable text.
    case ibeam
    case crosshair
    case wait
    case progress
    case notAllowed
    case move
    /// Horizontal resize (↔). Used for vertical splitter divider handles.
    case resizeHorizontal
    /// Vertical resize (↕). Used for horizontal splitter divider handles.
    case resizeVertical
    /// `↘ / ↖` diagonal resize.
    case resizeNWSE
    /// `↙ / ↗` diagonal resize.
    case resizeNESW
}
