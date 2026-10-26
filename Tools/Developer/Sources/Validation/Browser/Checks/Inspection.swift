internal import Foundation
private import ToolSupport

/// Acceptance checks shared by Canvas/WebGPU and native socket verification.
func inspectionChecks(page: Page, inspector: Frame) throws {
  _ = try page.evaluate(
    """
    window.inspectedNode = name => {
      function find(n) { if(n.debugName===name) return n; for(const c of n.children) {const r=find(c);if(r)return r;} }
      return find(coveDebug.snapshot.tree.root);
    }
    """)
  let count = try page.evaluate("coveDebug.snapshot.count").int ?? 0

  try inspector.locator("#pickNode").click()
  try page.waitForFunction("coveDebug.snapshot.tree.inspection.picking")
  let button = try page.evaluate("inspectedNode('counter.increment').absoluteFrame")
  try page.locator("#surface").click(
    position: .object([
      "x": .number((button["x"]?.number ?? 0) + (button["w"]?.number ?? 0) / 2),
      "y": .number((button["y"]?.number ?? 0) + (button["h"]?.number ?? 0) / 2),
    ]))
  try page.waitForFunction(
    "coveDebug.snapshot.tree.inspection.selectedID === inspectedNode('counter.increment').elementID"
  )
  try ensure(
    try page.evaluate("coveDebug.snapshot.count").int == count,
    "Picking a node changed the counter")

  try inspector.locator("#pickNode").click()
  try page.waitForFunction("coveDebug.snapshot.tree.inspection.picking")
  let value = try page.evaluate("inspectedNode('counter.value').absoluteFrame")
  try page.locator("#surface").click(
    position: .object([
      "x": .number((value["x"]?.number ?? 0) + 4),
      "y": .number((value["y"]?.number ?? 0) + 4),
    ]))
  try page.waitForFunction(
    "coveDebug.snapshot.tree.inspection.selectedID === inspectedNode('counter.value').elementID")
  try ensure(
    try page.evaluate("inspectedNode('counter.value').flags.hitTestable").bool == false,
    "Text node reported as hit testable")

  try inspector.locator("#selectionPath button").filter(text: .contains("counter.card")).click()
  try page.waitForFunction(
    "coveDebug.snapshot.tree.inspection.selectedID === inspectedNode('counter.card').elementID")
  try inspector.waitForFunction(
    "!inspector.session.tree.pendingSelectionId && inspector.tree.findNode(inspector.session.tree.tree,inspector.session.tree.selectedId)?.debugName === 'counter.card'"
  )
  // A delayed snapshot from before selection must not erase a focused draft
  // or cancel the edit timer while the new selection is awaiting confirmation.
  // Confirm the real selection before simulating an acknowledgement so the
  // test cannot clear an actual pending request with its synthetic snapshot.
  _ = try inspector.evaluate(
    """
    () => {
      const node=inspector.tree.findNode(inspector.session.tree.tree,inspector.session.tree.selectedId), previous=node.children[0];
      inspector.session.tree.pendingSelectionId=inspector.session.tree.selectedId;
      const input=document.querySelector('#paddingLeft'); input.focus();input.value='31';
      inspector.inspection.syncInspection({...inspector.session.tree.inspection,selectedID:previous.elementID});
      if(inspector.session.tree.selectedId!==node.elementID || input.value!=='31') throw Error('Stale selection erased draft');
      inspector.inspection.syncInspection({...inspector.session.tree.inspection,selectedID:node.elementID});
    }
    """)

  let profileBefore =
    try inspector.evaluate(
      "inspector.tree.findNode(inspector.session.tree.tree,inspector.tree.findNode(inspector.session.tree.tree,inspector.session.tree.selectedId).ownerScopeID).recomposition.count"
    ).int ?? 0
  try inspector.locator("#paddingLeft").fill("32")
  try page.waitForFunction("inspectedNode('counter.card').layout.padding.left === 32")
  try ensure(
    try page.evaluate(
      "inspectedNode('counter.value').absoluteFrame.x-inspectedNode('counter.card').absoluteFrame.x"
    ).number == 32,
    "Padding did not move the child")
  try inspector.locator("#backgroundColor").fill("#ff2020")
  try page.waitForFunction("inspectedNode('counter.card').style.backgroundColor === '#ff2020ff'")
  try waitPixels(
    page,
    .script(
      "() => { const n=inspectedNode('counter.card').absoluteFrame;return [n.x+n.w-12,n.y+30,1,1]; }"
    )
  ) { pixels in
    pixels.contains { $0.r > 220 && $0.g < 50 && $0.b < 50 && $0.a > 200 }
  }

  try inspector.locator("#foregroundColor").fill("#00ff00")
  try page.waitForFunction("inspectedNode('counter.card').style.foregroundColor === '#00ff00ff'")
  try waitPixels(
    page,
    .script(
      "() => { const l=coveDebug.snapshot.labels.find(l=>l.text===String(coveDebug.snapshot.count));return [l.x,l.y,l.width,l.size*1.4]; }"
    )
  ) { pixels in
    pixels.filter { $0.r < 80 && $0.g > 180 && $0.b < 80 }.count > 50
  }
  try ensure(
    try inspector.evaluate(
      "inspector.tree.findNode(inspector.session.tree.tree,inspector.tree.findNode(inspector.session.tree.tree,inspector.session.tree.selectedId).ownerScopeID).recomposition.count"
    ).int == profileBefore,
    "Style overrides triggered recomposition")

  // Composition retains debug values; clearing restores the latest theme.
  try page.locator("#theme").click()
  try page.waitForFunction(
    "coveDebug.snapshot.dark === false && inspectedNode('counter.card').layout.padding.left === 32"
  )
  try ensure(
    try page.evaluate("inspectedNode('counter.card').style.backgroundColor").string == "#ff2020ff",
    "Override did not survive composition")
  try inspector.locator("#undoStyle").click()
  try page.waitForFunction(
    "!inspectedNode('counter.card').style.overrides.includes('foregroundColor')")
  try inspector.locator("#redoStyle").click()
  try page.waitForFunction("inspectedNode('counter.card').style.foregroundColor === '#00ff00ff'")

  let rejected = try page.evaluate(
    """
    coveDebug.request({type:'inspect.style.set',id:987,payload:{id:inspectedNode('counter.card').elementID,
      properties:{backgroundColor:'#ffffff',padding:{top:-1,right:0,bottom:0,left:0}}}})
    """)
  try ensure(
    rejected["type"]?.string == "inspect.style.set.err" && rejected["id"]?.int == 987,
    "Invalid style request was accepted: \(rejected.serialized)")
  try ensure(
    try page.evaluate("inspectedNode('counter.card').style.backgroundColor").string == "#ff2020ff",
    "Rejected style changed the node")

  try inspector.locator("#clearStyle").click()
  try page.waitForFunction(
    "coveDebug.snapshot.tree.inspection.overrideCount===0 && inspectedNode('counter.card').layout.padding.left===20"
  )
  try ensure(
    try page.evaluate("inspectedNode('counter.card').style.backgroundColor").string != "#ff2020ff",
    "Cleared style still reports the override")
  try inspector.locator("#undoStyle").click()
  try page.waitForFunction("coveDebug.snapshot.tree.inspection.overrideCount===1")
  try inspector.locator("#clearAllStyles").click()
  try page.waitForFunction("coveDebug.snapshot.tree.inspection.overrideCount===0")
  try inspector.locator("#backgroundColor").fill("#abcdef")
  try page.waitForFunction("coveDebug.snapshot.tree.inspection.overrideCount===1")
  try page.locator("#theme").click()
  try page.waitForFunction("coveDebug.snapshot.dark === true")
  try inspector.locator("#disconnect").click()
  try page.waitForFunction(
    "coveDebug.snapshot.tree.inspection.overrideCount===0 && !coveDebug.snapshot.tree.inspection.canUndo"
  )
  try inspector.locator("#connect").click()
  try inspector.locator("#status").filter(text: .contains("Connected")).waitFor()
  Terminal.info(
    "Inspector: picking, layout, live padding/color pixels, recomposition, undo/redo, clear and disconnect cleanup passed"
  )
}

/// Native socket acceptance for picking, editable styles and undo/redo.
func nativeInspectionChecks(page: Page) throws {
  try page.locator("#pickNode").click()
  _ = try page.evaluate("inspector.connection.send('inspect.pick',{x:20,y:20})")
  try page.waitForFunction("!document.querySelector('#paddingLeft').disabled")
  try page.locator("#paddingLeft").fill("25")
  try page.waitForFunction("inspector.session.tree.tree.layout.padding.left === 25")
  try page.locator("#backgroundColor").fill("#ff0000")
  try page.waitForFunction("inspector.session.tree.tree.style.backgroundColor === '#ff0000ff'")
  try page.locator("#undoStyle").click()
  try page.waitForFunction("inspector.session.tree.tree.style.backgroundColor === '#ffffffff'")
  try page.locator("#redoStyle").click()
  try page.waitForFunction("inspector.session.tree.tree.style.backgroundColor === '#ff0000ff'")
  try page.locator("#disconnect").click()
  try page.locator("#connect").click()
  try page.locator("#status").filter(text: .contains("Connected")).waitFor()
  try page.waitForFunction(
    "inspector.session.tree.tree.layout.padding.left === 8 && inspector.session.tree.snapshot.inspection.overrideCount === 0 && !inspector.session.tree.snapshot.inspection.canUndo"
  )
  Terminal.info("Native WebSocket: picking, editable styles and undo/redo passed")
}
