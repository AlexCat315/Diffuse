"""Exercise real Swift rebuilds, state retention, and failed-build recovery."""
import os
from pathlib import Path
import re
import signal
import subprocess
import tempfile
import time
from playwright.sync_api import sync_playwright


def main():
    root = Path(__file__).resolve().parent
    source = root / "Sources/GuavaUIBrowserPrototype/main.swift"
    original = source.read_bytes()
    with tempfile.TemporaryFile(mode="w+") as log:
        process = subprocess.Popen(["python3", "dev.py", "--port", "0"], cwd=root,
                                   stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 120
            while True:
                log.seek(0); output = log.read()
                address = re.search(r"dev server: (http://127\.0\.0\.1:\d+)", output)
                if address:
                    break
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Development server did not start:\n" + output)
                time.sleep(0.2)
            with sync_playwright() as playwright:
                browser = playwright.chromium.launch(executable_path=os.environ.get("GUAVA_CHROMIUM"), headless=True, args=["--no-sandbox"])
                try:
                    page = browser.new_page()
                    page.goto(address[1] + "/?renderer=canvas2d", wait_until="domcontentloaded")
                    page.wait_for_function("window.guavaDebug?.snapshot != null", timeout=30000)
                    page.locator("#increment").click()
                    page.wait_for_function("guavaDebug.snapshot.count === 1")
                    first_url = page.url
                    # Let EventSource connect before changing a watched source.
                    page.wait_for_function("window.guavaDevConnected === true")
                    source.write_bytes(original + b"\n// development reload verification\n")
                    page.wait_for_url(lambda url: str(url) != first_url, timeout=60000)
                    page.wait_for_function("window.guavaDebug?.snapshot?.count === 1", timeout=30000)
                    second_url = page.url
                    page.wait_for_function("window.guavaDevConnected === true")
                    source.write_bytes(original + b"\nthis_is_not_valid_swift\n")
                    page.locator("pre").filter(has_text="error:").wait_for(timeout=60000)
                    assert page.url == second_url
                    page.locator("#increment").click()
                    page.wait_for_function("guavaDebug.snapshot.count === 2")
                    source.write_bytes(original)
                    page.wait_for_url(lambda url: str(url) != second_url, timeout=60000)
                    page.wait_for_function("window.guavaDebug?.snapshot?.count === 2", timeout=30000)
                    print("Development reload: real Swift rebuild, checkpoint retention, error overlay and recovery passed", flush=True)
                finally:
                    browser.close()
        finally:
            source.write_bytes(original)
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=10)


if __name__ == "__main__":
    main()
