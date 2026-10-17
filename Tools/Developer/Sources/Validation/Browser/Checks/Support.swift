internal import Foundation
private import ToolSupport

/// Raises the same acceptance failure the reference script's `assert` raises.
func ensure(_ condition: Bool, _ message: @autoclosure () -> String) throws {
  guard condition else { throw ToolError.message(message()) }
}

extension JSON {
  var text: String { string ?? serialized }
}

/// Formats a device scale the way the acceptance message prints it.
func scaleText(_ scale: Double) -> String {
  scale == scale.rounded() ? String(Int(scale)) : String(scale)
}
