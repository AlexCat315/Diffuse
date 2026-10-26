import Foundation
import CoveUICompose
import CoveUIRuntime
import PluginRuntime

enum ThemeTokenMaps {
    static let colors: [String: WritableKeyPath<ColorScheme, Color> & Sendable] = [
        "background": \.background,
        "surface": \.surface,
        "surfaceVariant": \.surfaceVariant,
        "surfaceSunken": \.surfaceSunken,
        "surfaceRaised": \.surfaceRaised,
        "surfaceFloating": \.surfaceFloating,
        "surfaceOverlay": \.surfaceOverlay,
        "onBackground": \.onBackground,
        "onSurface": \.onSurface,
        "onSurfaceVariant": \.onSurfaceVariant,
        "onSurfaceMuted": \.onSurfaceMuted,
        "accent": \.accent,
        "accentHover": \.accentHover,
        "accentPressed": \.accentPressed,
        "onAccent": \.onAccent,
        "accentMuted": \.accentMuted,
        "accentSecondary": \.accentSecondary,
        "stateLayerHover": \.stateLayerHover,
        "stateLayerPressed": \.stateLayerPressed,
        "stateLayerSelected": \.stateLayerSelected,
        "success": \.success,
        "warning": \.warning,
        "error": \.error,
        "info": \.info,
        "border": \.border,
        "borderStrong": \.borderStrong,
        "divider": \.divider,
        "focusRing": \.focusRing,
        "selection": \.selection,
        "overlay": \.overlay,
    ]

    static let typography: [String: WritableKeyPath<Typography, TextStyleToken> & Sendable] = [
        "display": \.display,
        "title": \.title,
        "headline": \.headline,
        "body": \.body,
        "bodyStrong": \.bodyStrong,
        "caption": \.caption,
        "label": \.label,
        "mono": \.mono,
    ]

    static let spacing: [String: WritableKeyPath<SpacingScale, Float> & Sendable] = [
        "xs": \.xs,
        "sm": \.sm,
        "md": \.md,
        "lg": \.lg,
        "xl": \.xl,
        "xxl": \.xxl,
    ]

    static let radius: [String: WritableKeyPath<RadiusScale, Float> & Sendable] = [
        "none": \.none,
        "sm": \.sm,
        "md": \.md,
        "lg": \.lg,
        "xl": \.xl,
        "pill": \.pill,
    ]

    static let inputColors: [String: WritableKeyPath<InputAppearance, Color> & Sendable] = [
        "background": \.background,
        "backgroundDisabled": \.backgroundDisabled,
        "borderColor": \.borderColor,
        "borderHover": \.borderHover,
        "borderFocused": \.borderFocused,
        "borderError": \.borderError,
        "borderDisabled": \.borderDisabled,
        "addonBackground": \.addonBackground,
        "addonForeground": \.addonForeground,
        "dividerColor": \.dividerColor,
    ]

    static let inputMetrics: [String: WritableKeyPath<InputAppearance, Float> & Sendable] = [
        "borderWidth": \.borderWidth,
        "focusRingWidth": \.focusRingWidth,
        "radius": \.radius,
    ]

    static func apply<Group, Value>(_ values: [String: Value]?, to group: inout Group,
                                    using keys: [String: WritableKeyPath<Group, Value> & Sendable]) throws {
        for (name, value) in values ?? [:] {
            guard let key = keys[name] else { throw ThemeResourceError.invalidToken(name) }
            group[keyPath: key] = value
        }
    }

    static func metrics<Group>(_ values: [String: Float]?, to group: inout Group,
                               using keys: [String: WritableKeyPath<Group, Float> & Sendable]) throws {
        guard (values ?? [:]).values.allSatisfy({ $0.isFinite && (0...1024).contains($0) }) else {
            throw ThemeResourceError.invalidTheme
        }
        try apply(values, to: &group, using: keys)
    }
}
