#!/usr/bin/env python3
"""Create and validate Crystal Rush through the real Guava MCP stdio server.

The only initial file is an empty scene. Source writes, builds, scene drafts,
script attachment, save, play inspection and export all use MCP tools.
"""
import argparse
import json
import os
from pathlib import Path
import selectors
import socket
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]


class MCPClient:
    def __init__(self, executable, environment):
        self.process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, env=environment)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.buffer = b""
        self.sequence = 0
        self.transcript = []

    def request(self, method, params=None):
        self.sequence += 1
        request = {"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params or {}}
        self.process.stdin.write(json.dumps(request, ensure_ascii=False).encode() + b"\n")
        self.process.stdin.flush()
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                message = json.loads(line)
                if message.get("id") != self.sequence:
                    continue
                self.transcript.append({"request": request, "response": message})
                if "error" in message:
                    raise RuntimeError(message["error"])
                return message["result"]
            if self.selector.select(timeout=min(1, max(0, deadline - time.monotonic()))):
                chunk = os.read(self.process.stdout.fileno(), 65536)
                if not chunk:
                    raise RuntimeError("MCP server exited before responding")
                self.buffer += chunk
        raise TimeoutError(method)

    def tool(self, name, arguments=None):
        result = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        text = result["content"][0]["text"]
        if result.get("isError"):
            raise RuntimeError(f"{name}: {text}")
        value = json.loads(text)
        if value.get("ok") is False:
            raise RuntimeError(f"{name}: {value}")
        return value

    def capability(self, identifier, arguments):
        search = self.tool("search_capabilities", {"query": identifier})
        item = next(c for c in search["capabilities"] if c["id"] == identifier)
        return self.tool(item["tool_name"], arguments)

    def submit(self, draft, summary):
        before = self.tool("get_project_info")["scene_revision"]
        result = self.tool("submit_plan", {"summary": summary, "draft_ids": [draft["draft_id"]]})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            info = self.tool("get_project_info")
            if not info["pending_confirmation"] and info["scene_revision"] > before:
                return result
            time.sleep(0.1)
        raise RuntimeError("Scene preview was not applied by the opt-in headless reviewer")

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            self.process.wait(timeout=5)
        self.selector.close()


def validate_bridge_connections(port):
    """Real concurrent TCP clients, partial frames, pipelining and recovery."""
    request = json.dumps({"action": "project_tool", "tool_name": "get_project_info", "arguments": {}}).encode() + b"\n"
    with socket.create_connection(("127.0.0.1", port), timeout=5) as first, socket.create_connection(("127.0.0.1", port), timeout=5) as second:
        first_file, second_file = first.makefile("rb"), second.makefile("rb")
        try:
            first.sendall(request[:13])
            second.sendall(request)
            assert json.loads(second_file.readline())["ok"] is True
            first.sendall(request[13:] + request)
            assert json.loads(first_file.readline())["ok"] is True
            assert json.loads(first_file.readline())["ok"] is True
            second.sendall(b"{malformed}\n" + request)
            assert json.loads(second_file.readline())["ok"] is False
            assert json.loads(second_file.readline())["ok"] is True
        finally:
            first_file.close(); second_file.close()
    print("Editor bridge passed: simultaneous clients, fragmented and pipelined frames, malformed request recovery", flush=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--project", type=Path, default=ROOT / "examples/CrystalRush")
    parser.add_argument("--source-file", type=Path)
    options = parser.parse_args()
    project = options.project.resolve()
    source = (options.source_file or ROOT / "examples/CrystalRush/Scripts/CrystalRush.swift").read_text()
    project.mkdir(parents=True, exist_ok=True)
    scene = project / ".guava/editor-scene-manifest.json"
    scene.parent.mkdir(exist_ok=True)
    if not scene.exists():
        scene.write_text(json.dumps({"schemaVersion": 5, "revision": 0, "entityCount": 0, "roots": []}))
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    environment = dict(os.environ, GUAVA_MCP_PORT=str(port))
    editor = ROOT / "Editor/.build/out/Products/Debug/EditorApp"
    player = ROOT / "Editor/.build/out/Products/Debug/GuavaPlayer"
    server = ROOT / "guava-mcp/.build/out/Products/Debug/GuavaMCP"
    # Native SwiftPM uses .build/debug instead of Xcode's Products directory.
    for name, package in (("editor", "Editor"), ("player", "Editor"), ("server", "guava-mcp")):
        path = locals()[name]
        if not path.exists():
            replacement = ROOT / package / ".build/debug" / path.name
            if name == "editor": editor = replacement
            elif name == "player": player = replacement
            else: server = replacement
    environment["GUAVA_PLAYER_EXECUTABLE"] = str(player)
    log = project / "validation/editor.log"
    log.parent.mkdir(exist_ok=True)
    with log.open("wb") as output:
        process = subprocess.Popen([str(editor), "--mcp-headless", "--project-dir", str(project),
                                    "--trust-project-scripts", "--approve-scene-edits"],
                                   stdout=output, stderr=output, env=environment)
    client = None
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(log.read_text()[-8192:])
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.1)
        else: raise TimeoutError("Headless editor did not bind its loopback bridge")
        validate_bridge_connections(port)
        client = MCPClient(server, environment)
        handshake = client.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                                  "clientInfo": {"name": "crystal-rush-validation", "version": "1"}})
        print("MCP initialized:", handshake["protocolVersion"], flush=True)
        tools = client.request("tools/list")["tools"]
        assert any(t["name"] == "write_script" for t in tools)
        info = client.tool("get_project_info")
        print("Project connected; trusted:", info["script_execution_trusted"], flush=True)
        arguments = {"filename": "CrystalRush.swift", "source": source}
        if (project / "Scripts/CrystalRush.swift").exists():
            arguments["expected_sha256"] = client.tool("read_script", {"filename": "CrystalRush.swift"})["sha256"]
        written = client.tool("write_script", arguments)
        print("Source written through MCP:", written["identifier"], flush=True)
        build = client.tool("compile_scripts")
        print("Scripts compiled:", build, flush=True)
        entities = client.capability("scene.get_entities", {})["scene"]["entities"]
        controller = next((e for e in entities if e["name"] == "Game Controller"), None)
        if controller is None:
            draft = client.capability("scene.spawn_entity", {"label": "Game Controller", "spawn_kind": "empty"})
            client.submit(draft, "Create the Crystal Rush game controller")
            entities = client.capability("scene.get_entities", {})["scene"]["entities"]
            controller = next(e for e in entities if e["name"] == "Game Controller")
        draft = client.capability("scene.set_script_property", {
            "entity_id": controller["id"], "script_identifier": written["identifier"],
            "script_property_name": "title", "script_property_value": "Crystal Rush",
        })
        client.submit(draft, "Attach the compiled gameplay with its stable script identifier")
        saved = client.tool("save_scene")
        print("Scene saved:", saved["path"], flush=True)
        client.tool("set_playback_state", {"state": "playing"})
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            runtime = client.tool("get_runtime_state")
            if runtime["scripts"]:
                break
            time.sleep(0.1)
        assert runtime["entity_count"] > 50, runtime
        assert runtime["unresolved_bindings"] == [], runtime
        assert runtime["scripts"][0]["values"]["phase"] == "ready", runtime
        print("Live gameplay state:", runtime, flush=True)
        client.tool("set_playback_state", {"state": "stopped"})
        exported = client.tool("export_project")
        assert exported["runnable"], exported
        print("Runnable game:", exported["executable"], flush=True)
        validation_environment = dict(os.environ, PATH="/guava-no-toolchain")
        validation_environment.pop("GUAVA_PROJECT_DIR", None)
        validation = subprocess.run([exported["executable"], "--validate-project", "--simulation-frames", "120"],
                                    capture_output=True, text=True, timeout=30, env=validation_environment)
        assert validation.returncode == 0, validation.stderr
        print(validation.stdout.strip(), flush=True)
        (project / "validation/mcp-transcript.json").write_text(json.dumps(client.transcript, ensure_ascii=False, indent=2))
    finally:
        if client:
            (project / "validation/mcp-transcript.json").write_text(json.dumps(client.transcript, ensure_ascii=False, indent=2))
            client.close()
        process.terminate()
        try: process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


if __name__ == "__main__":
    main()
