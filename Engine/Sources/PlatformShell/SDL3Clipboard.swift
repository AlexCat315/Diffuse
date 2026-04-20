import CSDL3
import Foundation

/// Thin Swift wrapper around SDL3 clipboard text APIs.
///
/// SDL3 returns clipboard text as a freshly-allocated UTF-8 string that the
/// caller must release via `SDL_free`; both the empty-string ("no clipboard
/// content") and `nil` ("error") cases are normalised to `nil` here.
public enum SDL3Clipboard {

    public static func read() -> String? {
        guard let raw = SDL_GetClipboardText() else { return nil }
        defer { SDL_free(raw) }
        let s = String(cString: raw)
        return s.isEmpty ? nil : s
    }

    @discardableResult
    public static func write(_ text: String) -> Bool {
        text.withCString { SDL_SetClipboardText($0) }
    }
}
