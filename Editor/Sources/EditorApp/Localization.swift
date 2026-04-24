import Foundation

/// Resolves a localized string from the EditorApp module bundle.
///
/// Usage: `Text(L("No selection"))`
func L(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
}
