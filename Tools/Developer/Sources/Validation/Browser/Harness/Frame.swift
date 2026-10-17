internal import Foundation
private import ToolSupport

#if canImport(Glibc)
  private import Glibc
#endif

/// The main document or one same-origin iframe. Script evaluation runs in the
/// frame's own DevTools execution context, so globals such as `inspector` and
/// `document` resolve inside the Inspector exactly as Playwright's frames do.
final class Frame: ScriptTarget {
  let page: Page
  let iframeSelector: String?
  private var cachedFrameID: String?
  private var cachedContextID: Int?

  init(page: Page, iframeSelector: String?) {
    self.page = page
    self.iframeSelector = iframeSelector
  }

  var isMain: Bool { iframeSelector == nil }

  func locator(_ selector: String) -> Locator { Locator(frame: self, selector: selector) }

  func evaluate(_ expression: String, argument: JSON) throws -> JSON {
    try rawEvaluate(Page.wrap(expression, argument))
  }

  @discardableResult
  func rawEvaluate(_ expression: String) throws -> JSON {
    try page.rawEvaluate(expression, contextID: try contextID())
  }

  func waitForFunction(_ expression: String, argument: JSON, timeout: Double = 30) throws {
    let wrapped = Page.wrap(expression, argument)
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
      if let value = try? rawEvaluate(wrapped), value.isTruthy { return }
      usleep(50_000)
    }
    throw ToolError.message("Timed out waiting for function in frame: \(expression)")
  }

  /// Resolves (and caches) the execution context of the iframe, waiting for
  /// the frame to exist the way `element_handle().content_frame()` does.
  func contextID() throws -> Int? {
    guard let selector = iframeSelector else { return nil }
    if let context = cachedContextID, page.hasContext(context) { return context }
    let deadline = Date(timeIntervalSinceNow: 10)
    while Date() < deadline {
      page.pump()
      if let id = try? frameID(), let context = page.context(forFrameID: id) {
        cachedFrameID = id
        cachedContextID = context
        return context
      }
      usleep(50_000)
    }
    throw ToolError.message("The Inspector frame '\(selector)' is not available")
  }

  func frameID() throws -> String? {
    guard let selector = iframeSelector else { return nil }
    if let cached = cachedFrameID, page.context(forFrameID: cached) != nil { return cached }
    let document = try page.command("DOM.getDocument", .object(["depth": .number(1)]))
    guard let root = document["root"]?["nodeId"]?.int else { return nil }
    let query = try page.command(
      "DOM.querySelector",
      .object([
        "nodeId": .number(Double(root)), "selector": .string(selector),
      ]))
    guard let node = query["nodeId"]?.int, node != 0 else { return nil }
    let described = try page.command("DOM.describeNode", .object(["nodeId": .number(Double(node))]))
    return described["node"]?["frameId"]?.string
  }

  /// The iframe's content origin in the top page's viewport coordinates, so
  /// real mouse input can target elements inside it.
  func offset() throws -> (x: Double, y: Double) {
    guard let selector = iframeSelector else { return (0, 0) }
    let script = """
      (() => { const __f = document.querySelector(\(JSON.quote(selector)));
        if (!__f) throw new Error('Missing frame \(selector)');
        const __r = __f.getBoundingClientRect(); const __s = getComputedStyle(__f);
        return { x: __r.left + parseFloat(__s.borderLeftWidth || '0'), y: __r.top + parseFloat(__s.borderTopWidth || '0') }; })()
      """
    let value = try page.rawEvaluate(script, contextID: nil)
    return (value["x"]?.number ?? 0, value["y"]?.number ?? 0)
  }
}
