package import Foundation

package extension NSNumber {
  /// Whether this number wraps a boolean rather than a numeric value.
  ///
  /// `JSONSerialization` boxes JSON `true`/`false` as boolean `NSNumber`s on
  /// every platform, and a boxed `0` or `1` compares numerically equal to
  /// `false` or `true`, so `boolValue` alone cannot tell them apart. Darwin
  /// exposes the CoreFoundation type IDs through Foundation; other platforms
  /// compare against the shared boolean singletons that `NSNumber(value:)`
  /// returns from Foundation's cache.
  var isBoolean: Bool {
    #if canImport(Darwin)
    return CFGetTypeID(self) == CFBooleanGetTypeID()
    #else
    return self === NSNumber(value: true) || self === NSNumber(value: false)
    #endif
  }
}
