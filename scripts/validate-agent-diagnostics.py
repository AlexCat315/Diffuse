#!/usr/bin/env python3
"""Exercise real stdio MCP -> portable TCP transport -> headless Editor tools."""
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def executable(package, name):
    for relative in (f"{package}/.build/out/Products/Debug/{name}", f"{package}/.build/debug/{name}"):
        path = ROOT / relative
        if path.is_file():
            return path
    raise RuntimeError(f"Build {package} first")


def check():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
    environment = dict(os.environ, GUAVA_MCP_PORT=str(port))
    with tempfile.TemporaryDirectory(prefix="guava-agent-diagnostics-") as directory:
        with open(Path(directory) / "editor.log", "w") as log:
            editor = subprocess.Popen([str(executable("Editor", "EditorApp")), "--mcp-headless", "--project-dir", directory],
                                      env=environment, stdout=log, stderr=log)
            mcp = None
            try:
                deadline = time.monotonic() + 20
                while True:
                    if editor.poll() is not None:
                        raise RuntimeError((Path(directory) / "editor.log").read_text())
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=.2):
                            break
                    except OSError:
                        if time.monotonic() >= deadline:
                            raise RuntimeError("Editor transport did not become ready")
                        time.sleep(.05)
                mcp = subprocess.Popen([str(executable("GuavaMcp", "GuavaMCP"))], env=environment,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log, text=True)
                request_id = 0

                def request(method, params=None):
                    nonlocal request_id
                    request_id += 1
                    message = {"jsonrpc": "2.0", "id": request_id, "method": method}
                    if params is not None:
                        message["params"] = params
                    mcp.stdin.write(json.dumps(message) + "\n")
                    mcp.stdin.flush()
                    while True:
                        if not select.select([mcp.stdout], [], [], 10)[0]:
                            raise RuntimeError(f"MCP request timed out: {method}")
                        response = json.loads(mcp.stdout.readline())
                        if response.get("id") == request_id:
                            assert "error" not in response, response
                            return response["result"]

                def tool(name, arguments=None):
                    return request("tools/call", {"name": name, "arguments": arguments or {}})

                request("initialize", {"protocolVersion": "2025-11-25"})
                definitions = request("tools/list")["tools"]
                assert "query_ui_nodes" in {item["name"] for item in definitions}
                report = tool("get_diagnostics")
                assert report["isError"] is False, report
                assert report["structuredContent"]["uiAvailable"] is False
                assert report["structuredContent"]["frameSampleCount"] == 0
                assert isinstance(report["structuredContent"]["issues"], list)
                metadata = tool("list_skills")["structuredContent"]["data"]
                assert metadata[0]["name"] == "ui-diagnostics"
                guide = tool("read_skill", {"name": "ui-diagnostics"})["structuredContent"]["data"]["instructions"]
                prompt = request("prompts/get", {"name": "ui-diagnostics"})["messages"][0]["content"]["text"]
                assert guide == prompt
                missing = tool("query_ui_nodes")
                assert missing["isError"] is True and "unavailable" in missing["content"][0]["text"]
                assert tool("get_console_messages")["isError"] is False
                mcp.stdin.close()
                assert mcp.wait(timeout=10) == 0
                print("Agent diagnostics passed: stdio MCP, TCP bridge, domain report, shared skills, and unavailable UI")
            finally:
                for process in (mcp, editor):
                    if process is not None and process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()


if __name__ == "__main__":
    check()
