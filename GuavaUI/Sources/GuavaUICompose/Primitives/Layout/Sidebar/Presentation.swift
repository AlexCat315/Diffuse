/// Present the same destination nodes as a full sidebar or a narrow rail.
public enum SidebarPresentation: Sendable, Hashable {
    case expanded
    case rail(showsLabels: Bool)

    var railWidth: Float? {
        switch self {
        case .expanded: nil
        case .rail(let showsLabels): showsLabels ? 72 : 56
        }
    }
    var isRail: Bool { railWidth != nil }
    var showsLabels: Bool {
        switch self {
        case .expanded: true
        case .rail(let showsLabels): showsLabels
        }
    }
}
