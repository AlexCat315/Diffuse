internal import Foundation
private import ToolSupport

/// Real browser verification for the Wasm prototype: pixels, font atlas and
/// fallback, ligatures, complex scripts, Compose/Yoga, Unicode/IME, DevTools and
/// resize, driven over the DevTools Protocol.
func previewChecks(
  _ browser: ChromiumBrowser, baseURL: String, renderer: String,
  screenshot: String?, scale: Double = 1
) throws {
  let page = try browser.newPage(viewport: Viewport(width: 1280, height: 1100), deviceScale: scale)
  let query = renderer.isEmpty ? "" : "?renderer=\(renderer)"
  try page.goto(baseURL + query, waitUntil: .networkIdle)
  try page.waitForFunction("window.coveDebug?.snapshot != null", timeout: 30000)
  if renderer == "webgpu" {
    try ensure(
      try page.evaluate("coveDebug.backend").string == "webgpu", "Expected the WebGPU backend")
  }

  // A working API alone does not prove that any geometry was drawn.
  try waitPixels(page, .rect([60, 260, 1, 1])) { pixels in
    pixels.contains { $0.a > 200 && Double($0.b) > Double($0.r) + 50 }
  }
  try ensure(
    try page.evaluate("coveDebug.snapshot.fontCount").int == 5, "Font atlas is incomplete")
  // Check ink inside the title. This catches lost initial atlas uploads and
  // prevents the old Canvas system-font overlay from satisfying the test.
  try ensure(
    try page.locator("#labels").count() == 0, "Legacy Canvas labels element is still present")
  try waitPixels(page, .rect([24, 24, 400, 36])) { pixels in
    pixels.filter { $0.r < 80 && $0.g < 100 && $0.b < 140 && $0.a > 200 }.count > 100
  }

  try page.locator("#surface").click(position: .object(["x": .number(60), "y": .number(260)]))
  try page.waitForFunction("coveDebug.snapshot.count === 1")
  try page.locator("#increment").click()
  try page.waitForFunction("coveDebug.snapshot.count === 2")
  let rejected = try page.evaluate(
    "coveDebug.request({type:'state.restore',id:90,payload:{count:-1,dark:'true'}})")
  try ensure(
    rejected["type"]?.string == "state.restore.err" && rejected["id"]?.int == 90,
    "Invalid restore was not rejected: \(rejected.serialized)")
  try ensure(
    try page.evaluate("coveDebug.snapshot.count").int == 2, "Rejected restore changed the count")

  let nodeID = try page.evaluate(
    """
    () => {
        function find(n) { if(n.debugName==='counter.increment') return n; for(const c of n.children) {const r=find(c); if(r) return r;} }
        return find(coveDebug.snapshot.tree.root).id;
    }
    """)
  let selected = try page.evaluate(
    "id => coveDebug.request({type:'select.node',id:91,payload:{id}})", argument: nodeID)
  try ensure(
    selected["type"]?.string == "select.node.ok", "select.node failed: \(selected.serialized)")
  try page.waitForFunction(
    "id => { function find(n) { if(n.id===id) return n.elementID===coveDebug.snapshot.tree.inspection.selectedID && !n.flags.hasBorder; return n.children.some(find); } return find(coveDebug.snapshot.tree.root); }",
    argument: nodeID)

  try page.locator("#surface").focus()
  try page.keyboardPress("Enter")
  try page.waitForFunction("coveDebug.snapshot.count === 3")
  try page.keyboardPress("Tab")
  try page.keyboardPress("Space")
  try page.waitForFunction("coveDebug.snapshot.count === 0")
  try page.locator("#increment").click()
  try page.locator("#increment").click()
  try page.waitForFunction("coveDebug.snapshot.count === 2")
  try ensure(
    (try page.evaluate("coveDebug.snapshot.tree.inputInventory.nodeCount").int ?? 0) > 5,
    "Input inventory is incomplete")
  try ensure(
    try page.evaluate(
      "coveDebug.snapshot.tree.invalidations.some(i => i.source.startsWith('stateWrite'))"
    ).isTruthy,
    "No stateWrite invalidation was recorded")

  try page.locator("#theme").click()
  try page.waitForFunction("coveDebug.snapshot.dark === true")

  let inspector = page.frameLocator("#inspector")
  try inspector.locator("#status").filter(text: .regex("^Connected$")).waitFor()
  try inspector.locator("#tree").filter(text: .contains("counter.root")).waitFor()
  let frame = page.locator("#inspector").elementHandle().contentFrame()
  try logPanelChecks(page: page, target: frame)

  try inspector.locator("#captureState").click()
  try page.waitForFunction(
    "document.querySelector('#inspector').contentDocument.querySelector('#stateSnapshot').value.includes('true')"
  )
  let captured = try JSON.parse(try inspector.locator("#stateSnapshot").inputValue())
  try ensure(
    captured == .object(["count": "2", "dark": "true", "note": ""]),
    "Captured state is wrong: \(captured.serialized)")
  try page.locator("#reset").click()
  try page.waitForFunction("coveDebug.snapshot.count === 0")
  try inspector.locator("#diffState").click()
  try inspector.locator("#stateDiff").filter(text: .contains("\"after\": \"0\"")).waitFor()
  try inspector.locator("#restoreState").click()
  try page.waitForFunction("coveDebug.snapshot.count === 2")
  try inspector.locator("#recordInput").click()
  try inspector.locator("#stopRecording").waitFor(state: .visible)
  try page.waitForFunction(
    "!document.querySelector('#inspector').contentDocument.querySelector('#stopRecording').disabled"
  )
  try page.locator("#increment").click()
  try page.waitForFunction("coveDebug.snapshot.count === 3")
  try inspector.locator("#stopRecording").click()
  try page.waitForFunction(
    "document.querySelector('#inspector').contentDocument.querySelector('#inputRecording').value.includes('mouseButtonUp')"
  )
  let recording = try JSON.parse(try inspector.locator("#inputRecording").inputValue())
  try ensure(
    recording["initialState"] == .object(["count": "2", "dark": "true", "note": ""]),
    "Recorded initial state is wrong: \(recording.serialized)")
  try page.locator("#reset").click()
  try page.waitForFunction("coveDebug.snapshot.count === 0")
  try inspector.locator("#replayInput").click()
  try page.waitForFunction("coveDebug.snapshot.count === 3")
  var malformed = recording
  if var object = malformed.object {
    object["version"] = .number(99)
    malformed = .object(object)
  }
  let replay = try page.evaluate(
    "r => coveDebug.request({type:'input.replay', id:92, payload:r}).type", argument: malformed)
  try ensure(
    replay.string == "input.replay.err", "Malformed replay was accepted: \(replay.serialized)")
  try ensure(
    try page.evaluate("coveDebug.snapshot.count").int == 3, "Rejected replay changed the count")

  _ = try page.evaluate(
    "coveDebug.request({type:'state.restore',id:93,payload:{count:'2',dark:'true'}})")
  try page.waitForFunction("coveDebug.snapshot.count === 2")
  try page.locator("#surface").click(position: .object(["x": .number(60), "y": .number(380)]))
  try page.waitForFunction("document.activeElement.id === 'textInput'")
  try page.insertText("你好🙂")
  try page.waitForFunction("coveDebug.snapshot.note === '你好🙂'")
  try page.keyboardPress("Backspace")
  try page.waitForFunction("coveDebug.snapshot.note === '你好'")
  _ = try page.evaluate(
    """
    () => {
        const input=document.querySelector('#textInput');
        input.dispatchEvent(new CompositionEvent('compositionstart',{data:''}));
        input.dispatchEvent(new CompositionEvent('compositionupdate',{data:'中文'}));
    }
    """)
  try page.waitForFunction("coveDebug.snapshot.labels.some(l=>l.text==='你好中文')")
  try page.waitForFunction(
    """
    () => {
        const snapshot=coveDebug.snapshot;
        function find(n){if(n.debugName==='counter.note')return n;for(const c of n.children){const r=find(c);if(r)return r;}}
        const frame=find(snapshot.tree.root).absoluteFrame;
        const left=document.querySelector('#surface').getBoundingClientRect().left;
        const expected=left+frame.x+Math.min(frame.w-20,16+snapshot.noteWidth);
        return snapshot.noteWidth>40 && Math.abs(parseFloat(document.querySelector('#textInput').style.left)-expected)<1;
    }
    """)
  _ = try page.evaluate(
    "document.querySelector('#textInput').dispatchEvent(new CompositionEvent('compositionend',{data:'中文'}))"
  )
  try page.waitForFunction("coveDebug.snapshot.note === '你好中文'")

  for (text, fontID) in [("office", 1), ("你好中文", 2), ("سلام", 3), ("कि", 1), ("🙂", 5)] {
    _ = try page.evaluate(
      "text => coveDebug.request({type:'state.restore',id:94,payload:{count:'2',dark:'true',note:text}})",
      argument: .string(text))
    try page.waitForFunction("text => coveDebug.snapshot.note === text", argument: .string(text))
    let label = try page.evaluate(
      "text => coveDebug.snapshot.labels.find(l=>l.text===text)", argument: .string(text))
    let glyphs = label["glyphs"]?.array ?? []
    try ensure(
      !glyphs.isEmpty && glyphs.allSatisfy(\.isTruthy),
      "Glyphs are missing for \(text): \(label.serialized)")
    try ensure(
      (label["fontIDs"]?.array ?? []).contains(.number(Double(fontID))),
      "Font id \(fontID) is missing for \(text): \(label.serialized)")
    if text == "office" {
      try ensure(glyphs.count < text.count, "Latin ligatures did not combine: \(label.serialized)")
    }
    if text == "سلام" {
      let clusters = (label["clusters"]?.array ?? []).compactMap(\.number)
      try ensure(
        (clusters.first ?? 0) > (clusters.last ?? 0),
        "Arabic clusters are not right-to-left: \(label.serialized)")
    }
    if text == "कि" {
      let clusters = (label["clusters"]?.array ?? []).compactMap(\.int)
      try ensure(
        glyphs.count == 2 && clusters.allSatisfy { $0 == 0 },
        "Devanagari clusters are wrong: \(label.serialized)")
    }
    let rect = [
      label["x"]?.number ?? 0, label["y"]?.number ?? 0,
      label["width"]?.number ?? 0, (label["size"]?.number ?? 0) * 1.4,
    ]
    try waitPixels(page, .rect(rect)) { pixels in
      pixels.filter { $0.r > 180 && $0.g > 180 && $0.b > 180 && $0.a > 200 }.count > 8
    }
  }

  _ = try page.evaluate(
    "coveDebug.request({type:'state.restore',id:95,payload:{count:'2',dark:'true',note:'你好中文'}})")
  try page.waitForFunction("coveDebug.snapshot.note === '你好中文'")
  try analysisChecks(page: page, inspector: frame)
  try inspectionChecks(page: page, inspector: frame)
  try wasmObservationChecks(page: page, inspector: frame)
  try inspector.locator("#disconnect").click()
  try inspector.locator("#connect").click()
  try inspector.locator("#status").filter(text: .contains("Connected")).waitFor()
  try page.setViewportSize(width: 600, height: 1100)
  try page.waitForFunction("coveDebug.snapshot.width < 600")
  try ensure(try page.evaluate("coveDebug.snapshot.count").int == 2, "Resize changed the counter")
  try ensure(page.errors.isEmpty, "Page errors: \(page.errors)")

  if let screenshot {
    try page.setViewportSize(width: 1280, height: 1100)
    try page.waitForFunction("coveDebug.snapshot.width > 600")
    try inspector.locator("#tree .treeNode").filter(text: .contains("counter.card")).click()
    try page.waitForFunction(
      "coveDebug.snapshot.tree.inspection.selectedID === inspectedNode('counter.card').elementID")
    try page.screenshot(to: screenshot, fullPage: true)
  }
  let backend = try page.evaluate("coveDebug.backend").string ?? ""
  Terminal.info(
    "Wasm \(backend) (\(scaleText(scale))x): pixels, font atlas/fallback, Latin ligatures, Arabic, Devanagari, emoji, Compose/Yoga, Unicode/IME, DevTools and resize passed"
  )
  try page.close()
}
