@testable import EditorApp
import Foundation
import XCTest

final class ReleaseInstallValidatorTests: XCTestCase {
    private let bundleBases = [
        "GuavaEditor_EditorApp",
        "GuavaEditor_EditorCore",
        "GuavaEngine_RenderBackend",
        "GuavaUI_GuavaUIApp",
        "GuavaUI_GuavaUICompose",
        "GuavaUI_GuavaUIWorkspace",
    ]

    func testCompletePortableLayoutPassesOnPOSIXAndWindows() throws {
        #if os(Windows)
        let platforms = [true]
        #else
        let platforms = [false, true]
        #endif
        for isWindows in platforms {
            let root = try makeLayout(isWindows: isWindows)
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent(isWindows ? "EditorApp.exe" : "EditorApp")

            let report = try EditorInstallValidator.validateEditorLayout(
                executableURL: executable,
                isWindows: isWindows
            )

            XCTAssertTrue(report.contains("4 executables"))
            XCTAssertTrue(report.contains("6 resource bundles"))
        }
    }

    func testMissingPlayerAndResourceBundleAreReportedTogether() throws {
        #if os(Windows)
        let isWindows = true
        let playerName = "GuavaPlayer.exe"
        let editorName = "EditorApp.exe"
        #else
        let isWindows = false
        let playerName = "GuavaPlayer"
        let editorName = "EditorApp"
        #endif
        let root = try makeLayout(isWindows: isWindows)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent(playerName))
        try FileManager.default.removeItem(
            at: root.appendingPathComponent("GuavaUI_GuavaUICompose.bundle")
        )

        XCTAssertThrowsError(try EditorInstallValidator.validateEditorLayout(
            executableURL: root.appendingPathComponent(editorName),
            isWindows: isWindows
        )) { error in
            guard case let EditorInstallValidationError.missingComponents(missing) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(missing.contains(playerName))
            XCTAssertTrue(missing.contains("GuavaUI_GuavaUICompose.{bundle,resources}"))
        }
    }

    func testMacApplicationBundleLayoutPasses() throws {
        #if os(macOS)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-app-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("GuavaEditor.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try writeApplicationInfoPlist(to: app)
        for url in [
            macOS.appendingPathComponent("EditorApp"),
            macOS.appendingPathComponent("GuavaPlayer"),
            helpers.appendingPathComponent("GuavaPluginHost"),
            helpers.appendingPathComponent("GuavaMCP"),
            helpers.appendingPathComponent("libwasmtime.dylib"),
        ] {
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path)
        }
        for base in bundleBases {
            try createResourceBundle(
                named: base,
                in: app.appendingPathComponent("Contents/Resources", isDirectory: true)
            )
        }

        XCTAssertNoThrow(try EditorInstallValidator.validateEditorLayout(
            executableURL: macOS.appendingPathComponent("EditorApp"),
            isWindows: false
        ))
        #endif
    }

    func testMacApplicationBundleRejectsMissingPluginRuntime() throws {
        #if os(macOS)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-app-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("GuavaEditor.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try writeApplicationInfoPlist(to: app)
        for url in [
            macOS.appendingPathComponent("EditorApp"),
            macOS.appendingPathComponent("GuavaPlayer"),
            helpers.appendingPathComponent("GuavaPluginHost"),
            helpers.appendingPathComponent("GuavaMCP"),
        ] {
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path)
        }
        for base in bundleBases {
            try createResourceBundle(
                named: base,
                in: app.appendingPathComponent("Contents/Resources", isDirectory: true)
            )
        }

        XCTAssertThrowsError(try EditorInstallValidator.validateEditorLayout(
            executableURL: macOS.appendingPathComponent("EditorApp"),
            isWindows: false
        )) { error in
            guard case let EditorInstallValidationError.missingComponents(missing) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(missing.contains("Contents/Helpers/libwasmtime.dylib"))
        }
        #endif
    }

    func testCommandLineExecutableFallbackSupportsPlatformsWithoutBundleURL() throws {
        let root = try makeLayout(isWindows: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("EditorApp.exe")

        XCTAssertNoThrow(try EditorInstallValidator.validateEditorLayout(
            bundleExecutableURL: nil,
            arguments: [executable.path],
            isWindows: true
        ))
    }

    func testMacApplicationBundleRejectsInvalidInfoPlist() throws {
        #if os(macOS)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-app-install-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("GuavaEditor.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let helpers = app.appendingPathComponent("Contents/Helpers", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        for url in [
            macOS.appendingPathComponent("EditorApp"),
            macOS.appendingPathComponent("GuavaPlayer"),
            helpers.appendingPathComponent("GuavaPluginHost"),
            helpers.appendingPathComponent("GuavaMCP"),
            helpers.appendingPathComponent("libwasmtime.dylib"),
        ] {
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: url.path)
        }
        for base in bundleBases {
            try createResourceBundle(
                named: base,
                in: app.appendingPathComponent("Contents/Resources", isDirectory: true)
            )
        }
        try Data("not-a-plist".utf8).write(
            to: app.appendingPathComponent("Contents/Info.plist")
        )

        XCTAssertThrowsError(try EditorInstallValidator.validateEditorLayout(
            executableURL: macOS.appendingPathComponent("EditorApp"),
            isWindows: false
        )) { error in
            guard case let EditorInstallValidationError.missingComponents(missing) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(missing.contains("Contents/Info.plist"))
        }
        #endif
    }

    func testNonExecutablePOSIXCompanionIsRejected() throws {
        #if !os(Windows)
        let root = try makeLayout(isWindows: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let player = root.appendingPathComponent("GuavaPlayer")
        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: player.path)

        XCTAssertThrowsError(try EditorInstallValidator.validateEditorLayout(
            executableURL: root.appendingPathComponent("EditorApp"),
            isWindows: false
        )) { error in
            guard case let EditorInstallValidationError.missingComponents(missing) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(missing.contains("GuavaPlayer"))
        }
        #endif
    }

    func testLaunchOptionsRecognizeValidationMode() throws {
        let options = try EditorAppLaunchOptions.load(
            arguments: ["EditorApp", "--validate-install"],
            environment: [:]
        )
        XCTAssertTrue(options.validateInstall)
    }

    private func makeLayout(isWindows: Bool) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Tools", isDirectory: true),
            withIntermediateDirectories: true
        )
        let suffix = isWindows ? ".exe" : ""
        for path in [
            "EditorApp\(suffix)",
            "GuavaPlayer\(suffix)",
            "Tools/GuavaPluginHost\(suffix)",
            "Tools/GuavaMCP\(suffix)",
        ] {
            let url = root.appendingPathComponent(path)
            try Data().write(to: url)
            if !isWindows {
                try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                      ofItemAtPath: url.path)
            }
        }
        for base in bundleBases {
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

    private func writeApplicationInfoPlist(to app: URL) throws {
        let info: [String: Any] = [
            "CFBundleExecutable": "EditorApp",
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
