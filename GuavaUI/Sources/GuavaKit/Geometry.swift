// Pure-Swift geometry primitives. No CoreGraphics — GuavaKit must build and
// behave identically on Windows/Linux where CoreGraphics is absent.

public struct Point: Equatable, Sendable {
    public var x: Float
    public var y: Float
    public init(x: Float = 0, y: Float = 0) { self.x = x; self.y = y }
    public static let zero = Point()
}

public struct Size: Equatable, Sendable {
    public var width: Float
    public var height: Float
    public init(width: Float = 0, height: Float = 0) { self.width = width; self.height = height }
    public static let zero = Size()
}

public struct Rect: Equatable, Sendable {
    public var origin: Point
    public var size: Size
    public init(origin: Point = .zero, size: Size = .zero) { self.origin = origin; self.size = size }
    public init(x: Float, y: Float, width: Float, height: Float) {
        self.init(origin: Point(x: x, y: y), size: Size(width: width, height: height))
    }
    public static let zero = Rect()

    public var minX: Float { origin.x }
    public var minY: Float { origin.y }
    public var maxX: Float { origin.x + size.width }
    public var maxY: Float { origin.y + size.height }

    /// Membership test in this rect's own coordinate space (origin-relative).
    public func contains(local p: Point) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x <= size.width && p.y <= size.height
    }
}

/// The complete visual/interaction geometry of a node. Bundled into one value
/// so a change is a single diffable mutation (see `UINode.setGeometry`), rather
/// than N independent properties each needing their own invalidation hook.
public struct Geometry: Equatable, Sendable {
    /// Parent-relative rectangle assigned by layout.
    public var frame: Rect
    /// Children are drawn/hit-tested translated by `-contentOffset` (scrolling).
    public var contentOffset: Point
    /// Higher z draws and hit-tests on top of lower-z siblings.
    public var zIndex: Float
    /// When true, this node and its subtree are clipped to `frame`.
    public var clipsToBounds: Bool
    /// When false, the node is skipped during hit-testing (its children still
    /// participate — matches CSS `pointer-events: none` for the node alone).
    public var isHitTestable: Bool

    public init(frame: Rect = .zero,
                contentOffset: Point = .zero,
                zIndex: Float = 0,
                clipsToBounds: Bool = false,
                isHitTestable: Bool = true) {
        self.frame = frame
        self.contentOffset = contentOffset
        self.zIndex = zIndex
        self.clipsToBounds = clipsToBounds
        self.isHitTestable = isHitTestable
    }

    /// Which caches a change from `old` to `new` dirties. This is the single
    /// place that maps a geometry change to invalidation flags — there is no
    /// second copy of this logic anywhere, so it cannot drift or be forgotten.
    static func diff(_ old: Geometry, _ new: Geometry) -> DirtyFlags {
        var flags: DirtyFlags = []
        if old.frame != new.frame {
            // A moved/resized node changes both where it paints and where it can
            // be hit. `.geometry` is what drives hit-cache invalidation.
            flags.formUnion([.geometry, .paint])
        }
        if old.contentOffset != new.contentOffset { flags.formUnion([.geometry, .paint]) }
        if old.zIndex != new.zIndex { flags.formUnion([.geometry, .paint]) }
        if old.clipsToBounds != new.clipsToBounds { flags.formUnion([.geometry, .paint]) }
        if old.isHitTestable != new.isHitTestable { flags.formUnion([.geometry]) }
        return flags
    }
}
