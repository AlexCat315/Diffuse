import Foundation
import GuavaUIRuntime

/// Optional presentation for one menu row. `MenuItem.title` stays the
/// accessible name and the type-ahead key, so rich titles never change how a
/// row is found or announced.
public struct MenuItemContent {
    /// Leading glyph. Any icon in a menu level reserves one shared lane.
    public var icon: BundleImageResource?
    /// Styled visual title. Run links are ignored: the row is the only target.
    public var richTitle: [RichTextRun]
    /// Secondary line under the title.
    public var detail: String?
    /// Marks the row as a link to `link`. Activation still runs the item's
    /// action (which opens the destination); assistive technology hears a link
    /// and a trailing glyph distinguishes it from commands.
    public var link: String?

    public init(icon: BundleImageResource? = nil, richTitle: [RichTextRun] = [],
                detail: String? = nil, link: String? = nil) {
        self.icon = icon
        self.richTitle = richTitle.map { RichTextRun($0.text, traits: $0.traits) }
        self.detail = detail?.isEmpty == true ? nil : detail
        self.link = link?.isEmpty == true ? nil : link
    }
}

/// Pointer travel toward an open submenu. A row crossed on the way keeps the
/// submenu open longer (a safe triangle from the previous pointer position to
/// the submenu's near edge), so diagonal moves do not switch branches.
struct MenuPointerIntent {
    private(set) var previous: CGPoint?
    private(set) var current: CGPoint?
    var submenuFrame: CGRect?

    mutating func record(_ point: CGPoint) {
        guard point != current else { return }
        previous = current; current = point
    }

    var isHeadingToSubmenu: Bool {
        guard let apex = previous, let point = current, let frame = submenuFrame,
              frame.width > 0, frame.height > 0 else { return false }
        let edge = point.x <= frame.minX ? frame.minX : point.x >= frame.maxX ? frame.maxX : nil
        guard let edge else { return frame.contains(point) }
        let slack: CGFloat = 4
        return Self.triangle(apex, CGPoint(x: edge, y: frame.minY - slack), CGPoint(x: edge, y: frame.maxY + slack), contains: point)
    }

    static func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, contains p: CGPoint) -> Bool {
        func sign(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> CGFloat {
            (p1.x - p3.x) * (p2.y - p3.y) - (p2.x - p3.x) * (p1.y - p3.y)
        }
        let d1 = sign(p, a, b), d2 = sign(p, b, c), d3 = sign(p, c, a)
        let negative = d1 < 0 || d2 < 0 || d3 < 0, positive = d1 > 0 || d2 > 0 || d3 > 0
        return !(negative && positive)
    }
}
