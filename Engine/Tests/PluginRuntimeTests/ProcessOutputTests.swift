import Foundation
internal import GuavaProcess
import Testing
@testable import PluginRuntime

#if os(macOS) || os(Linux)
@Suite("Plugin process output streaming")
struct ProcessOutputTests {
    @Test("burst output is retained but each poll stays below the RPC frame budget")
    func chunksLargeOutputBeforeReportingExit() async throws {
        var command = ProcessCommand(executable: URL(fileURLWithPath: "/usr/bin/head"), directory: FileManager.default.temporaryDirectory)
        command.arguments = ["-c", "10485760", "/dev/zero"]
        var budget = ProcessBudget()
        budget.outputBytes = 20_971_520
        let session = try ProcessSession(command: command, budget: budget)
        let entry = ProcessEntry(session: session, generation: UUID(), permissionID: "fixture", maximumBytes: budget.outputBytes)
        try await Task.sleep(for: .milliseconds(200))
        var output = Data()
        var polls = 0
        var exitStatus: Int32?
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while exitStatus == nil && ContinuousClock.now < deadline {
            let update = entry.poll()
            #expect(update.failure == nil)
            #expect(update.stdout.count <= ProcessEntry.chunkBytes)
            output.append(update.stdout)
            polls += 1
            exitStatus = update.exitStatus
            if exitStatus == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        #expect(output.count == 10_485_760)
        #expect(exitStatus == 0)
        #expect(polls >= 3)
        #expect(output.allSatisfy { $0 == 0 })
    }
}
#endif
