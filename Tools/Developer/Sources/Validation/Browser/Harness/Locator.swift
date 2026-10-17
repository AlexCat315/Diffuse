internal import Foundation
private import ToolSupport

#if canImport(Glibc)
  private import Glibc
#endif

/// Text matching for Playwright's `has_text`: a substring (case-insensitive) or
/// a regular expression tested against the element's text content.
enum TextMatch: Sendable {
  case contains(String)
  case regex(String)
}

enum WaitState: Sendable {
  case attached
  case detached
  case visible
  case hidden
}

/// A Playwright-shaped element finder: a CSS selector plus optional text/has
/// filters, an index, and an optional parent for `locator.locator(child)`
/// chaining. Every accessor resolves eagerly inside the owning frame.
final class Locator {
  let frame: Frame
  let selector: String
  let text: TextMatch?
  let hasSelector: String?
  let index: Int?
  let parent: Locator?

  init(
    frame: Frame, selector: String, text: TextMatch? = nil, hasSelector: String? = nil,
    index: Int? = nil, parent: Locator? = nil
  ) {
    self.frame = frame
    self.selector = selector
    self.text = text
    self.hasSelector = hasSelector
    self.index = index
    self.parent = parent
  }

  var first: Locator {
    Locator(
      frame: frame, selector: selector, text: text, hasSelector: hasSelector, index: 0,
      parent: parent)
  }

  func filter(text match: TextMatch) -> Locator {
    Locator(
      frame: frame, selector: selector, text: match, hasSelector: hasSelector, index: index,
      parent: parent)
  }

  func filter(has locator: Locator) -> Locator {
    Locator(
      frame: frame, selector: selector, text: text, hasSelector: locator.selector, index: index,
      parent: parent)
  }

  /// Playwright's `locator.locator(child)`: a descendant of this element.
  func locator(_ child: String) -> Locator {
    Locator(frame: frame, selector: child, parent: self)
  }

  // MARK: - Expressions

  private var pickCondition: String {
    var conditions: [String] = []
    if let text {
      switch text {
      case .contains(let value):
        conditions.append(
          "(__el.textContent || '').toLowerCase().includes(\(JSON.quote(value.lowercased())))")
      case .regex(let pattern):
        conditions.append("new RegExp(\(JSON.quote(pattern))).test(__el.textContent || '')")
      }
    }
    if let hasSelector {
      conditions.append("!!__el.querySelector(\(JSON.quote(hasSelector)))")
    }
    return conditions.isEmpty ? "true" : conditions.joined(separator: " && ")
  }

  private var nodesExpression: String {
    if let parent {
      return
        "(\(parent.filteredNodesExpression)).flatMap((__p) => Array.from(__p.querySelectorAll(\(JSON.quote(selector)))))"
    }
    return "Array.from(document.querySelectorAll(\(JSON.quote(selector))))"
  }

  private var filteredNodesExpression: String {
    "(() => { const __nodes = \(nodesExpression); return __nodes.filter((__el) => (\(pickCondition))); })()"
  }

  private var elementExpression: String {
    "(() => { const __nodes = \(filteredNodesExpression); return __nodes[\(index ?? 0)] ?? null; })()"
  }

  private var countExpression: String { "(\(filteredNodesExpression)).length" }

  private var visibilityExpression: String {
    "(() => { const __el = \(elementExpression); if (!__el) return false; "
      + "const __s = getComputedStyle(__el); "
      + "if (__s.visibility === 'hidden' || __s.visibility === 'collapse') return false; "
      + "const __r = __el.getBoundingClientRect(); return __r.width > 0 && __r.height > 0; })()"
  }

  private var missing: String { "No element for \(selector)" }

  // MARK: - Queries

  func count() throws -> Int { try frame.rawEvaluate(countExpression).int ?? 0 }

  func exists() throws -> Bool {
    try frame.rawEvaluate("(() => { const __el = \(elementExpression); return __el != null; })()")
      .isTruthy
  }

  func isVisible() throws -> Bool { try frame.rawEvaluate(visibilityExpression).isTruthy }

  func isChecked() throws -> Bool {
    try frame.rawEvaluate(
      "(() => { const __el = \(elementExpression); return __el ? !!__el.checked : false; })()"
    ).isTruthy
  }

  func isEnabled() throws -> Bool {
    try frame.rawEvaluate(
      "(() => { const __el = \(elementExpression); return __el ? !__el.disabled : false; })()"
    ).isTruthy
  }

  func inputValue() throws -> String {
    try frame.rawEvaluate(
      "(() => { const __el = \(elementExpression); return __el ? __el.value : null; })()"
    ).string ?? ""
  }

  func innerText() throws -> String {
    try frame.rawEvaluate(
      "(() => { const __el = \(elementExpression); return __el ? __el.innerText : null; })()"
    ).string ?? ""
  }

  func textContent() throws -> String {
    try frame.rawEvaluate(
      "(() => { const __el = \(elementExpression); return __el ? (__el.textContent || '') : null; })()"
    ).string ?? ""
  }

  func attribute(_ name: String) throws -> String? {
    let value = try frame.rawEvaluate(
      "(() => { const __el = \(elementExpression); return __el ? __el.getAttribute(\(JSON.quote(name))) : null; })()"
    )
    return value.string
  }

  // MARK: - Actions

  func waitFor(state: WaitState = .visible, timeout: Double = 30) throws {
    let deadline = Date(timeIntervalSinceNow: timeout)
    while Date() < deadline {
      let matched: Bool
      switch state {
      case .visible: matched = (try? isVisible()) ?? false
      case .hidden: matched = !((try? isVisible()) ?? false)
      case .attached: matched = (try? exists()) ?? false
      case .detached: matched = !((try? exists()) ?? false)
      }
      if matched { return }
      usleep(50_000)
    }
    throw ToolError.message("Timed out waiting for locator '\(selector)' to be \(state)")
  }

  func rect(scrolling: Bool = true) throws -> (x: Double, y: Double, w: Double, h: Double) {
    let scroll = scrolling ? "__el.scrollIntoView({block:'center', inline:'center'});" : ""
    let script = """
      (() => { const __el = \(elementExpression);
        if (!__el) throw new Error('\(missing)');
        \(scroll)
        const __r = __el.getBoundingClientRect();
        return { x: __r.left, y: __r.top, w: __r.width, h: __r.height }; })()
      """
    let value = try frame.rawEvaluate(script)
    let origin = try frame.offset()
    return (
      origin.x + (value["x"]?.number ?? 0), origin.y + (value["y"]?.number ?? 0),
      value["w"]?.number ?? 0, value["h"]?.number ?? 0
    )
  }

  func boundingBox() throws -> JSON {
    let box = try rect(scrolling: false)
    return .object([
      "x": .number(box.x), "y": .number(box.y), "width": .number(box.w), "height": .number(box.h),
    ])
  }

  func click(position: JSON? = nil) throws {
    try waitFor()
    let box = try rect()
    let x = box.x + (position?["x"]?.number ?? box.w / 2)
    let y = box.y + (position?["y"]?.number ?? box.h / 2)
    try frame.page.mouseClick(x: x, y: y)
  }

  func focus() throws {
    try waitFor(state: .attached)
    _ = try frame.rawEvaluate(
      "(() => { const __el = \(elementExpression); if (!__el) throw new Error('\(missing)'); __el.focus(); })()"
    )
  }

  func fill(_ value: String) throws {
    try waitFor()
    _ = try frame.rawEvaluate(
      "(() => { const __el = \(elementExpression); if (!__el) throw new Error('\(missing)'); "
        + "__el.focus(); __el.value = \(JSON.quote(value)); __el.dispatchEvent(new Event('input', {bubbles:true})); })()"
    )
  }

  func check() throws {
    if try isChecked() { return }
    try click()
  }

  func selectOption(_ value: String) throws {
    try waitFor()
    _ = try frame.rawEvaluate(
      "(() => { const __el = \(elementExpression); if (!__el) throw new Error('\(missing)'); "
        + "__el.value = \(JSON.quote(value)); __el.dispatchEvent(new Event('input', {bubbles:true})); "
        + "__el.dispatchEvent(new Event('change', {bubbles:true})); })()")
  }

  func scrollIntoViewIfNeeded() throws {
    _ = try frame.rawEvaluate(
      "(() => { const __el = \(elementExpression); if (__el) __el.scrollIntoView({block:'center', inline:'center'}); })()"
    )
  }

  /// `locator.evaluate(js)` invokes the expression with the element handle.
  func evaluate(_ expression: String) throws -> JSON {
    try frame.rawEvaluate(
      "(() => { const __el = \(elementExpression); if (!__el) throw new Error('\(missing)'); "
        + "const __expr = (\(expression)); return typeof __expr === 'function' ? __expr(__el) : __expr; })()"
    )
  }

  func elementHandle() -> ElementHandle { ElementHandle(locator: self) }
}

/// The thin handle Playwright exposes for `locator.element_handle()`, used here
/// only to reach an iframe's frame.
struct ElementHandle {
  let locator: Locator

  func contentFrame() -> Frame {
    Frame(page: locator.frame.page, iframeSelector: locator.selector)
  }
}
