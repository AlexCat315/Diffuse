internal import Foundation
private import ToolSupport

#if canImport(Glibc)
  private import Glibc
#endif

/// `verify` — real browser verification for the Wasm prototype and the native
/// WebSocket Inspector. Replaces `GuavaUI/Browser/verify.py`.
enum VerifyOperation {
  static func run(_ arguments: [String]) throws {
    var parser = FlagParser(
      arguments, valued: ["--dist", "--screenshot"],
      switches: [
        "--require-webgpu", "--require-hardware-gpu",
        "--skip-native", "--native-only",
      ])
    try parser.parse()
    if parser.flags.contains("--help") {
      Terminal.info(Browser.usage)
      return
    }
    if let unexpected = parser.positionals.first {
      throw ToolError.message("unrecognized arguments: \(unexpected)")
    }
    try verify(
      requireWebGPU: parser.flags.contains("--require-webgpu"),
      requireHardwareGPU: parser.flags.contains("--require-hardware-gpu"),
      skipNative: parser.flags.contains("--skip-native"),
      nativeOnly: parser.flags.contains("--native-only"),
      dist: parser.values["--dist"] ?? "dist",
      screenshot: parser.values["--screenshot"])
  }

  static func verify(
    requireWebGPU: Bool, requireHardwareGPU: Bool, skipNative: Bool,
    nativeOnly: Bool, dist: String, screenshot: String?
  ) throws {
    let root = Browser.sdkRoot.appendingPathComponent("Browser")
    let distURL =
      (dist as NSString).isAbsolutePath
      ? URL(fileURLWithPath: dist).standardizedFileURL
      : root.appendingPathComponent(dist).standardizedFileURL
    if !nativeOnly
      && !FileManager.default.fileExists(atPath: distURL.appendingPathComponent("guava.wasm").path)
    {
      throw ToolError.message("Run npm ci and npm run build first")
    }

    // Concurrent iframe scripts can exceed the stdlib's small listen backlog
    // while a second cold browser context is loading the Wasm/fonts.
    let directory = nativeOnly ? root.deletingLastPathComponent() : distURL
    let server = try staticServer(directory: directory, backlog: 128)
    server.start()
    defer { server.stop() }

    var native: SpawnedProcess?
    var nativePort: Int?
    defer { native?.terminate() }
    if !skipNative {
      let port = try freePort()
      nativePort = port
      let process = try SpawnedProcess(
        executable: try Shell.require("swift"),
        arguments: [
          "run", "--skip-build",
          "--package-path",
          root.deletingLastPathComponent()
            .appendingPathComponent("Portable").path,
          "GuavaUIDevToolsProbe", String(port),
        ])
      native = process
      let deadline = Date(timeIntervalSinceNow: 15)
      while true {
        if canConnect(port: port, timeout: 0.2) { break }
        if process.poll() != nil || Date() > deadline {
          throw ToolError.message(
            "Native probe failed; run swift build --package-path ../Portable first:\n"
              + process.output)
        }
        usleep(50_000)
      }
    }

    let strictGPU = requireWebGPU || requireHardwareGPU
    var flags = ["--no-sandbox", "--enable-unsafe-webgpu"]
    // Headless Chromium otherwise forces software rendering, even when a
    // working native GPU is available.
    flags.append(strictGPU ? "--enable-gpu" : "--use-angle=swiftshader")
    flags.append(contentsOf: chromiumArguments())

    let browser = try ChromiumBrowser.launch(executable: nil, arguments: flags)
    defer { browser.close() }

    let baseURL = "http://127.0.0.1:\(server.port)/"
    if nativeOnly {
      try nativeChecks(
        browser, baseURL: baseURL, nativePort: try unwrap(nativePort),
        clientPath: "DevTools/Client/index.html", screenshot: screenshot)
      return
    }

    try previewChecks(
      browser, baseURL: baseURL, renderer: "canvas2d",
      screenshot: strictGPU ? nil : screenshot)
    if requireHardwareGPU { try hardwareAdapterCheck(browser, baseURL: baseURL) }
    try previewChecks(
      browser, baseURL: baseURL, renderer: strictGPU ? "webgpu" : "",
      screenshot: strictGPU ? screenshot : nil, scale: 2)
    if let nativePort, native != nil {
      try nativeChecks(browser, baseURL: baseURL, nativePort: nativePort)
    }
  }

  /// The extra Chromium flags the reference script reads from the environment.
  private static func chromiumArguments() -> [String] {
    let raw = ProcessInfo.processInfo.environment["GUAVA_CHROMIUM_ARGS"] ?? "[]"
    guard let value = try? JSON.parse(raw), let items = value.array else { return [] }
    return items.compactMap(\.string)
  }

  /// Requires a real hardware WebGPU adapter, never a software fallback.
  private static func hardwareAdapterCheck(_ browser: ChromiumBrowser, baseURL: String) throws {
    let page = try browser.newPage()
    defer { try? page.close() }
    try page.goto(baseURL + "?renderer=webgpu", waitUntil: .networkIdle)
    try page.waitForFunction("window.guavaDebug?.snapshot != null", timeout: 30)
    let info = try page.evaluate("guavaDebug.gpuInfo")
    let present = !info.isNull && info.object?.isEmpty == false
    try ensure(
      present && info["isFallbackAdapter"]?.bool == false && !(info["lost"]?.isTruthy ?? true),
      info.compactText)
    let adapterName = ["vendor", "architecture", "device", "description"]
      .map { info[$0]?.text ?? "" }.joined(separator: " ").lowercased()
    try ensure(
      !["swiftshader", "llvmpipe", "lavapipe", "software", "warp"].contains(
        where: adapterName.contains),
      info.compactText)
    Terminal.info("Hardware WebGPU adapter: \(info.compactText)")
    flushOutput()
  }

  private static func unwrap(_ value: Int?) throws -> Int {
    guard let value else { throw ToolError.message("The native probe port is missing") }
    return value
  }
}
