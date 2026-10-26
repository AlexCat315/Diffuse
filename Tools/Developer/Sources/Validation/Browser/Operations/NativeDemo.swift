internal import Foundation
private import ToolSupport

/// `native-demo` — real native Compose/Metal mirror acceptance. Replaces
/// `CoveUI/Browser/verify_native_demo.py`; start `CoveUIDemo --shared-counter`
/// first.
enum NativeDemoOperation {
  static func run(_ arguments: [String]) throws {
    var parser = FlagParser(
      arguments, valued: ["--endpoint", "--screenshot"],
      switches: ["--require-presented"])
    try parser.parse()
    if parser.flags.contains("--help") {
      Terminal.info(Browser.usage)
      return
    }
    if let unexpected = parser.positionals.first {
      throw ToolError.message("unrecognized arguments: \(unexpected)")
    }
    try demo(
      endpoint: parser.values["--endpoint"] ?? "ws://127.0.0.1:9229/",
      screenshot: parser.values["--screenshot"],
      requirePresented: parser.flags.contains("--require-presented"))
  }

  static func demo(endpoint: String, screenshot: String?, requirePresented: Bool) throws {
    // The client directory is served from the repo-relative path the
    // reference script builds, `CoveUI/DevTools/Client/Client`.
    let client = Browser.sdkRoot.appendingPathComponent("DevTools/Client/Client")
    let server = try staticServer(directory: client)
    server.start()
    defer { server.stop() }

    let browser = try ChromiumBrowser.launch(
      executable: nil, arguments: ["--no-sandbox", "--use-angle=swiftshader"])
    defer { browser.close() }
    let page = try browser.newPage(viewport: Viewport(width: 1600, height: 1000))
    var baseline: JSON?
    defer { cleanup(page: page, baseline: baseline) }

    try page.goto("http://127.0.0.1:\(server.port)/")
    try page.locator("#endpoint").fill(endpoint)
    try page.locator("#connect").click()
    try page.waitForFunction("inspector.session.observation.registered.length === 2")
    try ensure(
      try page.evaluate("inspector.session.observation.registered.map(s=>s.name).sort().join(',')")
        .string
        == "count,dark", "Native Demo registration is not count,dark")
    try page.locator("#registeredStates label").filter(text: .contains("count")).locator("input")
      .check()
    try page.waitForFunction("inspector.session.observation.values.size === 1")
    try page.waitForFunction(
      "inspector.session.timing.timingFrames.some(f=>typeof f.presented==='boolean')")
    let timing = try JSON.parse(try page.locator("#timing").innerText())
    try ensure(
      ["submitted", "skipped"].contains(timing["presentation"]?.string ?? ""),
      "Native Demo presentation status: \(timing.compactText)")
    try ensure(
      timing["cpuThroughputFPS"] != nil && timing["fps"] == nil,
      "Native Demo timing is missing cpuThroughputFPS: \(timing.compactText)")
    let initial = Int(
      try page.evaluate("Number([...inspector.session.observation.values.values()][0].summary)")
        .number ?? 0)
    try page.locator("#captureState").click()
    try page.waitForFunction("document.querySelector('#stateSnapshot').value.includes('count')")
    baseline = try JSON.parse(try page.locator("#stateSnapshot").inputValue())

    func lastFrame() throws -> Int {
      try page.evaluate("inspector.session.timing.timingFrames.at(-1)?.frame ?? 0").int ?? 0
    }
    func requireSubmission(after: Int = 0) throws {
      guard requirePresented else { return }
      try page.waitForFunction(
        "after => { const frame=inspector.session.timing.timingFrames.at(-1); "
          + "return frame?.presented===true && frame.frame>after; }",
        argument: .number(Double(after)), timeout: 15)
    }

    try requireSubmission()
    try page.locator("#startTimeline").click()
    try page.waitForFunction("inspector.session.observation.recording")
    try page.locator("#stateSnapshot").fill(
      JSON.object([
        "count": .string(String(initial + 1)),
        "dark": "false", "note": "",
      ]).serialized)
    let beforeState = try lastFrame()
    try page.locator("#restoreState").click()
    try page.waitForFunction(
      "count => [...inspector.session.observation.values.values()][0]?.summary === String(count)",
      argument: .number(Double(initial + 1)))
    try requireSubmission(after: beforeState)

    // This shared view has fixed boxes; State alone may legitimately skip
    // clean Yoga passes. Change padding to require real layout.
    _ = try page.evaluate(
      """
      window.demoNode = name => {
          function find(n) { if(n.debugName===name) return n; for(const c of n.children??[]) {const found=find(c);if(found)return found;} }
          return find(inspector.session.tree.tree);
      }; inspector.tree.selectNode(demoNode('counter.card'));
      """)
    let beforeLayout = try lastFrame()
    try page.locator("#paddingLeft").fill("32")
    try page.waitForFunction("demoNode('counter.card').layout.padding.left === 32")
    try requireSubmission(after: beforeLayout)
    try page.waitForFunction(
      "['component','recomposition','layout','draw'].every(p=>inspector.session.observation.events.some(e=>e.phase===p))"
    )

    try page.locator("#startMirror").click()
    try page.waitForFunction(
      "inspector.session.mirror.mirrorFrame != null && document.querySelector('#mirrorImage').naturalWidth > 0",
      timeout: 15)
    try page.waitForFunction(
      """
      () => {
          const image=document.querySelector('#mirrorImage'), frame=demoNode('counter.increment').absoluteFrame;
          const canvas=document.createElement('canvas');canvas.width=image.naturalWidth;canvas.height=image.naturalHeight;
          const context=canvas.getContext('2d');context.drawImage(image,0,0);
          const rx=image.naturalWidth/inspector.session.mirror.mirrorFrame.logicalWidth, ry=image.naturalHeight/inspector.session.mirror.mirrorFrame.logicalHeight;
          const pixel=context.getImageData(Math.round((frame.x+12)*rx),Math.round((frame.y+frame.h/2)*ry),1,1).data;
          return pixel[3]>200 && pixel[2]>150 && pixel[2]>pixel[0]+50;
      }
      """, timeout: 15)

    let frame = try page.evaluate("demoNode('counter.increment').absoluteFrame")
    let mirror = try page.locator("#mirrorImage").boundingBox()
    let logical = try page.evaluate(
      "({w:inspector.session.mirror.mirrorFrame.logicalWidth,h:inspector.session.mirror.mirrorFrame.logicalHeight})"
    )
    let beforePointer = try lastFrame()
    try page.mouseClick(
      x: (mirror["x"]?.number ?? 0)
        + ((frame["x"]?.number ?? 0) + (frame["w"]?.number ?? 0) / 2) / (logical["w"]?.number ?? 1)
          * (mirror["width"]?.number ?? 0),
      y: (mirror["y"]?.number ?? 0)
        + ((frame["y"]?.number ?? 0) + (frame["h"]?.number ?? 0) / 2) / (logical["h"]?.number ?? 1)
        * (mirror["height"]?.number ?? 0))
    try page.waitForFunction(
      "count => [...inspector.session.observation.values.values()][0]?.summary === String(count)",
      argument: .number(Double(initial + 2)))
    try requireSubmission(after: beforePointer)

    if let screenshot {
      try page.locator("#startTimeline").scrollIntoViewIfNeeded()
      try page.screenshot(to: screenshot)
    }
    try ensure(page.errors.isEmpty, "Page errors: \(page.errors)")
    if requirePresented {
      Terminal.info(
        "Native primary surface: submitted frames after State, layout and pointer changes passed")
    }
    Terminal.info(
      "Native Demo: explicit fields, live State, presentation status, CPU throughput, actual Yoga/draw/commit spans, Metal mirror pixels and remote pointer input passed"
    )
    flushOutput()
  }

  /// Restores the captured state and disconnects the session the way the
  /// reference `finally` block does, ignoring a connection that already went
  /// away.
  private static func cleanup(page: Page, baseline: JSON?) {
    if let baseline, (try? page.evaluate("inspector.session.connection.connected").isTruthy) == true
    {
      _ = try? page.locator("#stateSnapshot").fill(baseline.serialized)
      _ = try? page.locator("#restoreState").click()
      _ = try? page.waitForFunction(
        "count=>[...inspector.session.observation.values.values()][0]?.summary===count",
        argument: baseline["count"] ?? .null)
    }
    _ = try? page.evaluate(
      "if(inspector.session.connection.connected) {"
        + "inspector.connection.send('mirror.stop');inspector.connection.send('timeline.unsubscribe');"
        + "inspector.connection.disconnect();}")
  }
}
