public import Foundation
public import ProcessRuntime

public struct LanguageServerConfiguration: Sendable {
    public var command: ProcessCommand
    public var workspace: URL
    /// Further roots the server serves beside `workspace`, such as the folder of
    /// a Swift package the user is editing.
    public var additionalWorkspaces: [URL] = []
    public var initializationOptions: Data?
    public var connect: (@Sendable (ProcessCommand) throws -> LanguageServerTransport)? = nil

    public init(command: ProcessCommand, workspace: URL) {
        self.command = command; self.workspace = workspace
    }
}
