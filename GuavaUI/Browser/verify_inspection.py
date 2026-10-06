"""Acceptance checks shared by Canvas/WebGPU and native socket verification."""

def inspection_checks(page, inspector):
    page.evaluate("""window.inspectedNode = name => {
      function find(n) { if(n.debugName===name) return n; for(const c of n.children) {const r=find(c);if(r)return r;} }
      return find(guavaDebug.snapshot.tree.root);
    }""")
    count = page.evaluate("guavaDebug.snapshot.count")
    inspector.locator("#pickNode").click()
    page.wait_for_function("guavaDebug.snapshot.tree.inspection.picking")
    button = page.evaluate("inspectedNode('counter.increment').absoluteFrame")
    page.locator("#surface").click(position={"x": button["x"]+button["w"]/2, "y": button["y"]+button["h"]/2})
    page.wait_for_function("guavaDebug.snapshot.tree.inspection.selectedID === inspectedNode('counter.increment').elementID")
    assert page.evaluate("guavaDebug.snapshot.count") == count
    inspector.locator("#pickNode").click()
    page.wait_for_function("guavaDebug.snapshot.tree.inspection.picking")
    value = page.evaluate("inspectedNode('counter.value').absoluteFrame")
    page.locator("#surface").click(position={"x": value["x"]+4, "y": value["y"]+4})
    page.wait_for_function("guavaDebug.snapshot.tree.inspection.selectedID === inspectedNode('counter.value').elementID")
    assert page.evaluate("inspectedNode('counter.value').flags.hitTestable") is False
    inspector.locator("#selectionPath button").filter(has_text="counter.card").click()
    inspector.locator("#paddingLeft").fill("32")
    page.wait_for_function("inspectedNode('counter.card').layout.padding.left === 32")
    assert page.evaluate("inspectedNode('counter.value').absoluteFrame.x-inspectedNode('counter.card').absoluteFrame.x") == 32
    inspector.locator("#backgroundColor").fill("#ff2020")
    page.wait_for_function("inspectedNode('counter.card').style.backgroundColor === '#ff2020ff'")
    page.wait_for_function("""() => {
      const n=inspectedNode('counter.card'), source=document.querySelector(guavaDebug.backend==='webgpu'?'#gpu':'#fallback');
      const canvas=document.createElement('canvas');canvas.width=source.width;canvas.height=source.height;
      const c=canvas.getContext('2d');c.drawImage(source,0,0);const r=source.width/guavaDebug.snapshot.width;
      const p=c.getImageData(Math.round((n.absoluteFrame.x+n.absoluteFrame.w-12)*r),Math.round((n.absoluteFrame.y+30)*r),1,1).data;
      return p[0]>220&&p[1]<50&&p[2]<50&&p[3]>200;
    }""")
    inspector.locator("#foregroundColor").fill("#00ff00")
    page.wait_for_function("inspectedNode('counter.card').style.foregroundColor === '#00ff00ff'")
    page.wait_for_function("""() => {
      const label=guavaDebug.snapshot.labels.find(l=>l.text===String(guavaDebug.snapshot.count));
      const source=document.querySelector(guavaDebug.backend==='webgpu'?'#gpu':'#fallback');
      const canvas=document.createElement('canvas');canvas.width=source.width;canvas.height=source.height;
      const c=canvas.getContext('2d');c.drawImage(source,0,0);const r=source.width/guavaDebug.snapshot.width;
      const p=c.getImageData(Math.round(label.x*r),Math.round(label.y*r),Math.ceil(label.width*r),Math.ceil(label.size*1.4*r)).data;
      let green=0;for(let i=0;i<p.length;i+=4)if(p[i]<80&&p[i+1]>180&&p[i+2]<80)green++;
      return green>50;
    }""")
    # Composition retains debug values; clearing restores the latest theme.
    page.locator("#theme").click()
    page.wait_for_function("guavaDebug.snapshot.dark === false && inspectedNode('counter.card').layout.padding.left === 32")
    assert page.evaluate("inspectedNode('counter.card').style.backgroundColor") == "#ff2020ff"
    inspector.locator("#undoStyle").click()
    page.wait_for_function("!inspectedNode('counter.card').style.overrides.includes('foregroundColor')")
    inspector.locator("#redoStyle").click()
    page.wait_for_function("inspectedNode('counter.card').style.foregroundColor === '#00ff00ff'")
    rejected = page.evaluate("""guavaDebug.request({type:'inspect.style.set',id:987,payload:{id:inspectedNode('counter.card').elementID,
      properties:{backgroundColor:'#ffffff',padding:{top:-1,right:0,bottom:0,left:0}}}})""")
    assert rejected["type"] == "inspect.style.set.err" and rejected["id"] == 987
    assert page.evaluate("inspectedNode('counter.card').style.backgroundColor") == "#ff2020ff"
    inspector.locator("#clearStyle").click()
    page.wait_for_function("guavaDebug.snapshot.tree.inspection.overrideCount===0 && inspectedNode('counter.card').layout.padding.left===20")
    assert page.evaluate("inspectedNode('counter.card').style.backgroundColor") != "#ff2020ff"
    inspector.locator("#undoStyle").click()
    page.wait_for_function("guavaDebug.snapshot.tree.inspection.overrideCount===1")
    inspector.locator("#clearAllStyles").click()
    page.wait_for_function("guavaDebug.snapshot.tree.inspection.overrideCount===0")
    inspector.locator("#backgroundColor").fill("#abcdef")
    page.wait_for_function("guavaDebug.snapshot.tree.inspection.overrideCount===1")
    page.locator("#theme").click()
    page.wait_for_function("guavaDebug.snapshot.dark === true")
    inspector.locator("#disconnect").click()
    page.wait_for_function("guavaDebug.snapshot.tree.inspection.overrideCount===0 && !guavaDebug.snapshot.tree.inspection.canUndo")
    inspector.locator("#connect").click()
    inspector.locator("#status").filter(has_text="Connected").wait_for()
    print("Inspector: picking, layout, live padding/color pixels, recomposition, undo/redo, clear and disconnect cleanup passed", flush=True)


def native_inspection_checks(page):
    page.locator("#pickNode").click()
    page.evaluate("send('inspect.pick',{x:20,y:20})")
    page.wait_for_function("!document.querySelector('#paddingLeft').disabled")
    page.locator("#paddingLeft").fill("25")
    page.wait_for_function("state.tree.layout.padding.left === 25")
    page.locator("#backgroundColor").fill("#ff0000")
    page.wait_for_function("state.tree.style.backgroundColor === '#ff0000ff'")
    page.locator("#undoStyle").click()
    page.wait_for_function("state.tree.style.backgroundColor === '#ffffffff'")
    page.locator("#redoStyle").click()
    page.wait_for_function("state.tree.style.backgroundColor === '#ff0000ff'")
    page.locator("#disconnect").click()
    page.locator("#connect").click()
    page.locator("#status").filter(has_text="Connected").wait_for()
    page.wait_for_function("state.tree.layout.padding.left === 8 && state.snapshot.inspection.overrideCount === 0 && !state.snapshot.inspection.canUndo")
