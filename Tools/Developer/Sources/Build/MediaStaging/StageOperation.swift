internal import Foundation
internal import ToolSupport

/// `--platform`, `--vendor`, `--check`: the former `stage.py` command line.
enum StageOperation {
  static func run(_ arguments: [String], environment: [String: String]) throws {
    var platform: String?
    var vendor: String?
    var check = false
    var index = 0
    while index < arguments.count {
      let token = arguments[index]
      index += 1
      switch token {
      case "-h", "--help":
        print(MediaStaging.usage)
        return
      case "--check":
        check = true
      case "--platform", "--vendor":
        guard index < arguments.count else {
          throw ToolError.message("argument \(token): expected one argument")
        }
        if token == "--platform" { platform = arguments[index] } else { vendor = arguments[index] }
        index += 1
      default:
        if let value = inlineValue(of: "--platform", in: token) {
          platform = value
        } else if let value = inlineValue(of: "--vendor", in: token) {
          vendor = value
        } else {
          throw ToolError.message("unrecognized arguments: \(token)")
        }
      }
    }
    let vendorRoot = (vendor.map(absolutePath) ?? MediaStaging.defaultVendor)
      .resolvingSymlinksInPath()
    try stage(
      platform: platform ?? Targets.host(), vendor: vendorRoot, check: check,
      environment: environment)
  }

  /// Whether the staged variant matches the pinned version, the pinned source
  /// digest and every file digest recorded in its provenance stamp.
  static func isReady(platform: String, vendor: URL) -> Bool {
    do {
      let variant = vendor.appendingPathComponent("FFmpeg.artifactbundle").appendingPathComponent(
        platform)
      let provenance = try JSONDecoder().decode(
        Provenance.self,
        from: try Fs.read(variant.appendingPathComponent("provenance.json")))
      return provenance.version == MediaStaging.version
        && provenance.sourceSha256 == MediaStaging.sourceSHA256
        && !provenance.files.isEmpty
        && provenance.files.allSatisfy { path, digest in
          (try? SHA256.hex(file: variant.appendingPathComponent(path))) == digest
        }
    } catch {
      return false
    }
  }

  static func stage(
    platform name: String, vendor: URL, check: Bool,
    environment: [String: String]
  ) throws {
    guard Targets.supported.contains(name) else {
      throw ToolError.message("Unsupported FFmpeg target")
    }
    let bundle = vendor.appendingPathComponent("FFmpeg.artifactbundle")
    let variant = bundle.appendingPathComponent(name)
    let stamp = variant.appendingPathComponent("provenance.json")

    if check {
      guard isReady(platform: name, vendor: vendor) else {
        throw ToolError.message("FFmpeg \(name) is not staged")
      }
      return
    }

    let cache = Repository.path("Engine/Media/build/cache")
    try Fs.directory(cache)
    let archive = cache.appendingPathComponent("ffmpeg-\(MediaStaging.version).tar.xz")
    guard
      let remote = URL(string: "https://ffmpeg.org/releases/ffmpeg-\(MediaStaging.version).tar.xz")
    else {
      throw ToolError.message("Invalid FFmpeg source URL for \(MediaStaging.version)")
    }
    try Download.file(from: remote, to: archive, sha256: MediaStaging.sourceSHA256)

    let source = cache.appendingPathComponent("ffmpeg-\(MediaStaging.version)")
    if !FileManager.default.fileExists(atPath: source.path) {
      try Archive.extract(archive, to: cache)
    }

    let build = Repository.path("Engine/Media/build/\(name)")
    try Fs.directory(build)
    let prefix = build.appendingPathComponent("install")
    let options =
      configureOptions(prefix: prefix) + (try Targets.options(for: name, environment: environment))
    try Shell.inherit(
      ["sh", source.appendingPathComponent("configure").path] + options,
      at: build, environment: environment)
    try Shell.inherit(["make", "-j4"], at: build, environment: environment)
    try Shell.inherit(["make", "install"], at: build, environment: environment)

    try Fs.directory(variant)
    try merge(
      prefix.appendingPathComponent("include"), into: variant.appendingPathComponent("include"))
    try merge(prefix.appendingPathComponent("lib"), into: variant.appendingPathComponent("lib"))
    if FileManager.default.fileExists(atPath: prefix.appendingPathComponent("bin").path) {
      try merge(prefix.appendingPathComponent("bin"), into: variant.appendingPathComponent("bin"))
    }
    for license in ["COPYING.LGPLv2.1", "COPYING.LGPLv3", "LICENSE.md"] {
      try Fs.copy(
        source.appendingPathComponent(license), to: bundle.appendingPathComponent(license))
    }

    let windows = name.hasPrefix("windows-")
    let filename = windows ? "FFmpeg.lib" : "libFFmpeg.a"
    let libraries = MediaStaging.libraries.map {
      variant.appendingPathComponent("lib").appendingPathComponent(
        windows ? "\($0).lib" : "lib\($0).a")
    }
    let combined = variant.appendingPathComponent("lib").appendingPathComponent(filename)
    if windows {
      // MSVC resolves `lib` from PATH; /OUT: uses a Windows path.
      try Shell.inherit(
        ["lib", "/OUT:\(combined.path)"] + libraries.map(\.path), environment: environment)
    } else if name.hasPrefix("ios-") || name.hasPrefix("macos-") {
      try Shell.inherit(
        ["xcrun", "libtool", "-static", "-o", combined.path] + libraries.map(\.path),
        environment: environment)
    } else {
      let android = name.hasPrefix("android-")
      let ar =
        android
        ? options.first { $0.hasPrefix("--ar=") }.map { String($0.dropFirst("--ar=".count)) }
          ?? "ar"
        : "ar"
      let script =
        "CREATE \(combined.path)\n"
        + libraries.map { "ADDLIB \($0.path)\n" }.joined()
        + "SAVE\nEND\n"
      try Shell.inherit([ar, "-M"], environment: environment, input: script)
    }

    var artifacts: [String: ArtifactBundle.Artifact] = [:]
    let manifest = bundle.appendingPathComponent("info.json")
    if FileManager.default.fileExists(atPath: manifest.path) {
      // Only the FFmpeg entry survives: other artifacts in the bundle are
      // not this tool's to rewrite.
      artifacts = try JSONDecoder().decode(ArtifactBundle.self, from: try Fs.read(manifest))
        .artifacts.filter { $0.key == "FFmpeg" }
    }
    var entry =
      artifacts["FFmpeg"]
      ?? ArtifactBundle.Artifact(type: "staticLibrary", version: MediaStaging.version, variants: [])
    guard entry.version == MediaStaging.version else {
      throw ToolError.message("Remove old FFmpeg artifacts before changing versions")
    }
    let triple = Targets.triple(name)
    entry.variants = entry.variants.filter { !$0.supportedTriples.contains(triple) }
    entry.variants.append(
      ArtifactBundle.Variant(
        path: "\(name)/lib/\(filename)",
        supportedTriples: [triple],
        staticLibraryMetadata: .init(headerPaths: ["\(name)/include"])))
    artifacts["FFmpeg"] = entry

    var files: [String: String] = [:]
    for file in try Fs.files(in: variant)
    where file.standardizedFileURL.path != stamp.standardizedFileURL.path {
      files[Fs.relative(file, to: variant)] = try SHA256.hex(file: file)
    }
    let provenance = Provenance(
      version: MediaStaging.version, sourceSha256: MediaStaging.sourceSHA256,
      license: "LGPL", files: files)
    try Fs.json(provenance, to: stamp)

    let temporary = manifest.deletingPathExtension().appendingPathExtension("tmp")
    try Fs.json(ArtifactBundle(schemaVersion: "1.0", artifacts: artifacts), to: temporary)
    try Fs.replace(temporary, at: manifest)
  }

  /// The target-independent, LGPL-only, minimal-feature configure list.
  private static func configureOptions(prefix: URL) -> [String] {
    [
      "--prefix=\(prefix.path)", "--disable-shared", "--enable-static", "--enable-pic",
      "--disable-autodetect",
      "--disable-gpl", "--disable-nonfree", "--disable-doc", "--disable-debug", "--disable-network",
      "--disable-everything",
      "--enable-avformat", "--enable-avcodec", "--enable-avfilter", "--enable-swscale",
      "--enable-swresample",
      "--enable-ffmpeg", "--enable-ffprobe", "--enable-indev=lavfi", "--enable-protocol=file,pipe",
      "--enable-demuxer=mov,matroska,avi,wav,mp3,aac,ogg,flac,aiff,image2",
      "--enable-decoder=h264,hevc,mpeg4,mjpeg,png,vp8,vp9,av1,aac,mp3,vorbis,opus,flac,pcm_s16le,pcm_s24le,pcm_s32le,pcm_f32le,pcm_s16be",
      "--enable-parser=h264,hevc,mpeg4video,mpegaudio,aac,vorbis,opus,flac,vp9,av1",
      "--enable-encoder=mpeg4,mjpeg,png,aac,flac,pcm_s16le,pcm_f32le",
      "--enable-muxer=mp4,ipod,mov,matroska,wav,flac,image2,null",
      "--enable-filter=buffer,abuffer,buffersink,abuffersink,trim,atrim,setpts,asetpts,concat,scale,format,aformat,aresample,anull,anullsrc,null,sine,color,volume,amix,pad,fps",
    ]
  }
}

/// The value of `--name=value`, or nil when `token` is not that option.
private func inlineValue(of option: String, in token: String) -> String? {
  let prefix = option + "="
  return token.hasPrefix(prefix) ? String(token.dropFirst(prefix.count)) : nil
}

/// Makes a possibly relative command-line path absolute against the caller's
/// working directory, matching `pathlib.Path(...).resolve()`.
private func absolutePath(_ path: String) -> URL {
  if (path as NSString).isAbsolutePath { return URL(fileURLWithPath: path).standardizedFileURL }
  return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(path)
    .standardizedFileURL
}
