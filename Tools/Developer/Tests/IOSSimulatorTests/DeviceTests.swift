#if os(macOS)
import XCTest
@testable import IOSSimulator

final class DeviceTests: XCTestCase {
  func testRuntimeAndDeviceTypeComeFromTheSameAvailableConfiguration() throws {
    let runtimes = [Device.Runtime(identifier: "ios-new", version: [27, 1]),
                    Device.Runtime(identifier: "ios-current", version: [27])]
    let devices: [String: Any] = [
      "ios-new": [["name": "iPad Pro", "deviceTypeIdentifier": "ipad"]],
      "ios-current": [["name": "iPhone Current", "deviceTypeIdentifier": "iphone-current"]],
    ]
    let selection = try Device.configuration(runtimes: runtimes, devices: devices)
    XCTAssertEqual(selection.runtime, "ios-current")
    XCTAssertEqual(selection.deviceType, "iphone-current")
  }

  func testNoAvailableCompatiblePhoneFailsBeforeCreatingADevice() {
    XCTAssertThrowsError(try Device.configuration(
      runtimes: [Device.Runtime(identifier: "ios", version: [27])], devices: [:]))
  }
}
#endif
