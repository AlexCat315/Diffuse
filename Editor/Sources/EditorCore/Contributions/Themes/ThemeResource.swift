import Foundation
import PluginRuntime
import GuavaUICompose
import GuavaUIRuntime

struct ThemeResource: Decodable, Sendable {
    let version: Int
    let light: ThemeVariant?
    let dark: ThemeVariant?

    func validate(appearance: String) throws {
        guard version == 1, light != nil || dark != nil,
              appearance != "dual" || (light != nil && dark != nil),
              appearance != "light" || light != nil,
              appearance != "dark" || dark != nil else { throw ThemeResourceError.invalidTheme }
        if let light { _ = try light.make(dark: false) }
        if let dark { _ = try dark.make(dark: true) }
    }
}

enum ThemeResourceError: Error { case invalidTheme, invalidToken(String) }

struct ThemeColor: Decodable, Sendable {
    let value: Color

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self),
           text.first == "#", [7, 9].contains(text.count),
           let rgba = UInt32(text.dropFirst(), radix: 16) {
            let hasAlpha = text.count == 9
            value = Color(red: UInt8((rgba >> (hasAlpha ? 24 : 16)) & 255),
                          green: UInt8((rgba >> (hasAlpha ? 16 : 8)) & 255),
                          blue: UInt8((rgba >> (hasAlpha ? 8 : 0)) & 255),
                          alpha: hasAlpha ? UInt8(rgba & 255) : 255)
        } else {
            let channels = try container.decode([Float].self)
            guard channels.count == 4, channels.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
                throw ThemeResourceError.invalidTheme
            }
            value = Color(r: channels[0], g: channels[1], b: channels[2], a: channels[3])
        }
    }
}

struct ThemeFont: Decodable, Sendable {
    let size: Float
    let lineHeight: Float
    let weight: String?
    let monospaced: Bool?
    let family: String?

    func token() throws -> TextStyleToken {
        guard size.isFinite, (1...128).contains(size), lineHeight.isFinite,
              (1...256).contains(lineHeight), family.map({ $0.count <= 128 }) ?? true else {
            throw ThemeResourceError.invalidTheme
        }
        let weight: FontWeight
        switch self.weight ?? "regular" {
        case "regular": weight = .regular
        case "medium": weight = .medium
        case "semibold": weight = .semibold
        case "bold": weight = .bold
        default: throw ThemeResourceError.invalidTheme
        }
        return TextStyleToken(font: Font(size: size, weight: weight,
                                        design: monospaced == true ? .monospaced : .standard, family: family),
                              lineHeight: lineHeight)
    }
}

struct ThemeMotion: Decodable, Sendable {
    let fast: Int
    let standard: Int
    let slow: Int
    let easing: String

    func apply(to theme: inout Theme) throws {
        guard [fast, standard, slow].allSatisfy({ (0...10_000).contains($0) }) else {
            throw ThemeResourceError.invalidTheme
        }
        theme.motion.fast = .milliseconds(fast)
        theme.motion.standard = .milliseconds(standard)
        theme.motion.slow = .milliseconds(slow)
        switch easing {
        case "standard": theme.motion.standardEasing = .standard
        case "emphasized": theme.motion.standardEasing = .emphasized
        case "decelerate": theme.motion.standardEasing = .decelerate
        case "accelerate": theme.motion.standardEasing = .accelerate
        default: throw ThemeResourceError.invalidTheme
        }
    }
}

struct ThemeShadow: Decodable, Sendable {
    let color: ThemeColor
    let offsetX: Float
    let offsetY: Float
    let blur: Float

    func token() throws -> SurfaceShadow {
        guard [offsetX, offsetY, blur].allSatisfy(\.isFinite),
              abs(offsetX) <= 128, abs(offsetY) <= 128, (0...256).contains(blur) else {
            throw ThemeResourceError.invalidTheme
        }
        return SurfaceShadow(color: color.value, offsetX: offsetX, offsetY: offsetY, blur: blur)
    }
}

struct ThemeInputTokens: Decodable, Sendable {
    let colors: [String: ThemeColor]?
    let metrics: [String: Float]?
}

struct ThemeVariant: Decodable, Sendable {
    let colors: [String: ThemeColor]?
    let typography: [String: ThemeFont]?
    let spacing: [String: Float]?
    let radius: [String: Float]?
    let motion: ThemeMotion?
    let inputs: ThemeInputTokens?
    let textEmphasis: [String: ThemeColor]?
    let shadow: ThemeShadow?
    let agent: ThemeColor?
    let syntax: [String: ThemeColor]?

    func make(dark: Bool) throws -> Theme {
        var theme = dark ? Theme.defaultDark : Theme.defaultLight
        try ThemeTokenMaps.apply(colors?.mapValues(\.value), to: &theme.colors, using: ThemeTokenMaps.colors)
        for (name, font) in typography ?? [:] {
            guard let key = ThemeTokenMaps.typography[name] else { throw ThemeResourceError.invalidToken(name) }
            theme.typography[keyPath: key] = try font.token()
        }
        try ThemeTokenMaps.metrics(spacing, to: &theme.spacing, using: ThemeTokenMaps.spacing)
        try ThemeTokenMaps.metrics(radius, to: &theme.radius, using: ThemeTokenMaps.radius)
        try motion?.apply(to: &theme)
        try ThemeTokenMaps.apply(inputs?.colors?.mapValues(\.value), to: &theme.inputs, using: ThemeTokenMaps.inputColors)
        try ThemeTokenMaps.metrics(inputs?.metrics, to: &theme.inputs, using: ThemeTokenMaps.inputMetrics)
        for (name, color) in textEmphasis ?? [:] {
            switch name {
            case "placeholder": theme.textEmphasis.placeholder = color.value
            case "disabled": theme.textEmphasis.disabled = color.value
            default: throw ThemeResourceError.invalidToken(name)
            }
        }
        if let shadow { theme.elevation.low = try shadow.token() }
        if let agent { theme.extensions[EditorThemeTokens.self].agent = agent.value }
        for (name, color) in syntax ?? [:] {
            guard SyntaxToken(rawValue: name) != nil else { throw ThemeResourceError.invalidToken(name) }
            theme.extensions[EditorThemeTokens.self].syntax[name] = color.value
        }
        return theme
    }
}

