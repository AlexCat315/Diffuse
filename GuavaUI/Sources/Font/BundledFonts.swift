import Foundation

/// Font bundling shim.
///
/// GuavaUI no longer ships a bundled UI font — each platform uses its own
/// system default (Segoe UI on Windows, San Francisco on macOS, a system sans
/// on Linux), resolved by `SystemFontDefaults` / `FontProvider`. This type is
/// kept as a no-op so existing call sites (and the `GuavaUIBundledFonts`
/// target dependency) compile unchanged.
public enum BundledFonts {
    /// No font is bundled; callers should fall back to the system UI font.
    public static func register() {}

    /// No bundled font URL anymore.
    public static var bundledFontURL: URL? { nil }
}
