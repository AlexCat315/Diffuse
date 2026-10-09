import Foundation
import GuavaUIRuntime

public enum AvatarShape: Sendable, Equatable {
    case circle, square, roundedRectangle(radius: Float)
    func radius(for diameter: Float) -> Float {
        switch self {
        case .circle: diameter / 2
        case .square: 0
        case .roundedRectangle(let radius): radius.isFinite ? max(0, min(diameter / 2, radius)) : 8
        }
    }
}
public struct AvatarColors: Sendable, Equatable {
    public var background: Color
    public var foreground: Color
    public var border: Color
    public init(background: Color, foreground: Color, border: Color) {
        self.background = background; self.foreground = foreground; self.border = border
    }
}
public struct AvatarAppearance {
    public var size: ControlSize?
    public var diameter: Float?
    public var shape: AvatarShape = .circle
    public var borderWidth: Float = 1
    public var colors: AvatarColors?
    public var placeholder = UICommonIcons.user
    public var retryID = 0
    public init() {}
    mutating func validate() {
        if let diameter { self.diameter = diameter.isFinite ? max(12, min(512, diameter)) : nil }
        borderWidth = borderWidth.isFinite ? max(0, min(8, borderWidth)) : 1
    }
    func resolvedDiameter(in node: Node) -> Float {
        if let diameter, diameter.isFinite { return max(12, min(512, diameter)) }
        return switch size ?? node.compositionValue(of: ControlSizeEnvironment.key) {
        case .mini: 16
        case .small: 24
        case .regular: 48
        case .large: 80
        }
    }
}

/// Person image, Unicode initials or anonymous icon. Images share the bounded
/// asynchronous loader and keep the fallback visible during loading/failure.
public struct Avatar: _PrimitiveView {
    public let name: String
    public let id: String?
    public let imageURL: URL?
    public var appearance = AvatarAppearance()
    public init(_ name: String = "", id: String? = nil, imageURL: URL? = nil,
                configure: (inout AvatarAppearance) -> Void = { _ in }) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id; self.imageURL = imageURL
        configure(&appearance); appearance.validate()
    }
    public var initials: String { AvatarIdentity.initials(name) }
    public func _makeNode() -> Node { let node = Node(); node.isHitTestable = false; return node }
    public func _makeLayoutNode() -> LayoutNode? { LayoutNode() }
    public func _updateNode(_ node: Node) {
        let diameter = appearance.resolvedDiameter(in: node)
        let colors = resolvedColors(in: node)
        node.backgroundColor = appearance.colors?.border ?? (imageURL == nil ? colors.border : node.theme.colors.border)
        node.cornerRadius = appearance.shape.radius(for: diameter)
        node.accessibility = AccessibilitySemantics(.image) {
            $0.label = name.isEmpty ? "Anonymous user" : name; $0.combinesChildren = true
        }
        node.attachments["avatar.initials"] = initials
        node.layoutNode?.width = diameter; node.layoutNode?.height = diameter
        node.layoutNode?.alignItems = .center; node.layoutNode?.justifyContent = .center
    }
    public func _children(for node: Node) -> [any View] {
        var appearance = appearance; appearance.validate()
        let diameter = appearance.resolvedDiameter(in: node)
        let border = min(appearance.borderWidth, diameter / 4)
        let inner = diameter - border * 2
        let radius = max(0, appearance.shape.radius(for: diameter) - border)
        let fallback = AnyView(AvatarFallback(initials: initials, diameter: inner, radius: radius,
                                               colors: resolvedColors(in: node), icon: appearance.placeholder))
        guard let imageURL else { return [fallback.accessibilityHidden()] }
        return [AsyncImage(url: imageURL, width: inner, height: inner, contentMode: .fill, retryID: appearance.retryID) { phase in
            switch phase {
            case .success(let image): AnyView(image.cornerRadius(radius))
            case .empty, .loading, .failure: fallback
            }
        }.accessibilityHidden()]
    }
    private func resolvedColors(in node: Node) -> AvatarColors {
        if let colors = appearance.colors { return colors }
        guard !initials.isEmpty else {
            return AvatarColors(background: node.theme.colors.surfaceVariant, foreground: node.theme.colors.onSurfaceMuted,
                                border: node.theme.colors.border)
        }
        return AvatarIdentity.colors(initials: initials, isDark: AvatarIdentity.isDark(node.theme.colors.background))
    }
}

struct AvatarFallback: View {
    let initials: String
    let diameter: Float
    let radius: Float
    let colors: AvatarColors
    let icon: BundleImageResource
    var body: some View {
        Box(direction: .row, alignItems: .center, justifyContent: .center) {
            if initials.isEmpty { Icon(icon, size: diameter * 0.6, color: colors.foreground) }
            else {
                Text(initials, lineLimit: 1).font(.system(size: diameter * 0.36, weight: .semibold))
                    .foregroundColor(colors.foreground)
            }
        }.frame(width: diameter, height: diameter).background(colors.background).cornerRadius(radius).clipped()
    }
}

enum AvatarIdentity {
    static func isDark(_ color: Color) -> Bool { 0.2126 * color.r + 0.7152 * color.g + 0.0722 * color.b < 0.5 }
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace)
        let raw = words.count > 1 ? words.prefix(2).compactMap(\.first).map(String.init).joined()
                                  : String((words.first ?? "").prefix(2))
        return String(raw.uppercased().prefix(2))
    }
    static func hueIndex(_ initials: String) -> Int {
        let hash = initials.precomposedStringWithCanonicalMapping.utf8.reduce(UInt64(14_695_981_039_346_656_037)) {
            ($0 ^ UInt64($1)) &* 1_099_511_628_211
        }
        return Int(hash % 12)
    }
    static func colors(initials: String, isDark: Bool) -> AvatarColors { colors(hue: Float(hueIndex(initials)) * 30, isDark: isDark) }
    static func colors(hue: Float, isDark: Bool) -> AvatarColors {
        if isDark {
            AvatarColors(background: oklch(0.30, 0.05, hue), foreground: oklch(0.82, 0.11, hue), border: oklch(0.36, 0.06, hue))
        } else {
            AvatarColors(background: oklch(0.97, 0.032, hue), foreground: oklch(0.50, 0.145, hue), border: oklch(0.89, 0.05, hue))
        }
    }
    private static func oklch(_ lightness: Float, _ chroma: Float, _ hue: Float) -> Color {
        let radians = hue * .pi / 180, a = chroma * cos(radians), b = chroma * sin(radians)
        let ll = lightness + 0.3963377774 * a + 0.2158037573 * b
        let mm = lightness - 0.1055613458 * a - 0.0638541728 * b
        let ss = lightness - 0.0894841775 * a - 1.2914855480 * b
        let l = ll * ll * ll, m = mm * mm * mm, s = ss * ss * ss
        func channel(_ value: Float) -> Float {
            let value = max(0, min(1, value))
            return value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
        }
        return Color(r: channel(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                     g: channel(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                     b: channel(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }
}
