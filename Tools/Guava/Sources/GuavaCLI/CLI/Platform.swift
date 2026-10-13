import Foundation

enum AppPlatform: String, Codable, CaseIterable, Sendable {
    case mac, win, linux, android, ios, web

    static var host: Self {
        #if os(macOS)
        .mac
        #elseif os(Windows)
        .win
        #else
        .linux
        #endif
    }

    func requireAvailable() throws {
        switch self {
        case .ios:
            throw ToolError.invalid("iOS application builds are not implemented yet; the native application host, signing and device deployment are missing.")
        case .web:
            throw ToolError.invalid("Web currently has a portable rendering prototype, not the complete GuavaUI application host. See GuavaUI/Browser.")
        case .mac, .win, .linux:
            guard self == Self.host else { throw ToolError.invalid("Build and run \(rawValue) applications on a \(rawValue) host; desktop cross-compilation is not configured.") }
        case .android:
            #if os(Windows)
            throw ToolError.invalid("The Android build backend currently supports macOS and Linux hosts.")
            #endif
        }
    }
}

enum BuildConfiguration: String, Codable {
    case debug, profile, release
    var swiftConfiguration: String { self == .debug ? "debug" : "release" }
    var swiftFlags: [String] { self == .profile ? ["-Xswiftc", "-DGUAVA_PROFILE"] : [] }
}

extension AppPlatform {
    var directoryName: String {
        switch self {
        case .mac: "macOS"
        case .win: "Windows"
        case .linux: "Linux"
        case .android: "Android"
        case .ios: "iOS"
        case .web: "Web"
        }
    }
}
