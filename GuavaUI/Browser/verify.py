"""Real browser verification for the Wasm prototype and native WebSocket server."""
import argparse
import functools
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time

from playwright.sync_api import sync_playwright


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


def preview_checks(browser, base_url, renderer, screenshot=None, scale=1):
    page = browser.new_page(viewport={"width": 1280, "height": 1100}, device_scale_factor=scale)
    errors = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    query = f"?renderer={renderer}" if renderer else ""
    page.goto(base_url + query, wait_until="networkidle")
    page.wait_for_function("window.guavaDebug?.snapshot != null", timeout=30000)
    if renderer == "webgpu":
        assert page.evaluate("guavaDebug.backend") == "webgpu"
    # A working API alone does not prove that any geometry was drawn.
    pixel_check = """() => {
        const gpu = guavaDebug.backend === 'webgpu';
        const source = document.querySelector(gpu ? '#gpu' : '#fallback');
        const canvas = document.createElement('canvas');
        canvas.width=source.width; canvas.height=source.height;
        const context=canvas.getContext('2d'); context.drawImage(source,0,0);
        const ratio=source.width/guavaDebug.snapshot.width;
        const p=context.getImageData(Math.round(60*ratio),Math.round(260*ratio),1,1).data;
        return p[3]>200 && p[2]>p[0]+50;
    }"""
    page.wait_for_function(pixel_check, timeout=10000)
    assert page.evaluate("guavaDebug.snapshot.fontCount") == 5
    # Check ink inside the title. This catches lost initial atlas uploads and
    # prevents the old Canvas system-font overlay from satisfying the test.
    assert page.locator("#labels").count() == 0
    page.wait_for_function("""() => {
        const source=document.querySelector(guavaDebug.backend==='webgpu'?'#gpu':'#fallback');
        const canvas=document.createElement('canvas');canvas.width=source.width;canvas.height=source.height;
        const c=canvas.getContext('2d');c.drawImage(source,0,0);
        const ratio=source.width/guavaDebug.snapshot.width;
        const p=c.getImageData(Math.ceil(24*ratio),Math.ceil(24*ratio),Math.floor(400*ratio),Math.floor(36*ratio)).data;
        let ink=0;for(let i=0;i<p.length;i+=4)if(p[i]<80&&p[i+1]<100&&p[i+2]<140&&p[i+3]>200)ink++;
        return ink>100;
    }""", timeout=10000)
    page.locator("#surface").click(position={"x": 60, "y": 260})
    page.wait_for_function("guavaDebug.snapshot.count === 1")
    page.locator("#increment").click()
    page.wait_for_function("guavaDebug.snapshot.count === 2")
    rejected = page.evaluate("guavaDebug.request({type:'state.restore',id:90,payload:{count:-1,dark:'true'}})")
    assert rejected["type"] == "state.restore.err" and rejected["id"] == 90
    assert page.evaluate("guavaDebug.snapshot.count") == 2
    node_id = page.evaluate("""() => {
        function find(n) { if(n.debugName==='counter.increment') return n; for(const c of n.children) {const r=find(c); if(r) return r;} }
        return find(guavaDebug.snapshot.tree.root).id;
    }""")
    selected = page.evaluate("id => guavaDebug.request({type:'select.node',id:91,payload:{id}})", node_id)
    assert selected["type"] == "select.node.ok"
    page.wait_for_function("id => { function find(n) { if(n.id===id) return n.flags.hasBorder; return n.children.some(find); } return find(guavaDebug.snapshot.tree.root); }", arg=node_id)
    page.locator("#surface").focus()
    page.keyboard.press("Enter")
    page.wait_for_function("guavaDebug.snapshot.count === 3")
    page.keyboard.press("Tab")
    page.keyboard.press("Space")
    page.wait_for_function("guavaDebug.snapshot.count === 0")
    page.locator("#increment").click()
    page.locator("#increment").click()
    page.wait_for_function("guavaDebug.snapshot.count === 2")
    assert page.evaluate("guavaDebug.snapshot.tree.inputInventory.nodeCount") > 5
    assert page.evaluate("guavaDebug.snapshot.tree.invalidations.some(i => i.source.startsWith('stateWrite'))")
    page.locator("#theme").click()
    page.wait_for_function("guavaDebug.snapshot.dark === true")
    inspector = page.frame_locator("#inspector")
    inspector.locator("#status").filter(has_text="Connected").wait_for()
    inspector.locator("#tree").filter(has_text="browser.root").wait_for()
    inspector.locator("#captureState").click()
    page.wait_for_function("document.querySelector('#inspector').contentDocument.querySelector('#stateSnapshot').value.includes('true')")
    captured = json.loads(inspector.locator("#stateSnapshot").input_value())
    assert captured == {"count": "2", "dark": "true", "note":""}
    page.locator("#reset").click()
    page.wait_for_function("guavaDebug.snapshot.count === 0")
    inspector.locator("#diffState").click()
    inspector.locator("#stateDiff").filter(has_text='"after": "0"').wait_for()
    inspector.locator("#restoreState").click()
    page.wait_for_function("guavaDebug.snapshot.count === 2")
    inspector.locator("#recordInput").click()
    inspector.locator("#stopRecording").wait_for(state="visible")
    page.wait_for_function("!document.querySelector('#inspector').contentDocument.querySelector('#stopRecording').disabled")
    page.locator("#increment").click()
    page.wait_for_function("guavaDebug.snapshot.count === 3")
    inspector.locator("#stopRecording").click()
    page.wait_for_function("document.querySelector('#inspector').contentDocument.querySelector('#inputRecording').value.includes('mouseButtonUp')")
    recording = json.loads(inspector.locator("#inputRecording").input_value())
    assert recording["initialState"] == {"count":"2", "dark":"true", "note":""}
    page.locator("#reset").click()
    page.wait_for_function("guavaDebug.snapshot.count === 0")
    inspector.locator("#replayInput").click()
    page.wait_for_function("guavaDebug.snapshot.count === 3")
    malformed = dict(recording, version=99)
    assert page.evaluate("r => guavaDebug.request({type:'input.replay', id:92, payload:r}).type", malformed) == "input.replay.err"
    assert page.evaluate("guavaDebug.snapshot.count") == 3
    page.evaluate("guavaDebug.request({type:'state.restore',id:93,payload:{count:'2',dark:'true'}})")
    page.wait_for_function("guavaDebug.snapshot.count === 2")
    page.locator("#surface").click(position={"x":60,"y":380})
    page.wait_for_function("document.activeElement.id === 'textInput'")
    page.keyboard.insert_text("你好🙂")
    page.wait_for_function("guavaDebug.snapshot.note === '你好🙂'")
    page.keyboard.press("Backspace")
    page.wait_for_function("guavaDebug.snapshot.note === '你好'")
    page.evaluate("""() => {
        const input=document.querySelector('#textInput');
        input.dispatchEvent(new CompositionEvent('compositionstart',{data:''}));
        input.dispatchEvent(new CompositionEvent('compositionupdate',{data:'中文'}));
    }""")
    page.wait_for_function("guavaDebug.snapshot.labels.some(l=>l.text==='你好中文')")
    page.wait_for_function("""() => {
        const snapshot=guavaDebug.snapshot;
        function find(n){if(n.debugName==='counter.note')return n;for(const c of n.children){const r=find(c);if(r)return r;}}
        const frame=find(snapshot.tree.root).absoluteFrame;
        const left=document.querySelector('#surface').getBoundingClientRect().left;
        const expected=left+frame.x+Math.min(frame.w-20,16+snapshot.noteWidth);
        return snapshot.noteWidth>40 && Math.abs(parseFloat(document.querySelector('#textInput').style.left)-expected)<1;
    }""")
    page.evaluate("document.querySelector('#textInput').dispatchEvent(new CompositionEvent('compositionend',{data:'中文'}))")
    page.wait_for_function("guavaDebug.snapshot.note === '你好中文'")
    for text, font_id in [("office", 1), ("你好中文", 2), ("سلام", 3), ("कि", 1), ("🙂", 5)]:
        page.evaluate("text => guavaDebug.request({type:'state.restore',id:94,payload:{count:'2',dark:'true',note:text}})", text)
        page.wait_for_function("text => guavaDebug.snapshot.note === text", arg=text)
        label = page.evaluate("text => guavaDebug.snapshot.labels.find(l=>l.text===text)", text)
        assert label["glyphs"] and all(label["glyphs"]), label
        assert font_id in label["fontIDs"], label
        if text == "office":
            assert len(label["glyphs"]) < len(text), label
        if text == "سلام":
            assert label["clusters"][0] > label["clusters"][-1], label
        if text == "कि":
            assert len(label["glyphs"]) == 2 and set(label["clusters"]) == {0}, label
        page.wait_for_function("""text => {
            const label=guavaDebug.snapshot.labels.find(l=>l.text===text);
            const source=document.querySelector(guavaDebug.backend==='webgpu'?'#gpu':'#fallback');
            const canvas=document.createElement('canvas');canvas.width=source.width;canvas.height=source.height;
            const c=canvas.getContext('2d');c.drawImage(source,0,0);
            const ratio=source.width/guavaDebug.snapshot.width;
            const p=c.getImageData(Math.round(label.x*ratio),Math.round(label.y*ratio),Math.ceil(label.width*ratio),Math.ceil(label.size*1.4*ratio)).data;
            let ink=0;for(let i=0;i<p.length;i+=4)if(p[i]>180&&p[i+1]>180&&p[i+2]>180&&p[i+3]>200)ink++;
            return ink>8;
        }""", arg=text, timeout=10000)
    page.evaluate("guavaDebug.request({type:'state.restore',id:95,payload:{count:'2',dark:'true',note:'你好中文'}})")
    page.wait_for_function("guavaDebug.snapshot.note === '你好中文'")
    inspector.locator("#disconnect").click()
    inspector.locator("#connect").click()
    inspector.locator("#status").filter(has_text="Connected").wait_for()
    page.set_viewport_size({"width": 600, "height": 1100})
    page.wait_for_function("guavaDebug.snapshot.width < 600")
    assert page.evaluate("guavaDebug.snapshot.count") == 2
    assert not errors, errors
    if screenshot:
        page.set_viewport_size({"width": 1280, "height": 1100})
        page.wait_for_function("guavaDebug.snapshot.width > 600")
        page.screenshot(path=screenshot, full_page=True)
    print(f"Wasm {page.evaluate('guavaDebug.backend')} ({scale}x): pixels, font atlas/fallback, Latin ligatures, Arabic, Devanagari, emoji, Compose/Yoga, Unicode/IME, DevTools and resize passed", flush=True)
    page.close()


def native_checks(browser, base_url, native_port):
    page = browser.new_page()
    page.goto(base_url + "devtools/index.html")
    page.locator("#endpoint").fill(f"ws://127.0.0.1:{native_port}/")
    page.locator("#connect").click()
    page.locator("#tree").filter(has_text="headless.root").wait_for()
    page.locator("#captureState").click()
    page.wait_for_function("document.querySelector('#stateSnapshot').value.includes('count')")
    page.locator("#stateSnapshot").fill('{"count":"12"}')
    page.locator("#restoreState").click()
    page.locator("#captureState").click()
    page.wait_for_function("document.querySelector('#stateSnapshot').value.includes('12')")
    page.locator("#disconnect").click()
    page.locator("#connect").click()
    page.locator("#status").filter(has_text="Connected").wait_for()
    print("Native WebSocket: hello, tree, state restore and reconnect passed", flush=True)
    page.close()


def main():
    args = argparse.ArgumentParser()
    args.add_argument("--require-webgpu", action="store_true")
    args.add_argument("--require-hardware-gpu", action="store_true", help="Also reject software/fallback adapters")
    args.add_argument("--skip-native", action="store_true")
    args.add_argument("--screenshot")
    options = args.parse_args()
    root = Path(__file__).resolve().parent
    if not (root / "dist/guava.wasm").is_file():
        raise SystemExit("Run npm ci and npm run build first")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(root / "dist")))
    threading.Thread(target=server.serve_forever, daemon=True).start()
    native = None
    with tempfile.TemporaryFile(mode="w+") as log:
        try:
            if not options.skip_native:
                with socket.socket() as reservation:
                    reservation.bind(("127.0.0.1", 0))
                    native_port = reservation.getsockname()[1]
                native = subprocess.Popen(["swift", "run", "--skip-build", "--package-path", str(root.parent / "Portable"),
                                           "GuavaUIDevToolsProbe", str(native_port)], stdout=log, stderr=log)
                deadline = time.monotonic() + 15
                while True:
                    try:
                        with socket.create_connection(("127.0.0.1", native_port), timeout=0.2):
                            break
                    except OSError:
                        if native.poll() is not None or time.monotonic() > deadline:
                            log.seek(0)
                            raise RuntimeError("Native probe failed; run swift build --package-path ../Portable first:\n" + log.read())
                        time.sleep(0.05)
            with sync_playwright() as playwright:
                executable = os.environ.get("GUAVA_CHROMIUM")
                strict_gpu = options.require_webgpu or options.require_hardware_gpu
                flags = ["--no-sandbox", "--enable-unsafe-webgpu"]
                if not strict_gpu:
                    flags.append("--use-angle=swiftshader")
                flags.extend(json.loads(os.environ.get("GUAVA_CHROMIUM_ARGS", "[]")))
                browser = playwright.chromium.launch(executable_path=executable, headless=True, args=flags)
                try:
                    base_url = f"http://127.0.0.1:{server.server_port}/"
                    preview_checks(browser, base_url, "canvas2d", None if strict_gpu else options.screenshot)
                    if options.require_hardware_gpu:
                        page = browser.new_page()
                        page.goto(base_url + "?renderer=webgpu", wait_until="networkidle")
                        page.wait_for_function("window.guavaDebug?.snapshot != null", timeout=30000)
                        info = page.evaluate("guavaDebug.gpuInfo")
                        assert info and info.get("isFallbackAdapter") is False and not info["lost"], info
                        adapter_name = " ".join(str(info.get(key, "")) for key in ("vendor", "architecture", "device", "description")).lower()
                        assert not any(name in adapter_name for name in ("swiftshader", "llvmpipe", "lavapipe", "software", "warp")), info
                        print("Hardware WebGPU adapter:", json.dumps(info), flush=True)
                        page.close()
                    preview_checks(browser, base_url, "webgpu" if strict_gpu else None,
                                   options.screenshot if strict_gpu else None, scale=2)
                    if native:
                        native_checks(browser, base_url, native_port)
                finally:
                    browser.close()
        finally:
            server.shutdown()
            server.server_close()
            if native:
                native.terminate()
                try:
                    native.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    native.kill()
                    native.wait()


if __name__ == "__main__":
    main()
