import Foundation

#if canImport(CoreText)
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

    /// URL to the bundled Inter.ttc file, for direct FreeType loading.
    public static var bundledFontURL: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("Inter.ttc")
    }
}

#else

/// Bundled font assets shipped with GuavaUI.
public enum BundledFonts {
    public static let interFamily = "Inter"

    /// No-op on non-Apple platforms — FreeType loads fonts directly.
    public static func register() {}

    /// URL to the bundled Inter.ttc file, for direct FreeType loading.
    public static var bundledFontURL: URL? {
        Bundle.module.resourceURL?.appendingPathComponent("Inter.ttc")
    }
}

#endif
