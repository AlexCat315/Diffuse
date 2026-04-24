import Foundation

/// A type-safe key for localized strings.
///
/// Pass one to `Text` or `Button` to display a UI string resolved from a
/// `.strings` table at a given bundle:
///
/// ```swift
/// Text(LocalizedStringKey("Save", bundle: Bundle.module))
/// Button(LocalizedStringKey("Cancel", bundle: Bundle.module)) { … }
/// ```
///
/// `ExpressibleByStringLiteral` lets you write bare string literals where a
/// `LocalizedStringKey` is expected; those literals resolve against `.main`.
public struct LocalizedStringKey: Sendable, ExpressibleByStringLiteral {
    public let key: String
    public let bundle: Bundle
    public let table: String?

    public init(_ key: String, bundle: Bundle = .main, table: String? = nil) {
        self.key = key
        self.bundle = bundle
        self.table = table
    }

    public init(stringLiteral value: String) {
        self.init(value, bundle: .main)
    }

    /// Resolves the key against the bundle. Falls back to `key` when no
    /// translation exists so UI always shows something readable.
    public var resolved: String {
        bundle.localizedString(forKey: key, value: key, table: table)
    }
}
