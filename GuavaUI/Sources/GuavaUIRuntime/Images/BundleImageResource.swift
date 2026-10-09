import Foundation

/// Bundle-backed image resource that keeps packaged asset lookup details out
/// of view code.
public struct BundleImageResource: @unchecked Sendable, CustomStringConvertible {
    public let name: String
    public let fileExtension: String
    public let bundle: Bundle
    public let subdirectory: String?

    public init(name: String,
                fileExtension: String,
                bundle: Bundle,
                subdirectory: String? = nil) {
        self.name = name
        self.fileExtension = fileExtension
        self.bundle = bundle
        self.subdirectory = subdirectory
    }

    public static func svg(named name: String,
                           in bundle: Bundle,
                           subdirectory: String? = nil) -> Self {
        Self(name: name,
             fileExtension: "svg",
             bundle: bundle,
             subdirectory: subdirectory)
    }

    public var url: URL? {
        if let subdirectory,
           let url = bundle.url(forResource: name,
                                withExtension: fileExtension,
                                subdirectory: subdirectory) {
            return url
        }
        return bundle.url(forResource: name,
                          withExtension: fileExtension)
    }

    public var description: String {
        if let subdirectory {
            return "\(bundle.bundlePath)#\(subdirectory)/\(name).\(fileExtension)"
        }
        return "\(bundle.bundlePath)#\(name).\(fileExtension)"
    }
}