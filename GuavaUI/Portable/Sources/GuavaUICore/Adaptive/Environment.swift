import Foundation

/// Transient surface capabilities. Layout follows available space and input,
/// so a tablet with a keyboard can use the same controls as a desktop window.
public struct UIEnvironment: Sendable, Hashable {
    public struct Viewport: Sendable, Hashable {
        public static let compactMaximumWidth: Float = 600
        public static let expandedMinimumWidth: Float = 1000
        public var width: Float = 1280
        public var height: Float = 720
        public var scale: Float = 1
        public init() {}
        public var widthClass: WidthClass {
            width < Self.compactMaximumWidth ? .compact
                : width < Self.expandedMinimumWidth ? .medium
                : .expanded
        }
    }
    public struct Insets: Sendable, Hashable {
        public var top: Float = 0
        public var bottom: Float = 0
        public var leading: Float = 0
        public var trailing: Float = 0
        public init() {}
    }
    public struct Input: OptionSet, Sendable, Hashable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let touch = Input(rawValue: 1)
        public static let pointer = Input(rawValue: 2)
        public static let keyboard = Input(rawValue: 4)
        public static let pen = Input(rawValue: 8)
    }
    public enum WidthClass: Sendable { case compact, medium, expanded }
    public var viewport = Viewport()
    public var safeArea = Insets()
    public var input: Input = [.pointer, .keyboard]
    public var reducesMotion = false
    public init() {}
    public var minimumControlExtent: Float { input.contains(.touch) ? 44 : 28 }
}
