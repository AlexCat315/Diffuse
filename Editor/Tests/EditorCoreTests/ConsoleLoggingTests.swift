import Foundation
import XCTest
import CoveLogging
@testable import EditorCore

final class ConsoleLoggingTests: XCTestCase {
    func testConsoleRecordsRemainSessionData() throws {
        var state = EditorOutputState()
        state.consoleEntries = [.init(id: 91, severity: .error, message: "temporary")]
        state.nextConsoleEntryID = 92
        let encoded = try JSONEncoder().encode(state)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "{}")
        let restored = try JSONDecoder().decode(EditorOutputState.self, from: encoded)
        XCTAssertTrue(restored.consoleEntries.isEmpty)
        XCTAssertEqual(restored.nextConsoleEntryID, 1)
        XCTAssertEqual(restored.outputTab, .logs)
    }

    func testDomainConsoleJournalDoesNotFeedBackAndEngineRecordsAreQueued() throws {
        let capture = EditorLogCapture(); defer { capture.stop() }
        _ = capture.take()
        let marker = UUID().uuidString
        let store = EditorStore()
        store.dispatch(.appendConsoleMessage(marker, severity: .warning, detail: "details", target: nil, nextStep: "retry"))
        LogSystem.logger("com.cove.engine.test").warning("engine-\(marker)")
        LogSystem.flush()
        let pending = capture.take()
        XCTAssertFalse(pending.contains { $0.message == marker })
        XCTAssertTrue(pending.contains { $0.message == "engine-\(marker)" })
        XCTAssertEqual(store.state.output.consoleEntries.filter { $0.message == marker }.count, 1)
        XCTAssertTrue(LogSystem.snapshot().records.contains { $0.message == marker && $0.metadata["next_step"] == .string("retry") })
    }
}
