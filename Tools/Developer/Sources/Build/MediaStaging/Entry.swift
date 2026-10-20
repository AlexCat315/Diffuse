package import Foundation
internal import ToolSupport

/// Builds the pinned LGPL FFmpeg libraries and desktop editing tools.
///
/// Replaces `Engine/Media/Native/stage.py`. The tool is self-contained: it
/// downloads the pinned source archive, configures it per target, links the
/// combined static archive and records a provenance stamp so later runs can
/// verify readiness without network access.
package enum MediaStaging {
  /// Version of the pinned FFmpeg source release.
  static let version = "8.1.3"

  /// SHA-256 of `ffmpeg-8.1.3.tar.xz`, pinned in the former Python tool.
  static let sourceSHA256 = "7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3"

  /// Libraries linked into the combined `libFFmpeg.a` in this order.
  static let libraries = ["avformat", "avcodec", "avfilter", "swresample", "swscale", "avutil"]

  /// `<root>/Engine/Media/vendor`, the default `--vendor` target.
  static var defaultVendor: URL { Repository.path("Engine/Media/vendor") }

  static let usage = """
    guava-dev media [--platform NAME] [--vendor PATH] [--check]

      --platform NAME  Target to stage; defaults to the host target.
      --vendor PATH    Artifact bundle root; defaults to Engine/Media/vendor.
      --check          Verify the staged variant and exit without building.
    """

  /// `environment` defaults to this process's environment; callers that build
  /// a tailored toolchain environment (the native bootstrap) pass it down so
  /// configure, make and `xcrun` see the same compiler setup.
  package static func run(
    _ arguments: [String],
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws {
    try StageOperation.run(arguments, environment: environment)
  }

  /// The platform key this tool stages by default for the current host.
  package static func host() -> String { Targets.host() }

  /// Whether the staged variant for `platform` matches the pinned version and
  /// every digest recorded in its provenance stamp. Never throws; a missing
  /// or malformed stamp simply reports as not ready.
  package static func isReady(platform: String, vendor: URL) -> Bool {
    StageOperation.isReady(platform: platform, vendor: vendor)
  }
}
