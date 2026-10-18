private import Foundation
internal import XCTest
@testable private import RuntimeValidation

final class InputSequenceTests: XCTestCase {
  func testWaitPreservesGestureOrderAndKeyNormalization() throws {
    let events = try InputUI.loadEvents("""
      [{"kind":"pointerDown","x":10,"y":20},
       {"kind":"wait","milliseconds":100},
       {"kind":"pointerMove","x":10,"y":100},
       {"kind":"pointerUp","x":10,"y":100},
       {"kind":"keyDown","scancode":82,"modifiers":["shift"]}]
      """)
    XCTAssertEqual(events.compactMap { $0["kind"] as? String },
                   ["pointerDown", "wait", "pointerMove", "pointerUp", "keyDown"])
    XCTAssertEqual(events[4]["key"] as? String, "ArrowUp")
    XCTAssertEqual(events[4]["modifiers"] as? Int, 1)
  }

  func testWaitIsBoundedAndRequiresAnExactShape() {
    for raw in [
      "[{\"kind\":\"wait\",\"milliseconds\":0}]",
      "[{\"kind\":\"wait\",\"milliseconds\":2001}]",
      "[{\"kind\":\"wait\",\"milliseconds\":100,\"x\":1}]",
      "[" + Array(repeating: "{\"kind\":\"wait\",\"milliseconds\":2000}", count: 6).joined(separator: ",") + "]"
    ] {
      XCTAssertThrowsError(try InputUI.loadEvents(raw))
    }
  }
}
