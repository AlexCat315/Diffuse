internal import Foundation
internal import MediaStaging
internal import PluginStaging
internal import ToolSupport

/// Builds the Engine and GuavaUI native C/C++ dependencies.
///
/// Replaces the repository-root `bootstrap.py`. Media (FFmpeg) and Wasmtime are
/// independent dependency graphs, so this tool only rebuilds them when their
/// readiness gates report stale output; the graphics libraries are always
/// configured incrementally unless `--force` invalidates the build stamps.
package enum NativeBootstrap {
  static let usage = """
    guava-dev native-bootstrap [--force]

      --force  Discard Engine/build/native and restage Media and Wasmtime
               even when they already verify.
    """

  package static func run(_ arguments: [String]) throws {
    if arguments.contains("--help") || arguments.contains("-h") {
      Terminal.info(usage)
      return
    }
    if let unknown = arguments.first(where: { $0 != "--force" }) {
      throw ToolError.message("Unknown native-bootstrap argument: \(unknown)")
    }
    try Bootstrap.run(arguments)
  }
}
