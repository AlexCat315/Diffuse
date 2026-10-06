"""Local Swift/Wasm development server with complete-build reloads and SSE."""
import argparse
import http.server
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import threading
import time
import urllib.parse

ROOT = Path(__file__).resolve().parent
WATCH = [ROOT / "Sources", ROOT / "web", ROOT.parent / "Portable/Sources",
         ROOT.parent / "Text/Sources", ROOT.parent / "Text/Fonts", ROOT.parent / "Text/Package.swift",
         ROOT / "build_fonts.py",
         ROOT.parent / "DevTools", ROOT.parents[1] / "Engine/PlatformCore",
         ROOT / "Package.swift", ROOT.parent / "Portable/Package.swift", ROOT / "build.sh"]


def fingerprint():
    files = []
    for source in WATCH:
        files.extend(source.rglob("*") if source.is_dir() else [source])
    entries = []
    for path in files:
        if any(part.startswith(".") for part in path.relative_to(ROOT.parents[1]).parts):
            continue
        try:
            if path.is_file():
                info = path.stat(); entries.append((str(path), info.st_mtime_ns, info.st_size))
        except FileNotFoundError:
            pass  # A deletion during scanning is picked up on the next poll.
    return tuple(sorted(entries))


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == "/__guava_events":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            channel = queue.Queue(maxsize=8)
            with self.server.lock:
                self.server.listeners.add(channel)
            try:
                self.wfile.write(b": connected\n\n"); self.wfile.flush()
                while True:
                    try:
                        event = channel.get(timeout=15)
                        data = "data: " + json.dumps(event) + "\n\n"
                    except queue.Empty:
                        data = ": keepalive\n\n"
                    self.wfile.write(data.encode()); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                with self.server.lock:
                    self.server.listeners.discard(channel)
            return
        if path == "/":
            self.send_response(302)
            self.send_header("Location", "/build/" + self.server.revision + "/" + ("?" + urllib.parse.urlsplit(self.path).query if urllib.parse.urlsplit(self.path).query else ""))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        self.directory = str(ROOT / ".dev-builds")
        if not path.startswith("/build/"):
            self.send_error(404); return
        self.path = self.path[len("/build"):]
        super().do_GET()


def publish(server, event):
    with server.lock:
        for listener in server.listeners:
            try:
                listener.put_nowait(event)
            except queue.Full:
                pass


def build():
    revision = str(time.time_ns())
    destination = ROOT / ".dev-builds" / revision
    env = dict(os.environ, GUAVA_WASM_OUTPUT=str(destination))
    result = subprocess.run(["bash", "build.sh"], cwd=ROOT, env=env,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    print(result.stdout, flush=True)
    if result.returncode:
        shutil.rmtree(destination, ignore_errors=True)
        return None, result.stdout[-6000:]
    (destination / "dev-mode.json").write_text('{"enabled":true}')
    return revision, None


def watch(server):
    previous = fingerprint()
    while True:
        time.sleep(0.3)
        current = fingerprint()
        if current == previous:
            continue
        time.sleep(0.3)
        previous = fingerprint()
        publish(server, {"type": "building"})
        revision, error = build()
        if revision:
            server.revision = revision
            publish(server, {"type": "ready"})
        else:
            publish(server, {"type": "error", "message": error})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args()
    revision, error = build()
    if error:
        raise SystemExit("Initial build failed")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.revision = revision
    server.lock = threading.Lock()
    server.listeners = set()
    threading.Thread(target=watch, args=(server,), daemon=True).start()
    print(f"GuavaUI dev server: http://127.0.0.1:{server.server_port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
