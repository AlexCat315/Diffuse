/// Bounds for a caller-owned sidebar width. Layout fitting never writes a
/// narrower temporary allocation back into the caller's requested width.
public struct SidebarResizeOptions: Sendable, Hashable {
  public var minimumWidth: Float = 180
  public var maximumWidth: Float = 480
  public var minimumContentWidth: Float = 320
  public var label = "Resize navigation"
  public init() {}

  mutating func validate() {
    minimumWidth = minimumWidth.isFinite ? max(44, minimumWidth) : 180
    maximumWidth = maximumWidth.isFinite ? max(minimumWidth, maximumWidth) : max(minimumWidth, 480)
    minimumContentWidth = minimumContentWidth.isFinite ? max(44, minimumContentWidth) : 320
  }

  func range(in width: Float, handle: Float) -> ClosedRange<Float> {
    let available = max(0, width - handle - minimumContentWidth)
    return min(minimumWidth, available)...min(maximumWidth, available)
  }
}
