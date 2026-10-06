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


def preview_checks(browser, base_url, renderer, screenshot=None):
    page = browser.new_page(viewport={"width": 1280, "height": 1100})
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
        const p=context.getImageData(60,260,1,1).data;
        return p[3]>200 && p[2]>p[0]+50;
    }"""
    page.wait_for_function(pixel_check, timeout=10000)
    page.locator("#surface").click(position={"x": 60, "y": 260})
    page.wait_for_function("guavaDebug.snapshot.count === 1")
    page.locator("#increment").click()
    page.wait_for_function("guavaDebug.snapshot.count === 2")
    rejected = page.evaluate("guavaDebug.request({type:'state.restore',id:90,payload:{count:-1,dark:'true'}})")
    assert rejected["type"] == "state.restore.err" and rejected["id"] == 90
    assert page.evaluate("guavaDebug.snapshot.count") == 2
    selected = page.evaluate("guavaDebug.request({type:'select.node',id:91,payload:{id:'2'}})")
    assert selected["type"] == "select.node.ok"
    page.wait_for_function("guavaDebug.snapshot.tree.root.children.find(n=>n.id==='2').flags.hasBorder")
    page.locator("#theme").click()
    page.wait_for_function("guavaDebug.snapshot.dark === true")
    inspector = page.frame_locator("#inspector")
    inspector.locator("#status").filter(has_text="Connected").wait_for()
    inspector.locator("#tree").filter(has_text="browser.root").wait_for()
    inspector.locator("#captureState").click()
    page.wait_for_function("document.querySelector('#inspector').contentDocument.querySelector('#stateSnapshot').value.includes('true')")
    captured = json.loads(inspector.locator("#stateSnapshot").input_value())
    assert captured == {"count": "2", "dark": "true"}
    page.locator("#reset").click()
    page.wait_for_function("guavaDebug.snapshot.count === 0")
    inspector.locator("#restoreState").click()
    page.wait_for_function("guavaDebug.snapshot.count === 2")
    inspector.locator("#disconnect").click()
    inspector.locator("#connect").click()
    inspector.locator("#status").filter(has_text="Connected").wait_for()
    page.set_viewport_size({"width": 600, "height": 1100})
    page.wait_for_function("guavaDebug.snapshot.width < 600")
    assert page.evaluate("guavaDebug.snapshot.count") == 2
    assert not errors, errors
    if screenshot:
        page.set_viewport_size({"width": 1280, "height": 1100})
        page.screenshot(path=screenshot, full_page=True)
    print(f"Wasm {page.evaluate('guavaDebug.backend')}: pixels, pointer input, state, Inspector, reconnect and resize passed", flush=True)
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
                browser = playwright.chromium.launch(executable_path=executable, headless=True,
                    args=["--no-sandbox", "--enable-unsafe-webgpu", "--use-angle=swiftshader"])
                try:
                    base_url = f"http://127.0.0.1:{server.server_port}/"
                    preview_checks(browser, base_url, "canvas2d")
                    preview_checks(browser, base_url, "webgpu" if options.require_webgpu else None, options.screenshot)
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
