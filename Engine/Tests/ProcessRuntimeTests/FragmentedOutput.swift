import Foundation
import Testing
@testable import ProcessRuntime

@Suite("Process output byte budget")
struct ProcessBufferTests {
    @Test func fragmentedOutputUsesByteBudget() async throws {
        let buffer = ProcessEventBuffer(maximumBytes: 128)
        for value in UInt8(0)..<128 {
            #expect(buffer.append(.stdout(Data([value]))))
        }
        #expect(!buffer.append(.stdout(Data([128]))))
        #expect(buffer.append(.stdoutClosed))
        #expect(buffer.append(.exited(0)))
        buffer.finish()
        var output = Data()
        var exitStatus: Int32?
        while let event = try await buffer.next() {
            switch event {
            case let .stdout(data): output.append(data)
            case let .exited(status): exitStatus = status
            default: break
            }
        }
        #expect(output == Data(UInt8(0)..<128))
        #expect(exitStatus == 0)
    }

    @Test func cancellingAnIdleProcessReaderReleasesItsWaiter() async {
        let buffer = ProcessEventBuffer(maximumBytes: 128)
        let task = Task { try await buffer.next() }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled reader returned without cancellation")
        } catch is CancellationError {
        } catch { Issue.record(error) }
    }
}
