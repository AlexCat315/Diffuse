import Testing
import Foundation
import PluginRuntime
@testable import EditorCore

@Suite("EditorCore resources")
struct EditorCoreResourceBundleTests {
    @Test("localization bundle resolves through the packaged resource locator")
    func localizationBundleResolves() {
        #expect(EditorCoreResourceBundle.bundle.path(
            forResource: "en",
            ofType: "lproj"
        ) != nil)
    }

    @Test("every packaged plugin loads from the resource bundle")
    func packagedPluginsLoad() throws {
        let bundle = EditorCoreResourceBundle.bundle
        let root = bundle.url(forResource: "Plugins", withExtension: nil)
            ?? bundle.bundleURL.appendingPathComponent("Plugins", isDirectory: true)
        let packages = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "coveplugin" }
        #expect(!packages.isEmpty, "No plugins in \(root.path); bundle resources: \(String(describing: bundle.resourceURL))")
        for package in packages {
            let loaded = try PluginPackageLoader().load(at: package)
            #expect(BundledPlugins.plugin(id: loaded.manifest.id) != nil, "Missing bundled plugin at \(package.path)")
        }
    }
}
