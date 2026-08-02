import Foundation

/// Locates SwiftPM resource bundles in both development layouts and packaged
/// applications. SwiftPM's generated accessor only searches beside
/// `Bundle.main`; a signed macOS application must instead store resources in
/// `Contents/Resources`.
public enum PackageResourceBundle {
    public static func locate(named baseNames: [String],
                              mainBundle: Bundle = .main,
                              executableURL: URL? = Bundle.main.executableURL,
                              arguments: [String] = CommandLine.arguments) -> Bundle? {
        for baseName in baseNames {
            if let bundle = locate(named: baseName,
                                   mainBundle: mainBundle,
                                   executableURL: executableURL,
                                   arguments: arguments) {
                return bundle
            }
        }
        return nil
    }

    public static func locate(named baseName: String,
                              mainBundle: Bundle = .main,
                              executableURL: URL? = Bundle.main.executableURL,
                              arguments: [String] = CommandLine.arguments) -> Bundle? {
        var roots: [URL] = []
        if let resourceURL = mainBundle.resourceURL {
            roots.append(resourceURL)
        }
        roots.append(mainBundle.bundleURL)
        // SwiftPM test runners are application-style `.xctest` bundles while
        // target resources remain siblings in the configuration directory.
        roots.append(mainBundle.bundleURL.deletingLastPathComponent())
        if let executableURL {
            let executableDirectory = executableURL.standardizedFileURL.deletingLastPathComponent()
            roots.append(executableDirectory)
            let contentsDirectory = executableDirectory.deletingLastPathComponent()
            if executableDirectory.lastPathComponent == "MacOS",
               contentsDirectory.lastPathComponent == "Contents" {
                roots.append(contentsDirectory.appendingPathComponent("Resources", isDirectory: true))
            }
        }
        // `swift test` may run through swiftpm-testing-helper, making that
        // helper Bundle.main. The actual test bundle is still passed as an
        // argument and its sibling directory contains target resources.
        for argument in arguments {
            var url = URL(fileURLWithPath: argument).standardizedFileURL
            while url.path != url.deletingLastPathComponent().path {
                if url.pathExtension == "xctest" {
                    roots.append(url.deletingLastPathComponent())
                    break
                }
                url.deleteLastPathComponent()
            }
        }
        return locate(named: baseName, searchRoots: roots)
    }

    /// Explicit-root overload used by installers and tests that inspect a
    /// layout other than the currently running executable.
    public static func locate(named baseName: String,
                              searchRoots: [URL]) -> Bundle? {
        var visited = Set<String>()
        for root in searchRoots {
            let standardizedRoot = root.standardizedFileURL
            guard visited.insert(standardizedRoot.path).inserted else { continue }
            for suffix in ["bundle", "resources"] {
                let candidate = standardizedRoot.appendingPathComponent(
                    "\(baseName).\(suffix)",
                    isDirectory: true
                )
                if let bundle = Bundle(url: candidate) {
                    return bundle
                }
            }
        }
        return nil
    }

    public static func required(named baseName: String,
                                mainBundle: Bundle = .main,
                                executableURL: URL? = Bundle.main.executableURL,
                                arguments: [String] = CommandLine.arguments) -> Bundle {
        guard let bundle = locate(named: baseName,
                                  mainBundle: mainBundle,
                                  executableURL: executableURL,
                                  arguments: arguments) else {
            Swift.fatalError("could not locate resource bundle \(baseName).{bundle,resources}")
        }
        return bundle
    }

    public static func required(named baseNames: [String],
                                mainBundle: Bundle = .main,
                                executableURL: URL? = Bundle.main.executableURL,
                                arguments: [String] = CommandLine.arguments) -> Bundle {
        guard let bundle = locate(named: baseNames,
                                  mainBundle: mainBundle,
                                  executableURL: executableURL,
                                  arguments: arguments) else {
            let names = baseNames.joined(separator: ", ")
            Swift.fatalError("could not locate any resource bundle named [\(names)]")
        }
        return bundle
    }
}
