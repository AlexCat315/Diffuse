import Foundation
@testable import GameRuntime
import XCTest

final class PlayerInstallValidatorTests: XCTestCase {
    private let resourceBundleBases = [
        "GuavaEditor_EditorCore",
        "GuavaEngine_RenderBackend",
        "GuavaUI_GuavaUIApp",
        "GuavaUI_GuavaUICompose",
        "GuavaUI_GuavaUIWorkspace",
    ]

    func testPortableLayoutAcceptsBundleAndResourcesDirectories() throws {
        let root = try makePortableLayout()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("GuavaUI_GuavaUICompose.bundle")
        )
        try createResourceBundle(
            named: "GuavaUI_GuavaUICompose",
            in: root,
            suffix: "resources"
        )

        let report = try PlayerInstallValidator.validateLayout(
            executableURL: root.appendingPathComponent(executableName)
        )

        XCTAssertTrue(report.contains("5 resource bundles"))
    }

    func testMissingResourcesAreReportedTogether() throws {
        let root = try makePortableLayout()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("GuavaEngine_RenderBackend.bundle")
        )
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("GuavaUI_GuavaUIApp.bundle")
        )

        XCTAssertThrowsError(try PlayerInstallValidator.validateLayout(
            executableURL: root.appendingPathComponent(executableName)
        )) { error in
            guard case let PlayerInstallValidationError.missingComponents(missing) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(missing, [
                "GuavaEngine_RenderBackend.{bundle,resources}",
                "GuavaUI_GuavaUIApp.{bundle,resources}",
            ])
        }
    }

    func testMacApplicationLooksForResourcesInContentsResources() throws {
        #if os(macOS)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-player-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("My Game.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/My Game")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeExecutable(at: executable)
        try writeApplicationInfoPlist(to: app, executable: "My Game")
        for base in resourceBundleBases {
            try createResourceBundle(
                named: base,
                in: app.appendingPathComponent("Contents/Resources", isDirectory: true)
            )
        }

        XCTAssertNoThrow(try PlayerInstallValidator.validateLayout(executableURL: executable))
        #endif
    }

    func testMacApplicationRejectsMissingInfoPlist() throws {
        #if os(macOS)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-player-app-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("My Game.app", isDirectory: true)
        let executable = app.appendingPathComponent("Contents/MacOS/My Game")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try makeExecutable(at: executable)
        for base in resourceBundleBases {
            try createResourceBundle(
                named: base,
                in: app.appendingPathComponent("Contents/Resources", isDirectory: true)
            )
        }

        XCTAssertThrowsError(try PlayerInstallValidator.validateLayout(
            executableURL: executable
        )) { error in
            guard case let PlayerInstallValidationError.missingComponents(missing) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(missing.contains("Contents/Info.plist"))
        }
        #endif
    }

    func testCommandLineFallbackLocatesExecutable() throws {
        let root = try makePortableLayout()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(executableName)

        XCTAssertNoThrow(try PlayerInstallValidator.validateLayout(
            bundleExecutableURL: nil,
            arguments: [executable.path]
        ))
    }

    private func makePortableLayout() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-player-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeExecutable(at: root.appendingPathComponent(executableName))
        for base in resourceBundleBases {
            try createResourceBundle(named: base, in: root)
        }
        return root
    }

    private func createResourceBundle(named base: String,
                                      in root: URL,
                                      suffix: String = "bundle") throws {
        let bundle = root.appendingPathComponent("\(base).\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.guava.tests.\(base.lowercased().replacingOccurrences(of: "_", with: "-"))",
            "CFBundleName": base,
            "CFBundlePackageType": "BNDL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: bundle.appendingPathComponent("Info.plist"), options: [.atomic])
    }

    private func makeExecutable(at url: URL) throws {
        #if os(Windows)
        try Data("player".utf8).write(to: url)
        #else
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        #endif
    }

    private var executableName: String {
        #if os(Windows)
        "GuavaPlayer.exe"
        #else
        "GuavaPlayer"
        #endif
    }

    private func writeApplicationInfoPlist(to app: URL,
                                           executable: String) throws {
        let info: [String: Any] = [
            "CFBundleExecutable": executable,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
    }
}
