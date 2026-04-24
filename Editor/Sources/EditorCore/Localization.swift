import Foundation

/// Resolves a localized string from the EditorCore module bundle.
///
/// Usage: `label: L("Name")`
func L(_ key: String) -> String {
    Bundle.module.localizedString(forKey: key, value: key, table: nil)
}
