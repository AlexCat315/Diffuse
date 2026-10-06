"""Real native Compose/Metal mirror acceptance; start GuavaUIDemo --shared-counter first."""
import argparse
import functools
import http.server
import json
from pathlib import Path
import threading

from playwright.sync_api import sync_playwright


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", default="ws://127.0.0.1:9229/")
    parser.add_argument("--screenshot")
    options = parser.parse_args()
    client = Path(__file__).resolve().parent.parent / "DevTools"
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(client)))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(headless=True, args=["--no-sandbox", "--use-angle=swiftshader"])
            page = browser.new_page(viewport={"width": 1600, "height": 1000})
            errors = []
            page.on("pageerror", lambda error: errors.append(str(error)))
            try:
                page.goto(f"http://127.0.0.1:{server.server_port}/")
                page.locator("#endpoint").fill(options.endpoint)
                page.locator("#connect").click()
                page.wait_for_function("observation.registered.length === 2")
                assert page.evaluate("observation.registered.map(s=>s.name).sort().join(',')") == "count,dark"
                page.locator("#registeredStates label").filter(has_text="count").locator("input").check()
                page.wait_for_function("observation.values.size === 1")
                initial = page.evaluate("Number([...observation.values.values()][0].summary)")
                page.locator("#startTimeline").click()
                page.wait_for_function("observation.recording")
                page.locator("#stateSnapshot").fill(json.dumps({"count": str(initial + 1), "dark": "false", "note": ""}))
                page.locator("#restoreState").click()
                page.wait_for_function("count => [...observation.values.values()][0]?.summary === String(count)", arg=initial + 1)
                # This shared view has fixed boxes; State alone may legitimately
                # skip clean Yoga passes. Change padding to require real layout.
                page.evaluate("""window.demoNode = name => {
                    function find(n) { if(n.debugName===name) return n; for(const c of n.children??[]) {const found=find(c);if(found)return found;} }
                    return find(state.tree);
                }; selectNode(demoNode('counter.card'));""")
                page.locator("#paddingLeft").fill("32")
                page.wait_for_function("demoNode('counter.card').layout.padding.left === 32")
                page.wait_for_function("['component','recomposition','layout','draw'].every(p=>observation.events.some(e=>e.phase===p))")
                page.locator("#startMirror").click()
                page.wait_for_function("state.mirrorFrame != null && document.querySelector('#mirrorImage').naturalWidth > 0", timeout=15000)
                frame = page.evaluate("demoNode('counter.increment').absoluteFrame")
                mirror = page.locator("#mirrorImage").bounding_box()
                logical = page.evaluate("({w:state.mirrorFrame.logicalWidth,h:state.mirrorFrame.logicalHeight})")
                page.mouse.click(mirror["x"] + (frame["x"] + frame["w"] / 2) / logical["w"] * mirror["width"],
                                 mirror["y"] + (frame["y"] + frame["h"] / 2) / logical["h"] * mirror["height"])
                page.wait_for_function("count => [...observation.values.values()][0]?.summary === String(count)", arg=initial + 2)
                if options.screenshot:
                    page.locator("#startTimeline").scroll_into_view_if_needed()
                    page.screenshot(path=options.screenshot)
                assert not errors, errors
                print("Native Demo: explicit fields, stable watch controls, live State, actual Yoga/draw/commit spans, Metal mirror pixels and remote pointer input passed", flush=True)
            finally:
                page.evaluate("if(state.connected) {send('mirror.stop');send('timeline.unsubscribe');disconnect();}")
                browser.close()
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
