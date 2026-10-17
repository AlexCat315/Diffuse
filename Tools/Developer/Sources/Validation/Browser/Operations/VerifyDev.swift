internal import Foundation
private import ToolSupport

#if canImport(Glibc)
  private import Glibc
#endif

/// `verify-dev` — exercises real Swift rebuilds, state retention, and
/// failed-build recovery against the development server. Replaces
/// `GuavaUI/Browser/verify_dev.py`.
enum VerifyDevOperation {
  private static func firstCapture(in text: String, pattern: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern),
      let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }

  static func run(_ arguments: [String]) throws {
    var parser = FlagParser(arguments, valued: [])
    try parser.parse()
    if parser.flags.contains("--help") {
      Terminal.info(Browser.usage)
      return
    }
    if let unexpected = parser.positionals.first {
      throw ToolError.message("unrecognized arguments: \(unexpected)")
    }
    try verify()
  }

  static func verify() throws {
    let root = Repository.path("GuavaUI/Browser")
    let source = root.appendingPathComponent("Sources/GuavaUIBrowserPrototype/main.swift")
    let original = try Fs.read(source)
    defer { try? Fs.write(original, to: source) }

    let process = try SpawnedProcess(
      executable: try BrowserExecutable.current(),
      arguments: ["browser", "dev", "--port", "0"],
      directory: root, newSession: true)
    defer { process.terminate(timeout: 10) }

    let deadline = Date(timeIntervalSinceNow: 120)
    var address: String?
    while true {
      if let captured = firstCapture(
        in: process.output, pattern: "dev server: (http://127\\.0\\.0\\.1:\\d+)")
      {
        address = captured
        break
      }
      if process.poll() != nil || Date() > deadline {
        throw ToolError.message("Development server did not start:\n" + process.output)
      }
      usleep(200_000)
    }
    guard let address else { throw ToolError.message("Development server did not start") }

    let browser = try ChromiumBrowser.launch(executable: nil, arguments: ["--no-sandbox"])
    defer { browser.close() }
    let page = try browser.newPage()
    try page.goto(address + "/?renderer=canvas2d", waitUntil: .domContentLoaded)
    try page.waitForFunction("window.guavaDebug?.snapshot != null", timeout: 30)
    try page.locator("#increment").click()
    try page.waitForFunction("guavaDebug.snapshot.count === 1")
    let firstURL = page.url
    // Let EventSource connect before changing a watched source.
    try page.waitForFunction("window.guavaDevConnected === true")
    try Fs.write(original + Data("\n// development reload verification\n".utf8), to: source)
    try page.waitForURL({ $0 != firstURL }, timeout: 60)
    try page.waitForFunction("window.guavaDebug?.snapshot?.count === 1", timeout: 30)
    let secondURL = page.url
    try page.waitForFunction("window.guavaDevConnected === true")
    try Fs.write(original + Data("\nthis_is_not_valid_swift\n".utf8), to: source)
    try page.locator("pre").filter(text: .contains("error:")).waitFor(timeout: 60)
    try ensure(page.url == secondURL, "A failed build navigated away from the last good revision")
    try page.locator("#increment").click()
    try page.waitForFunction("guavaDebug.snapshot.count === 2")
    try Fs.write(original, to: source)
    try page.waitForURL({ $0 != secondURL }, timeout: 60)
    try page.waitForFunction("window.guavaDebug?.snapshot?.count === 2", timeout: 30)
    Terminal.info(
      "Development reload: real Swift rebuild, checkpoint retention, error overlay and recovery passed"
    )
  }
}
