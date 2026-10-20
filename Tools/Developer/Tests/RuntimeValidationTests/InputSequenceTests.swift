private import Foundation
internal import XCTest
@testable private import RuntimeValidation

final class InputSequenceTests: XCTestCase {
  func testPointerButtonsNormalizeBeforeDeliveryAndRejectInvalidValues() throws {
    let events = try InputUI.loadEvents("""
      [{"kind":"pointerDown","x":10,"y":20,"button":"right"},
       {"kind":"pointerUp","x":10,"y":20,"button":2}]
      """)
    XCTAssertEqual(events.compactMap { $0["button"] as? Int }, [2, 2])
    for value in ["\"unknown\"", "5", "-1", "1.5", "true"] {
      XCTAssertThrowsError(try InputUI.loadEvents("[{\"kind\":\"pointerDown\",\"button\":\(value)}]"))
    }
  }
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

  func testPointerModifiersUseNamesAndRejectUnknownNames() throws {
    let events = try InputUI.loadEvents("""
      [{"kind":"pointerDown","x":10,"y":20,"button":"left","modifiers":["shift","cmd"]},
       {"kind":"pointerUp","x":10,"y":20,"button":0,"modifiers":["ctrl"]}]
      """)
    XCTAssertEqual(events.compactMap { $0["modifiers"] as? Int }, [9, 2])
    XCTAssertThrowsError(try InputUI.loadEvents("[{\"kind\":\"pointerDown\",\"button\":0,\"modifiers\":[\"hyper\"]}]"))
    XCTAssertThrowsError(try InputUI.loadEvents("[{\"kind\":\"keyDown\",\"key\":\"KeyA\",\"modifiers\":[\"super\"]}]"))
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

  func testShortcutsNormalizeLettersDigitsAndRejectUndeliverableKeys() throws {
    let events = try InputUI.loadEvents("""
      [{"kind":"keyDown","scancode":4,"modifiers":["cmd"]},
       {"kind":"keyUp","scancode":29},
       {"kind":"keyDown","scancode":30},
       {"kind":"keyDown","key":"KeyZ","modifiers":["cmd","shift"]}]
      """)
    XCTAssertEqual(events.compactMap { $0["key"] as? String }, ["KeyA", "KeyZ", "Digit1", "KeyZ"])
    XCTAssertEqual(events[0]["modifiers"] as? Int, 8)
    XCTAssertEqual(events[3]["modifiers"] as? Int, 9)
    for raw in ["[{\"kind\":\"keyDown\",\"key\":\"a\"}]",
                "[{\"kind\":\"keyDown\",\"scancode\":500}]",
                "[{\"kind\":\"keyDown\"}]"] {
      XCTAssertThrowsError(try InputUI.loadEvents(raw))
    }
  }

  func testCaptureSettlingIsOptionalAndBounded() throws {
    XCTAssertEqual(try CaptureUI.options(["9231", "out.jpg"]), .init())
    XCTAssertEqual(try CaptureUI.options(["9231", "out.jpg", "--settle-ms", "400"]).settleMilliseconds, 400)
    XCTAssertEqual(try CaptureUI.options(["9231", "out.jpg", "--scale", "2", "--settle-ms", "100"]), .init(settleMilliseconds: 100, scale: 2))
    for args in [[], ["9231"], ["9231", "out.jpg", "--settle-ms", "-1"],
                 ["9231", "out.jpg", "--settle-ms", "2001"],
                 ["9231", "out.jpg", "--settle-ms", "NaN"], ["9231", "out.jpg", "--scale", "4"],
                 ["9231", "out.jpg", "--scale"], ["9231", "out.jpg", "--zoom", "2"]] {
      XCTAssertThrowsError(try CaptureUI.options(args))
    }
  }

  func testCaptureCropsToANodeOrALogicalRegion() throws {
    XCTAssertEqual(try CaptureUI.options(["9231", "out.jpg", "--node", "128", "--scale", "2"]),
                   .init(scale: 2, crop: .node("128")))
    XCTAssertEqual(try CaptureUI.options(["9231", "out.jpg", "--region", "100,40.5,320,80"]).crop,
                   .region(x: 100, y: 40.5, width: 320, height: 80))
    for args in [["9231", "out.jpg", "--node", ""], ["9231", "out.jpg", "--node", "abc"],
                 ["9231", "out.jpg", "--region", "1,2,3"], ["9231", "out.jpg", "--region", "0,0,0,10"],
                 ["9231", "out.jpg", "--node", "1", "--region", "0,0,10,10"]] {
      XCTAssertThrowsError(try CaptureUI.options(args))
    }
  }
}
