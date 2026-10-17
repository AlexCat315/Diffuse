internal import Foundation
private import ToolSupport

/// Log protocol replay and Inspector controls against real native/Wasm hosts.
/// `target` is the Inspector frame for the Wasm prototype and the page itself
/// for the standalone native client.
func logPanelChecks(page: Page, target: any ScriptTarget) throws {
  try target.waitForFunction(
    "inspector.session.logs.logEntries.some(e => e.process?.runID && e.sequence > 0)")
  let records =
    try target.evaluate("inspector.session.logs.logEntries.filter(e => e.process)").array ?? []
  for record in records {
    try ensure(
      record["location"]?["file"]?.string?.isEmpty == false
        && record["process"]?["runID"]?.string?.isEmpty == false,
      "Log record is missing a file or run id: \(record.serialized)")
  }

  try target.locator("#pauseLog").click()
  let before = try target.locator("#log").innerText()
  _ = try target.evaluate(
    """
    () => {
        const record = {sequence:90000, timestamp:Date.now()/1000, level:'error', label:'com.guava.test.logs',
          message:'<script>literal text</script>', metadata:{nested:{value:'search-needle'}},
          location:{source:'acceptance',file:'LogCheck.swift',function:'check()',line:42},
          process:{pid:42,name:'acceptance',runID:'inspector-acceptance'}};
        inspector.logs.appendLog(record); inspector.logs.appendLog(record);
    }
    """)
  try ensure(
    try target.locator("#log").innerText() == before,
    "Paused log panel changed after appending records")
  try ensure(
    try target.evaluate(
      "inspector.session.logs.logEntries.filter(e => e.sequence === 90000).length"
    ).int == 1,
    "Duplicate records were not coalesced")

  try target.locator("#pauseLog").click()
  try target.locator("#logModule").fill("com.guava.test")
  try target.locator("#logLevel").selectOption("error")
  try target.locator("#logSearch").fill("search-needle")
  try target.locator("#log summary").filter(text: .contains("<script>literal text</script>"))
    .waitFor()
  try ensure(
    try target.locator("#log script").count() == 0, "Log markup was rendered as a script element")
  try target.locator("#log summary").click()
  try ensure(
    try target.locator("#log pre").innerText().contains("LogCheck.swift"),
    "Expanded log record is missing its location")

  let exported = try page.expectDownload { try target.locator("#exportLog").click() }
  let exportedLines = try Fs.text(exported)
    .split(separator: "\n", omittingEmptySubsequences: false)
    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    .map { try JSON.parse(String($0)) }
  try ensure(
    exportedLines.count == 1
      && exportedLines[0]["metadata"]?["nested"]?["value"]?.string == "search-needle",
    "Exported log stream does not match the appended record")

  try target.locator("#logSearch").fill("")
  try target.locator("#logModule").fill("")
  try target.locator("#logLevel").selectOption("info")
}
