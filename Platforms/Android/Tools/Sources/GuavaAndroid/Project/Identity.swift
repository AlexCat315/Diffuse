import Foundation

struct ApplicationIdentity: Codable {
    var applicationID: String
    var name = "GuavaUI Application"

    enum CodingKeys: String, CodingKey { case applicationID = "application_id", name }

    init(applicationID: String, name: String = "GuavaUI Application") {
        self.applicationID = applicationID
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        applicationID = try values.decode(String.self, forKey: .applicationID)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? "GuavaUI Application"
    }

    func validate() throws {
        let pattern = #"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$"#
        guard applicationID.range(of: pattern, options: .regularExpression) != nil else {
            throw ToolError.invalid("application_id must be a lowercase reverse-domain Android ID")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ToolError.invalid("name must be a nonempty printable application label")
        }
    }

    static func load(_ project: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: project.appendingPathComponent("Package.swift").path) else {
            throw ToolError.invalid("\(project.path) must contain Package.swift exporting AppContent")
        }
        let identity = try JSONDecoder().decode(Self.self, from: Data(contentsOf: project.appendingPathComponent("guava-android.json")))
        try identity.validate()
        return identity
    }
}
