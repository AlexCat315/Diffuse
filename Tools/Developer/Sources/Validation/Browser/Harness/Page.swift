internal import Foundation
private import ToolSupport

#if canImport(Glibc)
  private import Glibc
#endif

struct Viewport: Sendable {
  var width: Int
  var height: Int
}

/// The navigation states Playwright accepts for `page.goto`.
enum WaitUntil: Sendable {
  case domContentLoaded
  case load
  case networkIdle

  init(_ name: String) throws {
    switch name {
    case "domcontentloaded": self = .domContentLoaded
    case "load": self = .load
    case "networkidle": self = .networkIdle
    default: throw ToolError.message("Unknown wait_until state: \(name)")
    }
  }
}

/// One Chromium page target driven over the DevTools Protocol. It covers the
/// Playwright surface the verification scripts use: navigation, evaluation,
/// keyboard and mouse input, screenshots, and file downloads.
final class Page: ScriptTarget {
  let browser: ChromiumBrowser
  let targetId: String
  private let session: CDPConnection
  private(set) var errors: [String] = []

  private var contexts: [String: Int] = [:]
  private var inflight: Set<String> = []
  private var loadEvents = 0
  private var idleSince: Date?
  private var viewportSize = Viewport(width: 1280, height: 720)
  private var deviceScale: Double = 1

  lazy var mainFrame = Frame(page: self, iframeSelector: nil)

  init(browser: ChromiumBrowser, targetId: String, url: URL) throws {
    self.browser = browser
    self.targetId = targetId
    self.session = try CDPConnection(url: url)
  }

  func start(viewport: Viewport?, deviceScale scale: Double) throws {
    try session.request("Page.enable")
    try session.request("Runtime.enable")
    try session.request("Network.enable")
    try session.request("DOM.enable")
    if let viewport { try setViewport(viewport, scale: scale) }
    pump()
  }

  // MARK: - DevTools plumbing

  func command(_ method: String, _ params: JSON = .object([:])) throws -> JSON {
    try session.request(method, params)
  }

  func context(forFrameID id: String) -> Int? { contexts[id] }
  func hasContext(_ id: Int) -> Bool { contexts.values.contains(id) }

  /// Applies every buffered DevTools event, keeping the frame/network/error
  /// state current before the next script runs.
  func pump() {
    browser.pump()
    for (method, params) in session.drainEvents() { handle(method, params) }
  }

  private func handle(_ method: String, _ params: JSON) {
    switch method {
    case "Runtime.executionContextCreated":
      guard let context = params["context"], context["auxData"]?["isDefault"]?.bool == true,
        let identifier = context["id"]?.int, let frame = context["auxData"]?["frameId"]?.string
      else { return }
      contexts[frame] = identifier
    case "Runtime.executionContextDestroyed":
      guard let identifier = params["executionContextId"]?.int else { return }
      contexts = contexts.filter { $0.value != identifier }
    case "Runtime.executionContextsCleared":
      contexts.removeAll()
    case "Runtime.exceptionThrown":
      if let description = params["exceptionDetails"]?["exception"]?["description"]?.string {
        errors.append(description)
      } else if let text = params["exceptionDetails"]?["text"]?.string {
        errors.append(text)
      }
    case "Page.loadEventFired":
      loadEvents += 1
    case "Network.requestWillBeSent":
      if let identifier = params["requestId"]?.string { inflight.insert(identifier) }
    case "Network.loadingFinished", "Network.loadingFailed":
      if let identifier = params["requestId"]?.string { inflight.remove(identifier) }
    default:
      break
    }
  }

  // MARK: - Evaluation

  @discardableResult
  func rawEvaluate(_ expression: String, contextID: Int? = nil) throws -> JSON {
    pump()
    var params: [String: JSON] = [
      "expression": .string(expression),
      "awaitPromise": .bool(true),
      "returnByValue": .bool(true),
      "userGesture": .bool(true),
    ]
    if let contextID { params["contextId"] = .number(Double(contextID)) }
    let result = try session.request("Runtime.evaluate", .object(params))
    if let exception = result["exceptionDetails"], !exception.isNull {
      let description =
        exception["exception"]?["description"]?.string
        ?? exception["text"]?.string ?? "evaluate failed"
      throw ToolError.message("Page script error: \(description)")
    }
    return result["result"]?["value"] ?? .null
  }

  func evaluate(_ expression: String, argument: JSON) throws -> JSON {
    try rawEvaluate(Page.wrap(expression, argument))
  }

  /// Wraps an expression so a leading function receives `argument`, matching
  /// Playwright's `evaluate(expression, arg)`.
  static func wrap(_ expression: String, _ argument: JSON) -> String {
    "(() => { const __arg = \(argument.serialized); const __expr = (\(expression)); "
      + "return typeof __expr === \"function\" ? __expr(__arg) : __expr; })()"
  }

  func waitForFunction(_ expression: String, argument: JSON, timeout: Double = 30) throws {
    let wrapped = Page.wrap(expression, argument)
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
      if let value = try? rawEvaluate(wrapped), value.isTruthy { return }
      usleep(50_000)
    }
    throw ToolError.message("Timed out waiting for function: \(expression)")
  }

  func locator(_ selector: String) -> Locator { mainFrame.locator(selector) }

  func frameLocator(_ selector: String) -> Frame { Frame(page: self, iframeSelector: selector) }

  // MARK: - Navigation

  func goto(_ url: String, waitUntil: WaitUntil = .load, timeout: Double = 30) throws {
    loadEvents = 0
    idleSince = nil
    let result = try session.request("Page.navigate", .object(["url": .string(url)]))
    if let errorText = result["errorText"]?.string, !errorText.isEmpty {
      throw ToolError.message("Navigation to \(url) failed: \(errorText)")
    }
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
      pump()
      if navigationComplete(waitUntil) { return }
      usleep(50_000)
    }
    throw ToolError.message("Timed out waiting for \(url) to finish loading")
  }

  private func navigationComplete(_ waitUntil: WaitUntil) -> Bool {
    let state = (try? rawEvaluate("document.readyState").string) ?? ""
    switch waitUntil {
    case .domContentLoaded:
      return state == "interactive" || state == "complete"
    case .load:
      return loadEvents > 0 || state == "complete"
    case .networkIdle:
      guard loadEvents > 0 || state == "complete" else { return false }
      if inflight.isEmpty {
        if idleSince == nil { idleSince = Date() }
        return Date().timeIntervalSince(idleSince!) >= 0.5
      }
      idleSince = nil
      return false
    }
  }

  var url: String { (try? rawEvaluate("location.href").string) ?? "" }

  func waitForURL(_ predicate: @escaping (String) -> Bool, timeout: Double = 30) throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
      if predicate(url) { return }
      usleep(50_000)
    }
    throw ToolError.message("Timed out waiting for a matching URL")
  }

  func waitForTimeout(_ milliseconds: Double) { usleep(useconds_t(milliseconds * 1000)) }

  func setViewportSize(width: Int, height: Int) throws {
    try setViewport(Viewport(width: width, height: height), scale: deviceScale)
  }

  private func setViewport(_ viewport: Viewport, scale: Double) throws {
    viewportSize = viewport
    deviceScale = scale
    try session.request(
      "Emulation.setDeviceMetricsOverride",
      .object([
        "width": .number(Double(viewport.width)),
        "height": .number(Double(viewport.height)),
        "deviceScaleFactor": .number(scale),
        "mobile": .bool(false),
      ]))
  }

  // MARK: - Input

  func mouseClick(x: Double, y: Double) throws {
    try session.request(
      "Input.dispatchMouseEvent",
      .object([
        "type": .string("mouseMoved"), "x": .number(x), "y": .number(y),
        "button": .string("none"), "buttons": .number(0),
      ]))
    try session.request(
      "Input.dispatchMouseEvent",
      .object([
        "type": .string("mousePressed"), "x": .number(x), "y": .number(y),
        "button": .string("left"), "buttons": .number(1), "clickCount": .number(1),
      ]))
    try session.request(
      "Input.dispatchMouseEvent",
      .object([
        "type": .string("mouseReleased"), "x": .number(x), "y": .number(y),
        "button": .string("left"), "buttons": .number(0), "clickCount": .number(1),
      ]))
  }

  func keyboardPress(_ name: String) throws {
    guard let definition = KeyDefinition.named(name) else {
      throw ToolError.message("Unsupported key: \(name)")
    }
    try dispatchKey("keyDown", definition)
    try dispatchKey("keyUp", definition)
  }

  private func dispatchKey(_ type: String, _ definition: KeyDefinition) throws {
    var params: [String: JSON] = [
      "type": .string(type),
      "key": .string(definition.key),
      "code": .string(definition.code),
      "windowsVirtualKeyCode": .number(Double(definition.virtualKey)),
      "nativeVirtualKeyCode": .number(Double(definition.virtualKey)),
    ]
    if type == "keyDown", let text = definition.text { params["text"] = .string(text) }
    try session.request("Input.dispatchKeyEvent", .object(params))
  }

  func insertText(_ text: String) throws {
    try session.request("Input.insertText", .object(["text": .string(text)]))
  }

  // MARK: - Screenshots

  func captureScreenshot(fullPage: Bool) throws -> Data {
    var params: [String: JSON] = ["format": .string("png")]
    if fullPage { params["captureBeyondViewport"] = .bool(true) }
    let result = try session.request("Page.captureScreenshot", .object(params), timeout: 120)
    guard let encoded = result["data"]?.string, let data = Data(base64Encoded: encoded) else {
      throw ToolError.message("Chromium did not return a screenshot")
    }
    return data
  }

  func screenshot(to path: String, fullPage: Bool = false) throws {
    let data = try captureScreenshot(fullPage: fullPage)
    try Fs.write(data, to: absolutePath(path))
  }

  /// The presented canvas image, cropped to the element the way Playwright's
  /// `locator.screenshot()` returns the element's own pixels.
  func elementImage(_ selector: String) throws -> RGBAImage {
    let rect = try mainFrame.locator(selector).rect()
    let image = try RGBAImage(png: try captureScreenshot(fullPage: false))
    let factor = viewportSize.width > 0 ? Double(image.width) / Double(viewportSize.width) : 1
    return image.subimage(
      Int(floor(rect.x * factor)), Int(floor(rect.y * factor)),
      Int(ceil((rect.x + rect.w) * factor)), Int(ceil((rect.y + rect.h) * factor)))
  }

  // MARK: - Downloads

  func expectDownload(_ action: () throws -> Void) throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "guava-download-\(UUID().uuidString)")
    try Fs.directory(directory)
    try browser.setDownloadDirectory(directory, for: self)
    let before = browser.completedDownloadGuids()
    try action()
    let deadline = Date(timeIntervalSinceNow: 30)
    while Date() < deadline {
      browser.pump()
      if let guid = browser.completedDownloadGuids().subtracting(before).first {
        let file = directory.appendingPathComponent(guid)
        if FileManager.default.fileExists(atPath: file.path) { return file }
      }
      usleep(50_000)
    }
    throw ToolError.message("Timed out waiting for the download")
  }

  func close() throws {
    try browser.closePage(self)
  }

  func shutdown() { session.close() }
}

/// A physical key description used by `Input.dispatchKeyEvent`.
struct KeyDefinition {
  var key: String
  var code: String
  var virtualKey: Int
  var text: String?

  static func named(_ name: String) -> KeyDefinition? {
    switch name {
    case "Enter": return KeyDefinition(key: "Enter", code: "Enter", virtualKey: 13, text: "\r")
    case "Tab": return KeyDefinition(key: "Tab", code: "Tab", virtualKey: 9, text: nil)
    case "Space": return KeyDefinition(key: " ", code: "Space", virtualKey: 32, text: " ")
    case "Backspace":
      return KeyDefinition(key: "Backspace", code: "Backspace", virtualKey: 8, text: nil)
    case "Escape": return KeyDefinition(key: "Escape", code: "Escape", virtualKey: 27, text: nil)
    case "ArrowRight":
      return KeyDefinition(key: "ArrowRight", code: "ArrowRight", virtualKey: 39, text: nil)
    case "ArrowLeft":
      return KeyDefinition(key: "ArrowLeft", code: "ArrowLeft", virtualKey: 37, text: nil)
    case "ArrowDown":
      return KeyDefinition(key: "ArrowDown", code: "ArrowDown", virtualKey: 40, text: nil)
    case "ArrowUp": return KeyDefinition(key: "ArrowUp", code: "ArrowUp", virtualKey: 38, text: nil)
    default: return nil
    }
  }
}
