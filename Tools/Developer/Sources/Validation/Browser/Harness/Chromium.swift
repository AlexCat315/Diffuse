internal import Foundation
private import ToolSupport

#if canImport(Glibc)
  private import Glibc
#endif

/// Launches Chromium with a remote-debugging port and manages page targets over
/// the DevTools Protocol, replacing Playwright's browser lifecycle. The caller's
/// flags are appended verbatim so the reference command lines are preserved.
final class ChromiumBrowser: @unchecked Sendable {
  let port: Int
  private let process: SpawnedProcess
  private let userData: URL
  private let connection: CDPConnection
  private var pages: [Page] = []
  private var contexts: [String: String] = [:]
  private var closed = false
  private let completedDownloads = Locked<Set<String>>([])

  static func launch(executable: URL?, arguments: [String]) throws -> ChromiumBrowser {
    let binary: URL
    if let executable {
      binary = executable
    } else {
      binary = try Chromium.locate()
    }
    let port = try freePort()
    let userData = FileManager.default.temporaryDirectory.appendingPathComponent(
      "cove-chromium-\(UUID().uuidString)")
    try Fs.reset(userData)
    let process = try SpawnedProcess(
      executable: binary,
      arguments: Chromium.baseArguments(port: port, userData: userData) + arguments)
    var connected = false
    defer {
      if !connected {
        process.terminate()
        try? Fs.remove(userData)
      }
    }
    let deadline = Date(timeIntervalSinceNow: 30)
    var websocket: URL?
    while Date() < deadline {
      if let status = process.poll() {
        throw ToolError.message("Chromium exited with status \(status):\n\(process.output)")
      }
      if let url = Chromium.debuggingEndpoint(from: process.output, port: port) {
        websocket = url
        break
      }
      usleep(100_000)
    }
    guard let websocket else {
      process.terminate()
      throw ToolError.message(
        "Chromium DevTools endpoint did not start on port \(port):\n\(process.output)")
    }
    let connection = try CDPConnection(url: websocket)
    connected = true
    return ChromiumBrowser(
      port: port, process: process, userData: userData,
      connection: connection)
  }

  private init(port: Int, process: SpawnedProcess, userData: URL, connection: CDPConnection) {
    self.port = port
    self.process = process
    self.userData = userData
    self.connection = connection
  }

  /// Each check owns fresh cookies/storage and download policy, matching the
  /// isolation of the original browser.new_page convenience operation.
  func newPage(viewport: Viewport? = nil, deviceScale: Double = 1) throws -> Page {
    let context = try connection.request("Target.createBrowserContext")
    guard let contextID = context["browserContextId"]?.string else {
      throw ToolError.message("Chromium did not create an isolated browser context")
    }
    var started = false
    defer {
      if !started {
        _ = try? connection.request(
          "Target.disposeBrowserContext", .object(["browserContextId": .string(contextID)]))
      }
    }
    let target = try connection.request(
      "Target.createTarget",
      .object(["url": .string("about:blank"), "browserContextId": .string(contextID)]))
    guard let targetId = target["targetId"]?.string,
      let url = URL(string: "ws://127.0.0.1:\(port)/devtools/page/\(targetId)")
    else {
      throw ToolError.message("Chromium did not create a page target")
    }
    let page = try Page(browser: self, targetId: targetId, url: url)
    try page.start(viewport: viewport, deviceScale: deviceScale)
    pages.append(page)
    contexts[targetId] = contextID
    started = true
    return page
  }

  func closePage(_ page: Page) throws {
    page.shutdown()
    if let context = contexts.removeValue(forKey: page.targetId) {
      try connection.request(
        "Target.disposeBrowserContext", .object(["browserContextId": .string(context)]))
    }
    pages.removeAll { $0 === page }
  }

  func close() {
    guard !closed else { return }
    closed = true
    for page in pages { page.shutdown() }
    pages.removeAll()
    contexts.removeAll()
    _ = try? connection.request("Browser.close", .object([:]), timeout: 5)
    connection.close()
    process.terminate(timeout: 5)
    try? Fs.remove(userData)
  }

  // MARK: - Downloads

  func setDownloadDirectory(_ directory: URL, for page: Page) throws {
    guard let context = contexts[page.targetId] else {
      throw ToolError.message("Page has no browser context")
    }
    try connection.request(
      "Browser.setDownloadBehavior",
      .object([
        "behavior": .string("allowAndName"),
        "downloadPath": .string(directory.path),
        "eventsEnabled": .bool(true),
        "browserContextId": .string(context),
      ]))
  }

  func completedDownloadGuids() -> Set<String> { completedDownloads.value }

  /// Collects browser-scoped download events before the next script runs.
  func pump() {
    for (method, params) in connection.drainEvents() {
      guard method == "Browser.downloadProgress", params["state"]?.string == "completed",
        let guid = params["guid"]?.string
      else { continue }
      _ = completedDownloads.mutate { $0.insert(guid) }
    }
  }
}

enum Chromium {
  /// Chromium publishes the browser endpoint once its debugging server starts.
  /// Read that endpoint directly, avoiding an extra HTTP readiness dependency.
  static func debuggingEndpoint(from output: String, port: Int) -> URL? {
    let prefix = "DevTools listening on "
    for line in output.components(separatedBy: .newlines).reversed() {
      let text = line.trimmingCharacters(in: .whitespaces)
      guard text.hasPrefix(prefix), let url = URL(string: String(text.dropFirst(prefix.count))),
        url.scheme == "ws", url.host == "127.0.0.1", url.port == port,
        url.path.hasPrefix("/devtools/browser/") else { continue }
      return url
    }
    return nil
  }

  /// Matches Playwright's launching defaults closely enough that rendering and
  /// input behave the same, then keeps the animation frame pump unthrottled.
  static func baseArguments(port: Int, userData: URL) -> [String] {
    var arguments = [
      "--headless=new",
      "--remote-debugging-port=\(port)",
      "--remote-debugging-address=127.0.0.1",
      "--user-data-dir=\(userData.path)",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-background-networking",
      "--disable-background-timer-throttling",
      "--disable-backgrounding-occluded-windows",
      "--disable-renderer-backgrounding",
      "--disable-ipc-flooding-protection",
      "--force-color-profile=srgb",
      "--hide-scrollbars",
      "--mute-audio",
    ]
    #if canImport(Glibc)
      // Distributions that disable unprivileged user namespaces (Ubuntu
      // 23.10+ AppArmor, most CI containers) leave Chromium's zygote
      // sandbox unusable, and it aborts at startup with "No usable
      // sandbox!". This browser only ever drives headless automation, so
      // the documented --no-sandbox workaround is the right default here.
      arguments.append("--no-sandbox")
    #endif
    return arguments
  }

  static func locate() throws -> URL {
    if let override = ProcessInfo.processInfo.environment["COVE_CHROMIUM"], !override.isEmpty {
      let url = URL(fileURLWithPath: override)
      guard FileManager.default.isExecutableFile(atPath: url.path) else {
        throw ToolError.message("COVE_CHROMIUM is not executable: \(override)")
      }
      return url
    }
    for path in candidates() where FileManager.default.isExecutableFile(atPath: path) {
      return URL(fileURLWithPath: path)
    }
    for name in ["chromium", "chromium-browser", "google-chrome", "chrome"] {
      if let url = Shell.executable(name) { return url }
    }
    throw ToolError.message(
      "Chromium not found; set COVE_CHROMIUM to a Chromium or Chrome executable")
  }

  static func candidates() -> [String] {
    var list = [
      "/Applications/Chromium.app/Contents/MacOS/Chromium",
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
      "/Applications/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
      "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    ]
    let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Caches/ms-playwright")
    if let entries = try? FileManager.default.contentsOfDirectory(atPath: cache.path) {
      for entry in entries.sorted() where entry.hasPrefix("chromium") {
        let root = cache.appendingPathComponent(entry).appendingPathComponent("chrome-mac")
        guard let bundles = try? FileManager.default.contentsOfDirectory(atPath: root.path) else {
          continue
        }
        for bundle in bundles.sorted() where bundle.hasSuffix(".app") {
          let macos = root.appendingPathComponent(bundle).appendingPathComponent("Contents/MacOS")
          guard let executables = try? FileManager.default.contentsOfDirectory(atPath: macos.path)
          else { continue }
          for executable in executables.sorted() {
            let url = macos.appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: url.path) { list.append(url.path) }
          }
        }
      }
    }
    return list
  }
}
