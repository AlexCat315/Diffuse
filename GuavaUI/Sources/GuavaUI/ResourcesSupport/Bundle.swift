import Foundation
import EngineKernel

/// Resolves SwiftPM resources using the same rules on desktop and Android.
public enum ApplicationResources {
    public static func required(named name: String) -> Bundle {
        PackageResourceBundle.required(named: name)
    }
}
