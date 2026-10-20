internal import Foundation
#if canImport(AppKit)
internal import AppKit
#endif

/// Default handling for ⌘-clicked OSC 8 hyperlinks: hand them to the system.
/// Programs choose these URIs, so only web, mail and file links are accepted.
enum LinkOpener {
    static let schemes: Set<String> = ["http", "https", "mailto", "file"]

    static func url(_ link: String) -> URL? {
        guard let url = URL(string: link), let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
        return url
    }

    static func open(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
        process.arguments = [url.absoluteString]
        try? process.run()
        #endif
    }
}
