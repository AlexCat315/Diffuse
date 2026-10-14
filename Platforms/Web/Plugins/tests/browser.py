#!/usr/bin/env python3
"""Real browser gate: native-validated Component -> Jco -> isolated Worker."""
import argparse
import functools
import http.server
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import sys
from playwright.sync_api import sync_playwright


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    args = parser.parse_args()
    package = Path(__file__).resolve().parents[1]
    root = package.parents[2]
    with tempfile.TemporaryDirectory(prefix="guava-web-plugin-") as temporary:
        web = Path(temporary)
        shutil.copytree(package / "src/runtime", web / "runtime")
        (web / "index.html").write_text('<!doctype html><title>Guava plugin runtime gate</title>')
        subprocess.run([sys.executable, str(root / "Engine/Validation/Plugins/prepare.py"),
                        "--probe", str(args.probe.resolve()), "--output", str(web)], check=True)
        for name in ["reader", "scene-query", "infinite"]:
            subprocess.run(["node", str(package / "src/packaging/entry.js"), str(web / (name + ".guavaplugin")),
                            str(web / name), str(args.host.resolve())], check=True, stdout=subprocess.DEVNULL)
        # The application publishes this catalog from its trusted build output,
        # separately from user-uploaded plugin data.
        catalog = {name: hashlib.sha256((web / name / "plugin.web.json").read_bytes()).hexdigest()
                   for name in ["reader", "scene-query", "infinite"]}
        (web / "catalog.json").write_text(json.dumps(catalog))
        handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(web))
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with sync_playwright() as playwright:
                options = {"headless": True}
                if os.environ.get("GUAVA_CHROMIUM"):
                    options["executable_path"] = os.environ["GUAVA_CHROMIUM"]
                browser = playwright.chromium.launch(**options)
                page = browser.new_page()
                page.goto(f"http://127.0.0.1:{server.server_port}/")
                result = page.evaluate("""async () => {
                  const { WebPluginSession } = await import('/runtime/session.js');
                  const check = (ok, name) => { if (!ok) throw Error(name); };
                  const rejects = async (call, name) => { try { await call(); } catch { return; } throw Error(name); };
                  const catalog = await (await fetch('/catalog.json')).json();
                  const open = async name => { const url = `/${name}/plugin.web.json`; const integrity = catalog[name]; const info = await WebPluginSession.inspect(url, integrity); return WebPluginSession.open(url, {integrity, authorization: info.authorization}); };
                  const reader = await open('reader');
                  check((await reader.prepare('safe.reader.inspect', {enabled: true})).value === true, 'read true');
                  check((await reader.prepare('safe.reader.inspect', {enabled: false})).value === false, 'fresh store false');
                  await rejects(() => reader.prepare('safe.reader.inspect', {enabled: 1}), 'typed input');
                  await rejects(() => reader.prepare('other.inspect', {enabled: true}), 'capability grant');
                  await rejects(() => WebPluginSession.open('/reader/plugin.web.json', {integrity: catalog.reader, authorization: 'changed'}), 'authorization');
                  const query = await open('scene-query');
                  await rejects(() => query.prepare('safe.reader.inspect', {enabled: true}), 'missing query');
                  const snapshot = { sceneRevision: 42, values: {'guava:scene/query': {entities: [], revision: 42}} };
                  const value = (await query.prepare('safe.reader.inspect', {enabled: true}, {snapshot})).value;
                  check(value.revision === 42 && value.entities.length === 0, 'query snapshot');
                  const loop = await open('infinite');
                  const start = performance.now();
                  await rejects(() => loop.prepare('safe.reader.loop', {enabled: true}, {timeoutMilliseconds: 250}), 'worker deadline');
                  check(performance.now() - start < 2000, 'main thread remains responsive');
                  check((await reader.prepare('safe.reader.inspect', {enabled: true})).value === true, 'recovery after timeout');
                  const controller = new AbortController();
                  const cancelled = loop.prepare('safe.reader.loop', {enabled: true}, {signal: controller.signal});
                  controller.abort(); await rejects(() => cancelled, 'cancellation');
                  return 'PASS read, fresh instance, strict input, authority, query permission, Worker timeout, cancellation, recovery';
                }""")
                print(result)
                # Changing the executable JS after approval must be detected before import.
                with (web / "reader/component.js").open("a") as stream:
                    stream.write("\nthrow Error('tampered');\n")
                page.evaluate("""async () => {
                  const { WebPluginSession } = await import('/runtime/session.js');
                  const integrity = (await (await fetch('/catalog.json')).json()).reader;
                  const info = await WebPluginSession.inspect('/reader/plugin.web.json', integrity);
                  try { await WebPluginSession.open('/reader/plugin.web.json', {integrity, authorization: info.authorization}); }
                  catch (error) { if (String(error).includes('integrity')) return; throw error; }
                  throw Error('Tampered code was accepted');
                }""")
                print("PASS asset tampering rejected before execution")
                browser.close()
        finally:
            server.shutdown()


if __name__ == "__main__":
    main()
