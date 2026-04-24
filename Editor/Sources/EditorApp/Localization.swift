import Foundation
import EditorCore

/// Resolves a localized string from the EditorApp module bundle.
///
/// Usage: `Text(L("No selection"))`
func L(_ key: String) -> String {
    if let lproj = EditorLocalizationPreferences.language.lprojName,
       let path = Bundle.module.path(forResource: lproj, ofType: "lproj"),
       let bundle = Bundle(path: path) {
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }
    return Bundle.module.localizedString(forKey: key, value: key, table: nil)
}
