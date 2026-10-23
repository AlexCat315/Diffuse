internal import Foundation
private import ToolSupport

/// Real Wasm and socket acceptance for source links and body profiling.
func analysisChecks(page: Page, inspector: Frame) throws {
  let initialCount = try page.evaluate("guavaDebug.snapshot.count").int ?? 0
  let compact = try inspector.evaluate(
    "inspector.tree.compactTag('GuavaUI.Row<GuavaUI._SourceLocatedView<Demo.Button>>')"
  ).string
  try ensure(compact == "Row", "compactTag returned \(compact ?? "null")")

  try inspector.locator("#tree button").filter(text: .contains("counter.value")).first.click()
  try inspector.locator("#sourceLocation").filter(text: .contains("CounterView.swift:")).waitFor()

  let source = try inspector.evaluate(
    "inspector.tree.findNode(inspector.session.tree.tree, inspector.session.tree.selectedId).source"
  )
  guard let line = source["line"]?.int, let column = source["column"]?.int, line > 0, column > 0
  else {
    throw ToolError.message("Source location is missing: \(source.serialized)")
  }
  let filePath = source["filePath"]?.string ?? ""
  let file = Repository.path("GuavaUI/Examples/Counter/Sources/CounterExample/CounterView.swift")
  let lines = try Fs.text(file).split(separator: "\n", omittingEmptySubsequences: false).map(
    String.init)
  try ensure(
    lines.indices.contains(line - 1) && lines[line - 1].contains("debugName(\"counter.value\")"),
    "Swift expression line does not match: \(source.serialized)")

  let expected = try inspector.evaluate(
    "inspector.analysis.editorSourceURL(inspector.tree.findNode(inspector.session.tree.tree, inspector.session.tree.selectedId).source, 'vscode')"
  ).text
  try ensure(
    try inspector.locator("#openSource").attribute("href") == expected,
    "openSource href does not match the analysis URI")
  try ensure(
    expected.hasSuffix(":\(line):\(column)"),
    "URI does not end with the source line and column: \(expected)")

  _ = try inspector.evaluate(
    "document.querySelector('#openSource').addEventListener('click', e => { e.preventDefault(); window.clickedSource=e.currentTarget.href; })"
  )
  try inspector.locator("#openSource").click()
  try ensure(
    try inspector.evaluate("window.clickedSource").string == expected,
    "Clicked source URI does not match")
  try inspector.locator("#sourceEditor").selectOption("cursor")
  try ensure(
    try inspector.locator("#openSource").attribute("href")?.hasPrefix("cursor://file/") == true,
    "Cursor URI scheme is missing")

  _ = try inspector.locator("details").filter(has: inspector.locator("#sourceBuildRoot")).evaluate(
    "e => e.open = true")
  let buildRoot = filePath.components(separatedBy: "/GuavaUI/Examples/Counter/").first ?? ""
  try inspector.locator("#sourceBuildRoot").fill(buildRoot)
  try inspector.locator("#sourceLocalRoot").fill("C:\\我的项目\\Guava UI")
  let uri = try inspector.locator("#openSource").attribute("href") ?? ""
  try ensure(
    uri.hasPrefix(
      "cursor://file/C:/%E6%88%91%E7%9A%84%E9%A1%B9%E7%9B%AE/Guava%20UI/GuavaUI/Examples/Counter/"),
    "Windows remote path mapping failed: \(uri)")

  try ensure(
    try inspector.evaluate(
      "inspector.analysis.editorSourceURL({filePath:'/build/name #.swift',line:2,column:3},'vscode','/build','/Users/me')"
    ).string
      == "vscode://file/Users/me/name%20%23.swift:2:3", "Escaped URI mapping failed")
  try ensure(
    try inspector.evaluate(
      "inspector.analysis.editorSourceURL({filePath:'/build/name.swift',line:2,column:3},'vscode','/','C:/')"
    ).string
      == "vscode://file/C:/build/name.swift:2:3", "Windows local root mapping failed")
  try ensure(
    try inspector.evaluate(
      "inspector.analysis.editorSourceURL({filePath:'C:/build/name.swift',line:2,column:3},'vscode','C:/','/local')"
    ).string
      == "vscode://file/local/build/name.swift:2:3", "Windows build root mapping failed")

  for path in [
    "file:///tmp/a.swift", "javascript:alert(1)", "relative.swift", "/tmp/../a.swift",
    "/tmp/a\n.swift",
  ] {
    let value = try inspector.evaluate(
      "p => inspector.analysis.editorSourceURL({filePath:p,line:1,column:1},'vscode')",
      argument: .string(path))
    try ensure(value.isNull, "Unsafe source path was accepted: \(path) -> \(value.serialized)")
  }
  try ensure(
    try inspector.evaluate(
      "inspector.analysis.editorSourceURL({filePath:'/tmp/a.swift',line:0,column:1},'vscode')"
    ).isNull,
    "Zero line was accepted")
  try ensure(
    try inspector.evaluate(
      "inspector.analysis.editorSourceURL({filePath:'/tmp/a.swift',line:1,column:1},'custom')"
    ).isNull,
    "Unknown editor was accepted")
  try ensure(
    try inspector.evaluate(
      "inspector.analysis.editorSourceURL({filePath:'/build2/a.swift',line:1,column:1},'vscode','/build','/local')"
    ).isNull,
    "Non-prefix build root was accepted")

  try inspector.locator("#sourceBuildRoot").fill("")
  try inspector.locator("#sourceLocalRoot").fill("")
  try inspector.locator("#sourceEditor").selectOption("vscode")
  _ = try inspector.locator("details").filter(has: inspector.locator("#sourceBuildRoot")).evaluate(
    "e => e.open = false")

  // Counts are read from the actual owning user scope, never the DOM/paint loop.
  let before =
    try inspector.evaluate(
      "inspector.tree.findNode(inspector.session.tree.tree, inspector.tree.findNode(inspector.session.tree.tree, inspector.session.tree.selectedId).ownerScopeID).recomposition.count"
    ).int ?? 0
  try page.locator("#increment").click()
  try inspector.waitForFunction(
    "n => { const node=inspector.tree.findNode(inspector.session.tree.tree,inspector.session.tree.selectedId); return inspector.tree.findNode(inspector.session.tree.tree,node.ownerScopeID).recomposition.count > n; }",
    argument: .number(Double(before)))
  try inspector.locator("#recompositionReasons").filter(text: .contains("state: count")).waitFor()
  let metrics = try inspector.evaluate(
    "inspector.tree.findNode(inspector.session.tree.tree, inspector.tree.findNode(inspector.session.tree.tree, inspector.session.tree.selectedId).ownerScopeID).recomposition"
  )
  guard let count = metrics["count"]?.int, let lastMs = metrics["lastMs"]?.number,
    let maxMs = metrics["maxMs"]?.number
  else {
    throw ToolError.message("Recomposition metrics are incomplete: \(metrics.serialized)")
  }
  try ensure(
    count == before + 1 && lastMs >= 0 && maxMs >= lastMs,
    "Recomposition metrics are inconsistent: \(metrics.serialized)")
  try ensure(
    metrics["reasons"]
      == .array([.object(["kind": .string("state"), "detail": .string("count")])]),
    "Recomposition causes are wrong: \(metrics["reasons"]?.serialized ?? "null")")

  _ = try inspector.locator("details").filter(has: inspector.locator("#recompositionTable"))
    .evaluate("e => e.open = true")
  try ensure(
    try inspector.locator("#recompositionTable button").count() >= 1,
    "Recomposition table has no rows")
  try inspector.locator("#recompositionSort").selectOption("count")
  try inspector.locator("#resetRecomposition").click()
  try inspector.waitForFunction(
    "inspector.tree.findNode(inspector.session.tree.tree,inspector.tree.findNode(inspector.session.tree.tree,inspector.session.tree.selectedId).ownerScopeID).recomposition.count === 0"
  )
  try inspector.locator("#recompositionStats").filter(text: .contains("Recompositions: 0"))
    .waitFor()
  try ensure(
    try inspector.evaluate(
      "inspector.tree.findNode(inspector.session.tree.tree,inspector.tree.findNode(inspector.session.tree.tree,inspector.session.tree.selectedId).ownerScopeID).recomposition.reasons.length"
    ).int == 0,
    "Reset did not clear the causes")

  _ = try page.evaluate(
    "count => guavaDebug.request({type:'state.restore',id:992,payload:{count:String(count),dark:String(guavaDebug.snapshot.dark)}})",
    argument: .number(Double(initialCount)))
  try page.waitForFunction(
    "count => guavaDebug.snapshot.count === count", argument: .number(Double(initialCount)))
  Terminal.info(
    "Analysis: exact Swift expression line, VS Code/Cursor URI, remote/Windows path mapping, real State count/cause, timing and reset passed"
  )
}

/// Native socket acceptance for the real Compose source link and profile.
func nativeAnalysisChecks(page: Page) throws {
  try page.locator("#recompositionCount").filter(text: .contains("1")).waitFor()
  _ = try page.locator("details").filter(has: page.locator("#recompositionTable")).evaluate(
    "e => e.open = true")
  try page.locator("#recompositionTable button").first.click()
  try page.locator("#sourceLocation").filter(text: .contains("main.swift:")).waitFor()
  try page.locator("#recompositionStats").filter(text: .contains("Recompositions: 1")).waitFor()
  try page.locator("#recompositionReasons").filter(text: .contains("state: count")).waitFor()
  try ensure(
    try page.locator("#openSource").attribute("href")?.hasPrefix("vscode://file/") == true,
    "Native source link is not a VS Code URI")
  try page.locator("#resetRecomposition").click()
  try page.locator("#recompositionStats").filter(text: .contains("Recompositions: 0")).waitFor()
  Terminal.info("Native WebSocket: real Compose source/profile, State cause and reset passed")
}
