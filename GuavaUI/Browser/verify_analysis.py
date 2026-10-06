"""Real Wasm and socket acceptance for source links and body profiling."""
from pathlib import Path


def analysis_checks(page, inspector):
    initial_count = page.evaluate("guavaDebug.snapshot.count")
    frame = page.locator("#inspector").element_handle().content_frame()
    assert frame.evaluate("compactTag('GuavaUI.Row<GuavaUI._SourceLocatedView<Demo.Button>>')") == "Row"
    inspector.locator("#tree button").filter(has_text="counter.value").first.click()
    inspector.locator("#sourceLocation").filter(has_text="SharedCounterView.swift:").wait_for()
    source = frame.evaluate("findNode(state.tree, state.selectedId).source")
    assert source["line"] > 0 and source["column"] > 0
    lines = (Path(__file__).resolve().parent.parent / "Portable/Sources/GuavaUISharedDemo/SharedCounterView.swift").read_text().splitlines()
    assert 'debugName("counter.value")' in lines[source["line"] - 1], source
    expected = frame.evaluate("editorSourceURL(findNode(state.tree, state.selectedId).source, 'vscode')")
    assert inspector.locator("#openSource").get_attribute("href") == expected
    assert expected.endswith(f':{source["line"]}:{source["column"]}')
    # Prevent external app launch while verifying that the UI exposes a usable URI.
    frame.evaluate("document.querySelector('#openSource').addEventListener('click', e => { e.preventDefault(); window.clickedSource=e.currentTarget.href; })")
    inspector.locator("#openSource").click()
    assert frame.evaluate("window.clickedSource") == expected
    inspector.locator("#sourceEditor").select_option("cursor")
    assert inspector.locator("#openSource").get_attribute("href").startswith("cursor://file/")
    frame.locator("details").filter(has=frame.locator("#sourceBuildRoot")).evaluate("e => e.open = true")
    build_root = source["filePath"].split("/GuavaUI/")[0]
    inspector.locator("#sourceBuildRoot").fill(build_root)
    inspector.locator("#sourceLocalRoot").fill("C:\\我的项目\\Guava UI")
    uri = inspector.locator("#openSource").get_attribute("href")
    assert uri.startswith("cursor://file/C:/%E6%88%91%E7%9A%84%E9%A1%B9%E7%9B%AE/Guava%20UI/GuavaUI/"), uri
    assert frame.evaluate("editorSourceURL({filePath:'/build/name #.swift',line:2,column:3},'vscode','/build','/Users/me')") == "vscode://file/Users/me/name%20%23.swift:2:3"
    assert frame.evaluate("editorSourceURL({filePath:'/build/name.swift',line:2,column:3},'vscode','/','C:/')") == "vscode://file/C:/build/name.swift:2:3"
    assert frame.evaluate("editorSourceURL({filePath:'C:/build/name.swift',line:2,column:3},'vscode','C:/','/local')") == "vscode://file/local/build/name.swift:2:3"
    for path in ["file:///tmp/a.swift", "javascript:alert(1)", "relative.swift", "/tmp/../a.swift", "/tmp/a\n.swift"]:
        assert frame.evaluate("p => editorSourceURL({filePath:p,line:1,column:1},'vscode')", path) is None
    assert frame.evaluate("editorSourceURL({filePath:'/tmp/a.swift',line:0,column:1},'vscode')") is None
    assert frame.evaluate("editorSourceURL({filePath:'/tmp/a.swift',line:1,column:1},'custom')") is None
    assert frame.evaluate("editorSourceURL({filePath:'/build2/a.swift',line:1,column:1},'vscode','/build','/local')") is None
    inspector.locator("#sourceBuildRoot").fill("")
    inspector.locator("#sourceLocalRoot").fill("")
    inspector.locator("#sourceEditor").select_option("vscode")
    frame.locator("details").filter(has=frame.locator("#sourceBuildRoot")).evaluate("e => e.open = false")
    # Counts are read from the actual owning user scope, never the DOM/paint loop.
    before = frame.evaluate("findNode(state.tree, findNode(state.tree, state.selectedId).ownerScopeID).recomposition.count")
    page.locator("#increment").click()
    frame.wait_for_function("n => { const node=findNode(state.tree,state.selectedId); return findNode(state.tree,node.ownerScopeID).recomposition.count > n; }", arg=before)
    inspector.locator("#recompositionReasons").filter(has_text="state: count").wait_for()
    metrics = frame.evaluate("findNode(state.tree, findNode(state.tree, state.selectedId).ownerScopeID).recomposition")
    assert metrics["count"] == before + 1 and metrics["lastMs"] >= 0 and metrics["maxMs"] >= metrics["lastMs"]
    assert metrics["reasons"] == [{"kind": "state", "detail": "count"}]
    inspector.locator("details").filter(has=inspector.locator("#recompositionTable")).evaluate("e => e.open = true")
    assert inspector.locator("#recompositionTable button").count() >= 1
    inspector.locator("#recompositionSort").select_option("count")
    inspector.locator("#resetRecomposition").click()
    frame.wait_for_function("findNode(state.tree,findNode(state.tree,state.selectedId).ownerScopeID).recomposition.count === 0")
    inspector.locator("#recompositionStats").filter(has_text="Recompositions: 0").wait_for()
    assert frame.evaluate("findNode(state.tree,findNode(state.tree,state.selectedId).ownerScopeID).recomposition.reasons.length") == 0
    page.evaluate("count => guavaDebug.request({type:'state.restore',id:992,payload:{count:String(count),dark:String(guavaDebug.snapshot.dark)}})", initial_count)
    page.wait_for_function("count => guavaDebug.snapshot.count === count", arg=initial_count)
    print("Analysis: exact Swift expression line, VS Code/Cursor URI, remote/Windows path mapping, real State count/cause, timing and reset passed", flush=True)


def native_analysis_checks(page):
    page.locator("#recompositionCount").filter(has_text="1").wait_for()
    page.locator("details").filter(has=page.locator("#recompositionTable")).evaluate("e => e.open = true")
    page.locator("#recompositionTable button").first.click()
    page.locator("#sourceLocation").filter(has_text="main.swift:").wait_for()
    page.locator("#recompositionStats").filter(has_text="Recompositions: 1").wait_for()
    page.locator("#recompositionReasons").filter(has_text="state: count").wait_for()
    assert page.locator("#openSource").get_attribute("href").startswith("vscode://file/")
    page.locator("#resetRecomposition").click()
    page.locator("#recompositionStats").filter(has_text="Recompositions: 0").wait_for()
    print("Native WebSocket: real Compose source/profile, State cause and reset passed", flush=True)
