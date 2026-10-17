internal import Foundation
private import ToolSupport

/// Every exported trace entry must be a complete duration event with a thread.
func validateTimelineTrace(_ trace: JSON, expected: Int) throws {
  let events = trace["traceEvents"]?.array ?? []
  try ensure(
    events.count == expected, "Exported trace has \(events.count) events, expected \(expected)")
  for event in events {
    try ensure(
      event["ph"]?.string == "X" && event["tid"]?.isInteger == true,
      "Trace event is malformed: \(event.serialized)")
  }
}

/// Acceptance against the real Inspector and host protocol, without a GPU.
func nativeObservationChecks(page: Page, screenshot: String?) throws {
  try page.locator("#registeredStates").filter(text: .contains("count")).waitFor()
  try ensure(
    try page.evaluate("inspector.session.observation.registered.every(s => s.name === 'count')")
      .isTruthy,
    "Native registration includes an unexpected state")
  try ensure(
    try page.evaluate("inspector.session.observation.values.size").int == 0,
    "Watched values were not opt-in")
  // Repeated frame/tree notifications must not detach interactive watch fields.
  try ensure(
    try page.evaluate(
      """
      () => {
          const checkbox = document.querySelector('#registeredStates input');
          for (let i=0; i<50; i++) inspector.observation.renderStateRegistry();
          return checkbox === document.querySelector('#registeredStates input');
      }
      """
    ).isTruthy, "Rendering the registry replaced the watch fields")

  try page.locator("#registeredStates input[type=checkbox]").first.check()
  try page.waitForFunction("inspector.session.observation.values.size === 1")
  let initial = try page.evaluate("[...inspector.session.observation.values.values()][0].summary")
    .text
  try page.locator("#startTimeline").click()
  try page.waitForFunction("inspector.session.observation.recording")
  let changed = String((Int(initial) ?? 0) + 1)
  try page.locator("#stateSnapshot").fill(JSON.object(["count": .string(changed)]).serialized)
  try page.locator("#restoreState").click()
  try page.waitForFunction(
    "value => [...inspector.session.observation.values.values()][0]?.summary === value",
    argument: .string(changed))
  try page.waitForFunction(
    "['component','recomposition','layout','draw'].every(p => inspector.session.observation.events.some(e => e.phase === p))"
  )
  try ensure(
    try page.evaluate(
      "inspector.session.observation.events.every(e => Number.isFinite(e.durationMs) && e.durationMs >= 0 && e.startMs >= 0)"
    ).isTruthy,
    "Timeline spans are malformed")

  if let screenshot {
    try page.locator("#startTimeline").scrollIntoViewIfNeeded()
    try page.screenshot(to: screenshot)
  }

  try page.locator("#timelinePhase").selectOption("component")
  try ensure(
    try page.locator("#timelineEvents button").count() >= 1,
    "Timeline has no events for the selected phase")
  try page.locator("#timelineEvents button").first.click()
  try page.locator("#stateSelectedOnly").check()
  try ensure(
    try page.locator("#registeredStates input").count() == 1,
    "Scope filter did not narrow the registry")
  let uri = try page.locator("#addSourceBreakpoint").attribute("href") ?? ""
  try ensure(
    uri.hasPrefix("vscode://guava.guavaui-devtools/breakpoint?file=") && uri.contains("&line="),
    "Breakpoint URI is malformed: \(uri)")
  _ = try page.evaluate(
    "document.querySelector('#addSourceBreakpoint').addEventListener('click', e => { e.preventDefault(); window.breakpointClick=e.currentTarget.href; })"
  )
  try page.locator("#addSourceBreakpoint").click()
  try ensure(
    try page.evaluate("window.breakpointClick").string == uri,
    "Breakpoint click did not reach the URI")

  try page.locator("#stopTimeline").click()
  try page.waitForFunction(
    "!inspector.session.observation.recording && !inspector.session.observation.pending")
  let captured = try page.evaluate("inspector.session.observation.events.length").int ?? 0
  page.waitForTimeout(300)
  try ensure(
    try page.evaluate("inspector.session.observation.events.length").int == captured,
    "Events kept arriving after the timeline stopped")
  let exported = try page.expectDownload { try page.locator("#exportTimeline").click() }
  try validateTimelineTrace(try JSON.parse(try Fs.text(exported)), expected: captured)

  try page.locator("#stopWatching").click()
  try ensure(
    try page.evaluate(
      "inspector.session.observation.watched.size === 0 && inspector.session.observation.values.size === 0"
    ).isTruthy,
    "Stop watching left watched values behind")
  try page.locator("#disconnect").click()
  page.waitForTimeout(100)
  try ensure(
    try page.evaluate(
      "inspector.session.observation.events.length === 0 && inspector.session.observation.registered.length === 0"
    ).isTruthy,
    "Disconnect did not clear observation state")
  try page.locator("#connect").click()
  try page.locator("#registeredStates").filter(text: .contains("count")).waitFor()
  try ensure(
    try page.locator("#registeredStates input").first.isChecked() == false,
    "Watches were not reset after reconnect")
  try ensure(
    try page.locator("#startTimeline").isEnabled(), "Timeline did not re-enable after reconnect")
  Terminal.info(
    "Observation: opt-in values, live State writes, scope filter, CPU timeline, stop/export, breakpoint URI and disconnect cleanup passed"
  )
}

/// Wasm Inspector observation over the shared browser transport.
func wasmObservationChecks(page: Page, inspector: Frame) throws {
  let baseline = try page.evaluate(
    "({count:guavaDebug.snapshot.count, dark:guavaDebug.snapshot.dark, note:guavaDebug.snapshot.note})"
  )
  try inspector.locator("#registeredStates").filter(text: .contains("count")).waitFor()
  try ensure(
    try inspector.evaluate(
      "inspector.session.observation.registered.map(s=>s.name).sort().join(',')"
    ).string == "count,dark",
    "Wasm registration is not count,dark")
  try ensure(
    try inspector.evaluate("inspector.session.observation.values.size").int == 0,
    "Watched values were not opt-in")

  try inspector.locator("#registeredStates label").filter(text: .contains("count")).locator("input")
    .check()
  try inspector.waitForFunction("inspector.session.observation.values.size === 1")
  try inspector.locator("#startTimeline").click()
  try inspector.waitForFunction(
    "inspector.session.observation.recording && !inspector.session.observation.pending")
  try page.locator("#increment").click()
  try inspector.waitForFunction(
    "n => [...inspector.session.observation.values.values()][0]?.summary === String(n)",
    argument: .number(Double((baseline["count"]?.int ?? 0) + 1)))

  let card = try page.evaluate("inspectedNode('counter.card').id")
  _ = try inspector.evaluate(
    "id=>inspector.tree.selectNode(inspector.tree.findNode(inspector.session.tree.tree,id))",
    argument: card)
  try inspector.locator("#paddingLeft").fill("32")
  try inspector.waitForFunction(
    "['component','recomposition','layout','draw'].every(p=>inspector.session.observation.events.some(e=>e.phase===p))"
  )
  try ensure(
    try inspector.evaluate(
      "inspector.session.observation.events.every(e=>Number.isFinite(e.startMs)&&Number.isFinite(e.durationMs)&&e.startMs>=0&&e.durationMs>=0)"
    ).isTruthy,
    "Timeline spans are malformed")

  try inspector.locator("#timelinePhase").selectOption("component")
  try inspector.locator("#timelineEvents button").first.click()
  try inspector.locator("#stateSelectedOnly").check()
  try ensure(
    try inspector.locator("#registeredStates input").count() == 2,
    "Scope filter discarded a registered state")
  try ensure(
    try inspector.locator("#addSourceBreakpoint").attribute("href")?.hasPrefix(
      "vscode://guava.guavaui-devtools/breakpoint?") == true,
    "Breakpoint URI is malformed")
  try inspector.locator("#stopTimeline").click()
  try inspector.waitForFunction(
    "!inspector.session.observation.recording && !inspector.session.observation.pending")
  let captured = try inspector.evaluate("inspector.session.observation.events.length").int ?? 0
  try page.locator("#increment").click()
  try inspector.waitForFunction(
    "n => [...inspector.session.observation.values.values()][0]?.summary === String(n)",
    argument: .number(Double((baseline["count"]?.int ?? 0) + 2)))
  try ensure(
    try inspector.evaluate("inspector.session.observation.events.length").int == captured,
    "Events kept arriving after the timeline stopped")
  let exported = try page.expectDownload { try inspector.locator("#exportTimeline").click() }
  try validateTimelineTrace(try JSON.parse(try Fs.text(exported)), expected: captured)

  try inspector.locator("#disconnect").click()
  try inspector.waitForFunction(
    "inspector.session.observation.events.length===0 && inspector.session.observation.registered.length===0"
  )
  try inspector.locator("#connect").click()
  try inspector.waitForFunction("inspector.session.observation.registered.length===2")
  try ensure(
    try inspector.locator("#registeredStates input").first.isChecked() == false,
    "Watches were not reset after reconnect")
  try ensure(
    try inspector.locator("#startTimeline").isEnabled(),
    "Timeline did not re-enable after reconnect")
  _ = try page.evaluate(
    "s=>guavaDebug.request({type:'state.restore',id:994,payload:{count:String(s.count),dark:String(s.dark),note:s.note}})",
    argument: baseline)
  try page.waitForFunction(
    "s=>guavaDebug.snapshot.count===s.count && guavaDebug.snapshot.note===s.note",
    argument: baseline)
  Terminal.info(
    "Wasm observation: explicit/private State, real updates, all CPU stages, component navigation, trace export, stop and reconnect cleanup passed"
  )
}
