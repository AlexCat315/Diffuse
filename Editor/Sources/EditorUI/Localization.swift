import Foundation
import EditorCore

/// Resolves a localized string from the EditorApp module bundle.
///
/// Usage: `Text(L("No selection"))`
func L(_ key: String) -> String {
    if let lproj = EditorLocalizationPreferences.language.lprojName {
        for candidate in [lproj, lproj.lowercased()] {
            if let path = EditorAppResourceBundle.bundle.path(
                forResource: candidate,
                ofType: "lproj"
            ),
               let bundle = Bundle(path: path) {
                return bundle.localizedString(forKey: key, value: key, table: nil)
            }
        }
    }
    return EditorAppResourceBundle.bundle.localizedString(
        forKey: key,
        value: key,
        table: nil
    )
}
