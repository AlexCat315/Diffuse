import Foundation
import GuavaUICompose
import GuavaUIRuntime
import PluginRuntime
import Testing
@testable import EditorCore

@Suite("Default theme resource")
struct DefaultThemeTests {
    @Test(arguments: [false, true])
    func resourcePreservesExistingTokens(dark: Bool) throws {
        let url = try #require(BundledPlugins.plugin(id: "studio.theme.default")?.package)
        let package = try PluginPackageLoader().load(at: url)
        #expect(package.runtime == nil)
        let resource = try JSONDecoder().decode(ThemeResource.self, from: package.resource(at: "resources/theme.json"))
        let variant = try #require(dark ? resource.dark : resource.light)
        let actual = try variant.make(dark: dark)
        let expected = OriginalDefaultTheme.make(dark: dark)
        for (_, key) in ThemeTokenMaps.colors { #expect(actual.colors[keyPath: key] == expected.colors[keyPath: key]) }
        for (_, key) in ThemeTokenMaps.typography { #expect(actual.typography[keyPath: key] == expected.typography[keyPath: key]) }
        for (_, key) in ThemeTokenMaps.spacing { #expect(actual.spacing[keyPath: key] == expected.spacing[keyPath: key]) }
        for (_, key) in ThemeTokenMaps.radius { #expect(actual.radius[keyPath: key] == expected.radius[keyPath: key]) }
        for (_, key) in ThemeTokenMaps.inputColors { #expect(actual.inputs[keyPath: key] == expected.inputs[keyPath: key]) }
        for (_, key) in ThemeTokenMaps.inputMetrics { #expect(actual.inputs[keyPath: key] == expected.inputs[keyPath: key]) }
        #expect(actual.extensions[EditorThemeTokens.self].assistant == expected.extensions[EditorThemeTokens.self].assistant)
        #expect(actual.textEmphasis.placeholder == expected.textEmphasis.placeholder)
        #expect(actual.textEmphasis.disabled == expected.textEmphasis.disabled)
        #expect(actual.motion.fast == expected.motion.fast)
        #expect(actual.motion.standard == expected.motion.standard)
        #expect(actual.motion.slow == expected.motion.slow)
        #expect(actual.motion.standardEasing == expected.motion.standardEasing)
        #expect(actual.elevation.low.color == expected.elevation.low.color)
        #expect(actual.elevation.low.blur == expected.elevation.low.blur)
        #expect(actual.elevation.low.offsetX == expected.elevation.low.offsetX)
        #expect(actual.elevation.low.offsetY == expected.elevation.low.offsetY)
    }
}

