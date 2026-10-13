import Foundation

struct ApplicationIdentity: Codable, Equatable {
    let id: String
    let name: String

    func validate() throws {
        guard id.range(of: #"^[a-z][a-z0-9]*(?:\.[a-z][a-z0-9]*)+$"#, options: .regularExpression) != nil else {
            throw ToolError.invalid("application.id must be a lowercase reverse-domain identifier, such as com.example.myapp")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ToolError.invalid("application.name must be a nonempty printable label")
        }
    }
}
