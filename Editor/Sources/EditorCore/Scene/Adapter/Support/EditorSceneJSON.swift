import Foundation
import SIMDCompat


func normalizedJSONCommitText(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "{}" : trimmed
}

func isValidJSONDocument(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8) else { return false }
    do {
        _ = try JSONSerialization.jsonObject(with: data)
        return true
    } catch {
        return false
    }
}
