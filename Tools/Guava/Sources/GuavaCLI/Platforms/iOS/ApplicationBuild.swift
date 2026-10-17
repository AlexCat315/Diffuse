import Foundation

struct IOSBuild {
    let project: AppProject
    let root: URL
    let arguments: Arguments

    func run() throws {
        let device = arguments.value(.device)
        let sdk = device == nil ? "iphonesimulator" : "iphoneos"
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = device == nil ? "x86_64" : "arm64"
        #endif
        if device != nil && arguments.value(.team) == nil {
            throw ToolError.invalid("iOS device builds require --team APPLE_TEAM_ID and a configured signing identity")
        }
        let variant = "ios-\(arch)" + (device == nil ? "-simulator" : "")
        try DeveloperTool.run(["ios-native", "--sdk", sdk, "--arch", arch], root: root)
        var environment = SwiftPackage.environment(root: root)
        environment["GUAVA_ENGINE_ARTIFACT_ROOT"] = "build/\(variant)/vendor"
        environment["GUAVA_TEXT_ARTIFACT_ROOT"] = "../build/\(variant)/vendor"
        let derived = project.buildDirectory.appendingPathComponent("\(variant)/xcode")
        let configuration = arguments.configuration == .debug ? "Debug" : "Release"
        var command = ["xcodebuild", "-jobs", "4", "-project", project.directory.appendingPathComponent("Platforms/iOS/Application.xcodeproj").path,
            "-scheme", "Application", "-configuration", configuration, "-sdk", sdk,
            "-destination", "generic/platform=" + (device == nil ? "iOS Simulator" : "iOS"),
            "-derivedDataPath", derived.path, "ARCHS=\(arch)",
            "PRODUCT_BUNDLE_IDENTIFIER=\(project.configuration.application.id)",
            "INFOPLIST_KEY_CFBundleDisplayName=\(project.configuration.application.name)",
            "MARKETING_VERSION=\(project.configuration.version.name)",
            "CURRENT_PROJECT_VERSION=\(project.configuration.version.build)"]
        command += device == nil ? ["CODE_SIGNING_ALLOWED=NO"] : ["DEVELOPMENT_TEAM=\(arguments.value(.team)!)", "-allowProvisioningUpdates"]
        try Shell.run(command + ["build"], environment: environment)
        let app = derived.appendingPathComponent("Build/Products/\(configuration)-\(sdk)/Application.app")
        let output = arguments.url(.output) ?? project.buildDirectory.appendingPathComponent("\(variant)/Application.app")
        guard output.pathExtension == "app" else { throw ToolError.invalid("iOS --output must end in .app") }
        // Never remove a user directory to assemble an artifact.
        guard arguments.url(.output) == nil || !FileManager.default.fileExists(atPath: output.path) else {
            throw ToolError.invalid("Output exists: \(output.path); choose another --output or run guava clean")
        }
        if arguments.url(.output) == nil { try Files.remove(output) }
        try Files.copy(app, to: output)
        print("Built iOS application: \(output.path)")
        if arguments.operation == .run { try launch(output, device: device) }
    }

    private func launch(_ app: URL, device: String?) throws {
        let id = project.configuration.application.id
        if let device {
            try Shell.run(["xcrun", "devicectl", "device", "install", "app", "--device", device, app.path])
            try Shell.run(["xcrun", "devicectl", "device", "process", "launch", "--device", device, id])
        } else {
            let simulator = arguments.value(.simulator) ?? "booted"
            if simulator != "booted" {
                // bootstatus -b boots a shutdown simulator and waits for readiness.
                try Shell.run(["xcrun", "simctl", "bootstatus", simulator, "-b"])
            }
            try Shell.run(["xcrun", "simctl", "install", simulator, app.path])
            try Shell.run(["xcrun", "simctl", "launch", simulator, id])
        }
    }
}
