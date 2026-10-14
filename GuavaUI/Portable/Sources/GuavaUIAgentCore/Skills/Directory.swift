import Foundation

public extension AgentSkillLibrary {
    /// Reads immediate child directories containing SKILL.md. Only scalar name
    /// and description frontmatter is accepted; referenced resources are not read.
    static func load(directory: URL) throws -> Self {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let children = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var skills: [AgentSkill] = []
        for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
            let file = child.appendingPathComponent("SKILL.md").resolvingSymlinksInPath().standardizedFileURL
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard skills.count < 64 else { throw AgentError.invalidConfiguration("Skill library exceeds 64 entries.") }
            guard file.path.hasPrefix(root.path + "/") else {
                throw AgentError.invalidConfiguration("Skill file escapes the configured directory.")
            }
            let metadata = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard metadata.isRegularFile == true, (metadata.fileSize ?? Int.max) <= 70_000 else {
                throw AgentError.invalidConfiguration("Skill must be a regular Markdown file of at most 70 KB.")
            }
            let text = try String(contentsOf: file, encoding: .utf8)
            let lines = text.components(separatedBy: .newlines)
            guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
                throw AgentError.invalidConfiguration("SKILL.md requires name and description frontmatter.")
            }
            var fields: [String: String] = [:]
            for line in lines[1..<end] {
                if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                guard let colon = line.firstIndex(of: ":") else {
                    throw AgentError.invalidConfiguration("Skill frontmatter supports scalar name and description fields.")
                }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if value.first == "\"", value.last == "\"" { value = String(value.dropFirst().dropLast()) }
                else if value.first == "'", value.last == "'" { value = String(value.dropFirst().dropLast()) }
                guard ["name", "description"].contains(key), fields[key] == nil, !["|", ">"].contains(value) else {
                    throw AgentError.invalidConfiguration("Unsupported or duplicate skill frontmatter field.")
                }
                fields[key] = value
            }
            skills.append(try AgentSkill(name: fields["name"] ?? "", description: fields["description"] ?? "",
                instructions: lines.dropFirst(end + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return try Self(skills: skills)
    }
}
