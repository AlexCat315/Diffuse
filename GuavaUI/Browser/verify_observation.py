"""Acceptance against the real Inspector and host protocol, without a GPU."""
import json


def native_observation_checks(page, screenshot=None):
    page.locator("#registeredStates").filter(has_text="count").wait_for()
    assert page.evaluate("observation.registered.every(s => s.name === 'count')")
    assert page.evaluate("observation.values.size") == 0
    # Repeated frame/tree notifications must not detach interactive watch fields.
    assert page.evaluate("""() => {
        const checkbox = document.querySelector('#registeredStates input');
        for (let i=0; i<50; i++) renderStateRegistry();
        return checkbox === document.querySelector('#registeredStates input');
    }""")
    watch = page.locator("#registeredStates input[type=checkbox]").first
    watch.check()
    page.wait_for_function("observation.values.size === 1")
    initial = page.evaluate("[...observation.values.values()][0].summary")
    page.locator("#startTimeline").click()
    page.wait_for_function("observation.recording")
    changed = str(int(initial) + 1)
    page.locator("#stateSnapshot").fill(json.dumps({"count": changed}))
    page.locator("#restoreState").click()
    page.wait_for_function("value => [...observation.values.values()][0]?.summary === value", arg=changed)
    page.wait_for_function("['component','recomposition','layout','draw'].every(p => observation.events.some(e => e.phase === p))")
    assert page.evaluate("observation.events.every(e => Number.isFinite(e.durationMs) && e.durationMs >= 0 && e.startMs >= 0)")
    if screenshot:
        page.locator("#startTimeline").scroll_into_view_if_needed()
        page.screenshot(path=screenshot)
    page.locator("#timelinePhase").select_option("component")
    assert page.locator("#timelineEvents button").count() >= 1
    page.locator("#timelineEvents button").first.click()
    page.locator("#stateSelectedOnly").check()
    assert page.locator("#registeredStates input").count() == 1
    uri = page.locator("#addSourceBreakpoint").get_attribute("href")
    assert uri.startswith("vscode://guava.guavaui-devtools/breakpoint?file=") and "&line=" in uri, uri
    page.evaluate("document.querySelector('#addSourceBreakpoint').addEventListener('click', e => { e.preventDefault(); window.breakpointClick=e.currentTarget.href; })")
    page.locator("#addSourceBreakpoint").click()
    assert page.evaluate("window.breakpointClick") == uri
    page.locator("#stopTimeline").click()
    page.wait_for_function("!observation.recording && !observation.pending")
    captured = page.evaluate("observation.events.length")
    page.wait_for_timeout(300)
    assert page.evaluate("observation.events.length") == captured
    with page.expect_download() as pending:
        page.locator("#exportTimeline").click()
    trace = json.loads(open(pending.value.path()).read())
    assert len(trace["traceEvents"]) == captured and all(e["ph"] == "X" and isinstance(e["tid"], int) for e in trace["traceEvents"])
    page.locator("#stopWatching").click()
    assert page.evaluate("observation.watched.size === 0 && observation.values.size === 0")
    page.locator("#disconnect").click()
    page.wait_for_timeout(100)
    assert page.evaluate("observation.events.length === 0 && observation.registered.length === 0")
    page.locator("#connect").click()
    page.locator("#registeredStates").filter(has_text="count").wait_for()
    assert not page.locator("#registeredStates input").first.is_checked()
    assert page.locator("#startTimeline").is_enabled()
    print("Observation: opt-in values, live State writes, scope filter, CPU timeline, stop/export, breakpoint URI and disconnect cleanup passed", flush=True)


def wasm_observation_checks(page, inspector):
    frame = page.locator("#inspector").element_handle().content_frame()
    baseline = page.evaluate("({count:guavaDebug.snapshot.count, dark:guavaDebug.snapshot.dark, note:guavaDebug.snapshot.note})")
    inspector.locator("#registeredStates").filter(has_text="count").wait_for()
    assert frame.evaluate("observation.registered.map(s=>s.name).sort().join(',')") == "count,dark"
    assert frame.evaluate("observation.values.size") == 0
    inspector.locator("#registeredStates label").filter(has_text="count").locator("input").check()
    frame.wait_for_function("observation.values.size === 1")
    inspector.locator("#startTimeline").click()
    frame.wait_for_function("observation.recording && !observation.pending")
    page.locator("#increment").click()
    frame.wait_for_function("n => [...observation.values.values()][0]?.summary === String(n)", arg=baseline["count"] + 1)
    card = page.evaluate("inspectedNode('counter.card').id")
    frame.evaluate("id=>selectNode(findNode(state.tree,id))", card)
    inspector.locator("#paddingLeft").fill("32")
    frame.wait_for_function("['component','recomposition','layout','draw'].every(p=>observation.events.some(e=>e.phase===p))")
    assert frame.evaluate("observation.events.every(e=>Number.isFinite(e.startMs)&&Number.isFinite(e.durationMs)&&e.startMs>=0&&e.durationMs>=0)")
    inspector.locator("#timelinePhase").select_option("component")
    inspector.locator("#timelineEvents button").first.click()
    inspector.locator("#stateSelectedOnly").check()
    assert inspector.locator("#registeredStates input").count() == 2
    assert inspector.locator("#addSourceBreakpoint").get_attribute("href").startswith("vscode://guava.guavaui-devtools/breakpoint?")
    inspector.locator("#stopTimeline").click()
    frame.wait_for_function("!observation.recording && !observation.pending")
    captured = frame.evaluate("observation.events.length")
    page.locator("#increment").click()
    frame.wait_for_function("n => [...observation.values.values()][0]?.summary === String(n)", arg=baseline["count"] + 2)
    assert frame.evaluate("observation.events.length") == captured
    with page.expect_download() as pending:
        inspector.locator("#exportTimeline").click()
    trace = json.loads(open(pending.value.path()).read())
    assert len(trace["traceEvents"]) == captured
    assert all(e["ph"] == "X" and isinstance(e["tid"], int) for e in trace["traceEvents"])
    inspector.locator("#disconnect").click()
    frame.wait_for_function("observation.events.length===0 && observation.registered.length===0")
    inspector.locator("#connect").click()
    frame.wait_for_function("observation.registered.length===2")
    assert not inspector.locator("#registeredStates input").first.is_checked()
    assert inspector.locator("#startTimeline").is_enabled()
    page.evaluate("s=>guavaDebug.request({type:'state.restore',id:994,payload:{count:String(s.count),dark:String(s.dark),note:s.note}})", baseline)
    page.wait_for_function("s=>guavaDebug.snapshot.count===s.count && guavaDebug.snapshot.note===s.note", arg=baseline)
    print("Wasm observation: explicit/private State, real updates, all CPU stages, component navigation, trace export, stop and reconnect cleanup passed", flush=True)
