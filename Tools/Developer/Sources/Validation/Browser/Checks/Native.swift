internal import Foundation
private import ToolSupport

/// Verification of the real native WebSocket Inspector without a Wasm SDK or
/// GPU. The probe is started by the caller; this drives the browser client.
func nativeChecks(
  _ browser: ChromiumBrowser, baseURL: String, nativePort: Int,
  clientPath: String = "devtools/index.html", screenshot: String? = nil
) throws {
  let page = try browser.newPage()
  try page.goto(baseURL + clientPath)
  try page.locator("#endpoint").fill("ws://127.0.0.1:\(nativePort)/")
  try page.locator("#connect").click()
  try page.locator("#tree").filter(text: .contains("headless.root")).waitFor()
  try logPanelChecks(page: page, target: page)
  try page.locator("#captureState").click()
  try page.waitForFunction("document.querySelector('#stateSnapshot').value.includes('count')")
  try page.locator("#stateSnapshot").fill("{\"count\":\"12\"}")
  try page.locator("#restoreState").click()
  try page.locator("#captureState").click()
  try page.waitForFunction("document.querySelector('#stateSnapshot').value.includes('12')")
  try nativeAnalysisChecks(page: page)
  try nativeInspectionChecks(page: page)
  do {
    try nativeObservationChecks(page: page, screenshot: screenshot)
  } catch {
    if let info = try? page.evaluate(
      "({capabilities:[...inspector.session.connection.capabilities], registered:inspector.session.observation.registered, log:inspector.session.logs.logEntries})"
    ) {
      Terminal.info(info.prettyText)
    }
    _ = try? page.screenshot(to: "/tmp/guava-devtools-failure.png", fullPage: true)
    throw error
  }
  try page.locator("#disconnect").click()
  try page.locator("#connect").click()
  try page.locator("#status").filter(text: .contains("Connected")).waitFor()
  Terminal.info(
    "Native WebSocket: hello, tree, state restore, picking, editable styles, undo/redo, disconnect cleanup and reconnect passed"
  )
  try page.close()
}
