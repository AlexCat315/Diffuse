import EngineKernel
import Foundation
import Testing

@Suite("PackageResourceBundle")
struct PackageResourceBundleTests {
    @Test("locates resource bundles in an explicit application resources root")
    func locatesApplicationResourceBundle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guava-package-resources-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        let expected = try makeBundle(named: "Example", suffix: "bundle", in: resources)

        let located = PackageResourceBundle.locate(named: "Example",
                                                   searchRoots: [resources])

        #expect(located?.bundleURL.standardizedFileURL == expected.standardizedFileURL)
    }

    @Test("supports SwiftPM resources directories and reports missing bundles")
    func locatesResourcesDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guava-package-resources-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = try makeBundle(named: "Example", suffix: "resources", in: root)

        #expect(PackageResourceBundle.locate(named: "Missing", searchRoots: [root]) == nil)
        #expect(PackageResourceBundle.locate(named: "Example", searchRoots: [root])?
            .bundleURL.standardizedFileURL == expected.standardizedFileURL)
    }

    @Test("supports target bundles renamed by an aggregate package")
    func locatesFirstAvailableBundleName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "guava-package-resources-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = try makeBundle(named: "Workspace_EditorApp", suffix: "bundle", in: root)

        let located = PackageResourceBundle.locate(
            named: ["Standalone_EditorApp", "Workspace_EditorApp"],
            mainBundle: .main,
            executableURL: root.appendingPathComponent("EditorApp"),
            arguments: []
        )

        #expect(located?.bundleURL.standardizedFileURL == expected.standardizedFileURL)
    }

    private func makeBundle(named name: String,
                            suffix: String,
                            in root: URL) throws -> URL {
        let bundle = root.appendingPathComponent("\(name).\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.guava.tests.\(name.lowercased())",
            "CFBundleName": name,
            "CFBundlePackageType": "BNDL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: bundle.appendingPathComponent("Info.plist"), options: [.atomic])
        return bundle
    }
}
