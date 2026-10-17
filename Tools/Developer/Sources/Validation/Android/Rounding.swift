internal import Foundation

/// Python's `round()` uses banker's rounding (nearest, ties to even). The
/// screenshot crops and tap coordinates were produced with it, so the port
/// reproduces it rather than Swift's ties-away-from-zero default.
func pythonRound(_ value: Double) -> Int {
  Int(value.rounded(.toNearestOrEven))
}
