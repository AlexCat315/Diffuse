internal import Foundation
private import ToolSupport

/// Browser verification and local development servers for the GuavaUI web
/// prototype and the native DevTools client.
///
/// The first token of `arguments` selects the operation; the remaining tokens
/// are its flags. This replaces the former `GuavaUI/Browser/*.py` scripts and
/// `Platforms/Web/Plugins/tests/browser.py`.
package enum Browser {
  static var sdkRoot: URL {
    ProcessInfo.processInfo.environment["GUAVA_SDK_ROOT"]
      .map { URL(fileURLWithPath: $0).standardizedFileURL }
      ?? Repository.path("GuavaUI")
  }
  package static func run(_ arguments: [String]) throws {
    guard let operation = arguments.first else {
      throw ToolError.message("Missing operation; expected \(operations.joined(separator: ", "))")
    }
    let flags = Array(arguments.dropFirst())
    switch operation {
    case "verify": try VerifyOperation.run(flags)
    case "native-demo": try NativeDemoOperation.run(flags)
    case "dev": try DevOperation.run(flags)
    case "verify-dev": try VerifyDevOperation.run(flags)
    case "serve": try ServeOperation.run(flags)
    case "build-fonts": try BuildFontsOperation.run(flags)
    case "web-plugins": try WebPluginsOperation.run(flags)
    case "-h", "--help": Terminal.info(usage)
    default:
      throw ToolError.message(
        "Unknown operation '\(operation)'; expected \(operations.joined(separator: ", "))")
    }
  }

  static let operations = [
    "verify", "native-demo", "dev", "verify-dev", "serve", "build-fonts", "web-plugins",
  ]

  static let usage = """
    guava-dev browser <operation> [options]

      verify       Verify the Wasm prototype and the native WebSocket Inspector in a real browser
      native-demo  Verify the native Compose/Metal mirror; start GuavaUIDemo --shared-counter first
      dev          Run the Swift/Wasm development server with complete-build reloads
      verify-dev   Exercise real Swift rebuilds, checkpoint retention and failed-build recovery
      serve        Serve the built Browser/dist directory over http.server-compatible HTTP
      build-fonts  Build the pinned FreeType/HarfBuzz submodules for the WASI SDK
      web-plugins  Run the Component -> Jco -> isolated Worker browser gate

      verify      [--require-webgpu] [--require-hardware-gpu] [--skip-native] [--native-only]
                  [--dist PATH] [--screenshot PATH]
      native-demo [--endpoint URL] [--screenshot PATH] [--require-presented]
      dev         [--port PORT]
      verify-dev
      serve       [--port PORT] [--dist PATH]
      build-fonts
      web-plugins --host PATH --probe PATH

    Every operation runs against the checkout discovered from the current
    directory (or GUAVA_ROOT); the browser build lives in GuavaUI/Browser.
    """
}
