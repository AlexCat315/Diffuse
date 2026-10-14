import Foundation

/// Instructions are content. Loading a skill never executes code or grants tools.
public struct AgentSkill: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let instructions: String

    public init(name: String, description: String, instructions: String) throws {
        guard name.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil,
              !description.isEmpty, description.utf8.count <= 1024,
              !instructions.isEmpty, instructions.utf8.count <= 65_536 else {
            throw AgentError.invalidConfiguration("Invalid skill name, description or instructions.")
        }
        self.name = name; self.description = description; self.instructions = instructions
    }
}

public struct AgentSkillLibrary: Sendable {
    public let skills: [AgentSkill]
    public init() { skills = [] }
    public init(skills: [AgentSkill]) throws {
        guard skills.count <= 64, Set(skills.map(\.name)).count == skills.count else {
            throw AgentError.invalidConfiguration("Skills must have unique names; at most 64 are supported.")
        }
        // Validate decoded values as well as values created through the initializer.
        self.skills = try skills.map { try AgentSkill(name: $0.name, description: $0.description, instructions: $0.instructions) }
    }
    public func read(name: String) throws -> AgentSkill {
        guard let skill = skills.first(where: { $0.name == name }) else {
            throw AgentError.invalidConfiguration("Unknown skill: \(name)")
        }
        return skill
    }
    public func instructions(for names: [String]) throws -> String {
        guard Set(names).count == names.count else { throw AgentError.invalidConfiguration("Duplicate enabled skill.") }
        return try names.map { name in
            let skill = try read(name: name)
            return "Skill: \(skill.name)\n\(skill.instructions)"
        }.joined(separator: "\n\n")
    }
}
