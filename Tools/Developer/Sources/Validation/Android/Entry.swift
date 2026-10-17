internal import Foundation
internal import ToolSupport

/// Android validation harness: one entry point dispatching to the cross-compile
/// probe, the SharedCounter demo, the Gallery, the exported game, and the
/// logging journal. Each operation mirrors its former `scripts/android/*.py`
/// program, sharing `AndroidTools` for device discovery.
package enum AndroidValidation {
  package static func run(_ arguments: [String]) throws {
    guard let operation = arguments.first else {
      throw ToolError.message(
        "Expected an operation: validate, demo, gallery, game, or logging")
    }
    let rest = Array(arguments.dropFirst())
    switch operation {
    case "validate": try ValidateOperation.run(rest)
    case "demo": try DemoOperation.run(rest)
    case "gallery": try GalleryOperation.run(rest)
    case "game": try GameOperation.run(rest)
    case "logging": try LoggingOperation.run(rest)
    case "--help", "-h": Terminal.info(usage)
    default: throw ToolError.message("Unknown android operation '\(operation)'")
    }
  }

  static let usage = """
    guava-dev android <operation> …

      validate [--android-sdk S] [--ndk D] [--serial S]
          cross-compile and run the strict NativeRHI/GuavaUI Vulkan probes
      demo [--android-sdk S] [--serial S]
          validate the SharedCounter APK: pixels, touch, IME, recreation
      gallery [--android-sdk S] [--serial S] [--pages P …] [--interactions-only]
          render every Gallery page and check pixels and semantics
      game [--android-sdk S] [--serial S] [--package ID]
          exercise the exported CrystalRush APK
      logging PROJECT
          verify a running Profile app's Java/JNI/Swift journal
    """
}
