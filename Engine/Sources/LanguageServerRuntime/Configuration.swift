public import Foundation
public import ProcessRuntime

public struct LanguageServerConfiguration: Sendable {
    public var command: ProcessCommand
    public var workspace: URL
    public var initializationOptions: Data?

    public init(command: ProcessCommand, workspace: URL) {
        self.command = command; self.workspace = workspace
    }
}
