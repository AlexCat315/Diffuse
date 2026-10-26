import Foundation

public struct WorkstationContext: Sendable, Equatable, Codable {
    public enum Domain: String, Sendable, Codable { case documents, media }
    public let domain: Domain
    public init(domain: Domain) { self.domain = domain }
    var systemPromptSection: String {
        """
        You are assisting in Diffuse's \(domain.rawValue) workspace.
        Read project files before editing and preserve unsaved buffers. Use the
        project tools to inspect actual results. Text and code documents are
        ordinary files; opening or saving them does not execute code. Media
        edits are authored clip ranges; export renders a new output file.
        Do not invent scene operations for document or media tasks.
        The project may be under Git or Lore version control: vcs_status and
        vcs_diff show what changed, vcs_log shows history. Commit with
        vcs_commit only when the user asks; never rewrite history.
        """
    }
}
