private import GuavaUIRuntime

public struct SidebarLayoutPolicy: Sendable, Hashable {
  public var compactMaximumWidth = UIEnvironment.Viewport.compactMaximumWidth
  public var expandedMinimumWidth = UIEnvironment.Viewport.expandedMinimumWidth
  public var sidebarWidth: Float = 240
  public var showsRailLabels = true
  public init() {}

  mutating func validate() {
    compactMaximumWidth = compactMaximumWidth.isFinite ? max(0, compactMaximumWidth) : 600
    expandedMinimumWidth =
      expandedMinimumWidth.isFinite
      ? max(compactMaximumWidth, expandedMinimumWidth) : max(compactMaximumWidth, 1000)
    sidebarWidth = sidebarWidth.isFinite ? max(44, sidebarWidth) : 240
  }
}

public struct AdaptiveSidebarOptions {
  public var layout = SidebarLayoutPolicy()
  public var drawer = NavigationDrawerOptions()
  public var openLabel = "Open navigation"
  /// A rightward gesture beginning within the leading 24pt opens compact navigation.
  /// Enabled only on surfaces that support touch; ordinary taps still reach content.
  public var allowsEdgeSwipe = false
  public init() {}
}

enum SidebarMode { case compact, rail, expanded }

struct SidebarGeometry {
  let mode: SidebarMode
  let viewportWidth: Float
  let dockedWidth: Float
  let panelWidth: Float
  let isModal: Bool
  var isVisible: Bool { mode != .compact || isModal }

  init(width: Float, policy: SidebarLayoutPolicy, isPresented: Bool) {
    viewportWidth = max(0, width)
    mode =
      width < policy.compactMaximumWidth
      ? .compact : width < policy.expandedMinimumWidth ? .rail : .expanded
    dockedWidth =
      mode == .expanded
      ? min(policy.sidebarWidth, viewportWidth)
      : mode == .rail ? (policy.showsRailLabels ? 72 : 56) : 0
    isModal = mode != .expanded && isPresented
    panelWidth = isModal || mode == .compact ? min(320, max(0, viewportWidth - 56)) : dockedWidth
  }
}
