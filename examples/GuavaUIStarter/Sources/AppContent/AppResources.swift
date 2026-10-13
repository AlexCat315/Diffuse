import Foundation
import GuavaUI

/// Uses the same resource lookup in desktop, Android Debug and Android Release.
enum AppResources {
    static let bundle = ApplicationResources.required(named: "GuavaApplication_AppContent")
    static let welcome: String = {
        guard let url = bundle.url(forResource: "welcome", withExtension: "txt", subdirectory: "Assets"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing bundled Assets/welcome.txt")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
}
