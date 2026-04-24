import Foundation
import CoreText

/// Bundled font assets shipped with GuavaUI.
///
/// Call `BundledFonts.register()` once before creating any `FontProvider` or
/// `TextEnvironment`. `AppRuntime` does this automatically; host applications
/// that bypass `AppRuntime` must call it themselves.
public enum BundledFonts {
    /// The family name exposed by the bundled Inter font collection.
    public static let interFamily = "Inter"

    private static let once: Void = {
        guard let url = Bundle.module
            .resourceURL?
            .appendingPathComponent("Inter.ttc")
        else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }()

    /// Registers all bundled fonts with CoreText for the current process.
    /// Safe to call multiple times; registration only occurs once.
    public static func register() {
        _ = once
    }
}
