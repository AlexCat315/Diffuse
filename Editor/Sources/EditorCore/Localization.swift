import Foundation

public enum EditorLocalizationPreferences {
    nonisolated(unsafe) public static var language: EditorLanguage = .system
}

/// Resolves a localized string from the EditorCore module bundle.
///
/// Usage: `label: L("Name")`
func L(_ key: String) -> String {
    if let lproj = EditorLocalizationPreferences.language.lprojName,
       let path = Bundle.module.path(forResource: lproj, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    return Bundle.module.localizedString(forKey: key, value: key, table: nil)
}
