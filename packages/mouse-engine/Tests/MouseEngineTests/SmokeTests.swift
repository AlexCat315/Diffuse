import XCTest
@testable import MouseEngineCore
@testable import MouseEngineRPC

final class SmokeTests: XCTestCase {
    func testApplicationLifecycle() {
        let app = Application()
        XCTAssertFalse(app.isRunning)
        app.start()
        XCTAssertTrue(app.isRunning)
        app.stop()
        XCTAssertFalse(app.isRunning)
    }

    func testRPCStartStop() {
        let app = Application()
        let rpc = RPCBridge(app: app)
        XCTAssertTrue(rpc.handle(.init(method: "engine.start")).ok)
        XCTAssertTrue(rpc.handle(.init(method: "engine.stop")).ok)
    }
}
