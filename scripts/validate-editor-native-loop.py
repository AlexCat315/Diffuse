#!/usr/bin/env python3
"""Validate real Editor windows, MCP compilation/reload, playback, and export.

Runs both idle/event-driven and continuous frame loops on NativeRHI by default.
Use --renderer wgpu for the reference path. The disposable bundle,
project, trust decision, logs and transcript stay in a new temporary directory.
Use --renderer both to compare the two paused Editor window captures as well.
macOS currently provides the native editor TCP bridge used by this test.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
_spec = importlib.util.spec_from_file_location("crystal_rush_validation", ROOT / "scripts/validate-crystal-rush-mcp.py")
_shared = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_shared)
MCPClient = _shared.MCPClient
validate_bridge_connections = _shared.validate_bridge_connections


def executable(package, name, configuration="debug"):
    product_configuration = configuration.capitalize()
    for directory in (ROOT / package / f".build/out/Products/{product_configuration}",
                      ROOT / package / f".build/{configuration}"):
        candidate = directory / name
        if candidate.is_file():
            return candidate.resolve()
    raise FileNotFoundError(f"Build {package}'s {name} before running this validation")


def wait_for_bridge(child, port, log, renderer):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if child.poll() is not None:
            raise RuntimeError(log.read_text()[-8192:])
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                # Bridge startup can precede scene renderer initialization.
                startup = log.read_text()
                if renderer == "wgpu" or "NativeRenderer ready" in startup:
                    return
        except OSError:
            pass
        time.sleep(0.1)
    raise TimeoutError(f"The editor did not start its bridge and {renderer} renderer: {log.read_text()[-8192:]}")


def capture_window(port, destination):
    capture = subprocess.run(["swift", str(ROOT / "scripts/capture-editor-devtools.swift"),
                              str(port), str(destination)], capture_output=True, text=True, timeout=45)
    assert capture.returncode == 0, capture.stderr
    print(capture.stdout.strip(), flush=True)


def rendered_game(runtime, previous_frame):
    rendered = runtime["render"]
    return (rendered["viewport_valid"] and rendered["frame_index"] > previous_frame
            and rendered["visible_mesh_instances"] > 0 and rendered["draw_call_count"] > 0)


def record_timings(port, destination, frames):
    measured = subprocess.run(["swift", str(ROOT / "scripts/record-editor-timings.swift"),
                               str(port), str(destination), str(frames), "60"],
                              capture_output=True, text=True, timeout=45 + frames / 30)
    assert measured.returncode == 0, measured.stderr
    print(measured.stdout.strip(), flush=True)


def validate(directory, continuous, renderer, configuration="debug", timing_frames=0):
    directory.mkdir()
    editor = executable("Editor", "EditorApp", configuration)
    player = executable("Editor", "GuavaPlayer", configuration)
    server = executable("guava-mcp", "GuavaMCP")
    project = directory / "Crystal Rush"
    scripts = project / "Scripts"
    metadata = project / ".guava"
    scripts.mkdir(parents=True)
    metadata.mkdir()
    resources = ROOT / "Editor/Sources/EditorCore/Resources/ProjectTemplates"
    shutil.copy2(resources / "crystal-rush.swift.txt", scripts / "CrystalRush.swift")
    shutil.copy2(resources / "crystal-rush.scene.json", metadata / "editor-scene-manifest.json")
    shutil.copy2(resources / "crystal-rush.script-assets.json", metadata / "script-assets.json")

    bundle_id = f"org.guava.native-validation.{uuid.uuid4()}"
    bundle = directory / "GuavaNativeValidation.app"
    macos = bundle / "Contents/MacOS"
    macos.mkdir(parents=True)
    shutil.copy2(editor, macos / "GuavaNativeValidation")
    with (bundle / "Contents/Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleExecutable": "GuavaNativeValidation", "CFBundleName": "GuavaNativeValidation",
                      "CFBundleIdentifier": bundle_id, "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
                      "NSHighResolutionCapable": True}, output)
    bundled_resources = bundle / "Contents/Resources"
    bundled_resources.mkdir()
    products = editor.parent
    for resource in products.glob("*.bundle"):
        (bundled_resources / resource.name).symlink_to(resource)
    # Mirror the developer SDK layout that the editor already discovers.
    modules = products / "Modules" if (products / "Modules").is_dir() else products
    (macos / "Modules").symlink_to(modules)
    maps = products.parent.parent / "Intermediates.noindex/GeneratedModuleMaps"
    for module_map in list(maps.glob("C*.modulemap")) + list(products.glob("C*.build/module.modulemap")):
        name = module_map.name if module_map.name != "module.modulemap" else module_map.parent.stem + ".modulemap"
        (macos / name).symlink_to(module_map)

    state = directory / "editor-state"
    state.mkdir()
    # This is our generated test source, explicitly trusted in isolated user
    # state. Project files and MCP cannot grant themselves execution trust.
    (state / "script-workspace-trust.json").write_text(json.dumps({
        "version": 1, "trustedProjectPaths": [str(project), str(project.resolve())],
    }))
    with socket.socket() as bridge_probe, socket.socket() as devtools_probe:
        bridge_probe.bind(("127.0.0.1", 0))
        devtools_probe.bind(("127.0.0.1", 0))
        port = bridge_probe.getsockname()[1]
        devtools_port = devtools_probe.getsockname()[1]
    environment = dict(os.environ, GUAVA_MCP_PORT=str(port), GUAVA_EDITOR_STATE_DIRECTORY=str(state),
                       GUAVA_PLAYER_EXECUTABLE=str(player), GUAVAUI_FORCE_CONTINUOUS_FRAMES="1" if continuous else "0",
                       GUAVA_DEVTOOLS="1", GUAVA_DEVTOOLS_PORT=str(devtools_port), GUAVA_DEVTOOLS_AUTO_LOG_TAP="0")
    log = directory / "editor.log"
    with log.open("wb") as output:
        child = subprocess.Popen([str(macos / "GuavaNativeValidation"), "--project-dir", str(project),
                                  "--renderer", renderer],
                                 stdout=output, stderr=output, env=environment)
    client = None
    try:
        wait_for_bridge(child, port, log, renderer)
        if renderer != "wgpu":
            # Validate the renderer used by the actual application process;
            # successful simulation/MCP traffic alone cannot prove GPU startup.
            startup = log.read_text()
            assert "NativeRenderer ready" in startup, startup[-8192:]
            assert "[RHIWGPU]" not in startup, startup[-8192:]
        # The listener can accept connections before the first UI layout and
        # font rasterization finishes. Wait for a real window frame before
        # applying the bridge's normal interactive-response deadline.
        capture_window(devtools_port, directory / "startup-editor.jpg")
        validate_bridge_connections(port)
        client = MCPClient(server, environment)
        client.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                      "clientInfo": {"name": "native-editor-validation", "version": "1"}})
        info = client.tool("get_project_info")
        assert info["script_sdk_available"] and info["script_execution_trusted"], info
        assert info["entity_count"] == 1 and not info["pending_confirmation"], info
        client.tool("compile_scripts")
        source = client.tool("read_script", {"filename": "CrystalRush.swift"})
        changed = source["source"].replace('"phase": phase', '"phase": phase, "validation_generation": "native-loop"', 1)
        assert changed != source["source"]
        client.tool("write_script", {"filename": "CrystalRush.swift", "source": changed,
                                     "expected_sha256": source["sha256"]})
        client.tool("compile_scripts")
        client.tool("save_scene")
        previous_frame = client.tool("get_runtime_state")["render"]["frame_index"]
        client.tool("set_playback_state", {"state": "playing"})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            runtime = client.tool("get_runtime_state")
            if runtime["entity_count"] == 60 and runtime["scripts"] and rendered_game(runtime, previous_frame):
                break
            time.sleep(0.1)
        assert runtime["entity_count"] == 60 and runtime["unresolved_bindings"] == [], runtime
        assert runtime["scripts"][0]["values"]["phase"] == "ready", runtime
        assert runtime["scripts"][0]["values"]["validation_generation"] == "native-loop", runtime
        assert rendered_game(runtime, previous_frame), runtime
        if timing_frames:
            record_timings(devtools_port, directory / "playing-timings.json", timing_frames)
        client.tool("set_playback_state", {"state": "paused"})
        assert client.tool("get_project_info")["playback_state"] == "paused"
        capture_window(devtools_port, directory / "paused-editor.jpg")
        if timing_frames:
            record_timings(devtools_port, directory / "paused-timings.json", timing_frames)
        client.tool("set_playback_state", {"state": "stopped"})
        assert client.tool("get_project_info")["entity_count"] == 1
        previous_frame = client.tool("get_runtime_state")["render"]["frame_index"]
        client.tool("set_playback_state", {"state": "playing"})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            restarted = client.tool("get_runtime_state")
            if restarted["entity_count"] == 60 and rendered_game(restarted, previous_frame):
                break
            time.sleep(0.1)
        assert restarted["entity_count"] == 60, restarted
        assert rendered_game(restarted, previous_frame), restarted
        assert restarted["scripts"][0]["values"]["phase"] == "ready", restarted
        client.tool("set_playback_state", {"state": "stopped"})
        exported = client.tool("export_project")
        assert exported["runnable"], exported
        isolated_player_environment = dict(os.environ, PATH="/guava-no-toolchain")
        isolated_player_environment.pop("GUAVA_PROJECT_DIR", None)
        validation = subprocess.run([exported["executable"], "--validate-project", "--simulation-frames", "120"],
                                    capture_output=True, text=True, timeout=30, env=isolated_player_environment)
        assert validation.returncode == 0, validation.stderr
        application_log = log.read_text()
        for failure in ("native scene render failed:", "[EngineHost] NativeRHI renderer initialization failed:",
                        "render failed:"):
            assert failure not in application_log, application_log[-8192:]
        print(f"{'Continuous' if continuous else 'Event-driven'} {renderer} loop passed: compile, reload, Play/Pause/Stop, export", flush=True)
        print(validation.stdout.strip(), flush=True)
    finally:
        if client:
            (directory / "mcp-transcript.json").write_text(json.dumps(client.transcript, ensure_ascii=False, indent=2))
            client.close()
        child.terminate()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=5)
        # Delete only this run's dedicated preferences domain.
        subprocess.run(["defaults", "delete", bundle_id], capture_output=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("both", "event-driven", "continuous"), default="both")
    parser.add_argument("--renderer", choices=("native", "metal", "wgpu", "both"), default="native")
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--timing-frames", type=int, default=0,
                        help="Record presented window timings after 60 warmup frames; requires --mode continuous")
    parser.add_argument("--wgpu-first", action="store_true", help="Measure WGPU first with --renderer both")
    options = parser.parse_args()
    if options.timing_frames < 0 or (options.timing_frames and options.mode != "continuous"):
        parser.error("--timing-frames requires a positive count and --mode continuous")
    if sys.platform != "darwin":
        parser.error("The native editor TCP bridge currently requires macOS")
    directory = Path(tempfile.mkdtemp(prefix="guava-native-validation-"))
    print("Validation artifacts:", directory, flush=True)
    modes = [continuous for continuous in (False, True)
             if options.mode == "both" or (options.mode == "continuous") == continuous]
    renderers = ("native", "wgpu") if options.renderer == "both" else (options.renderer,)
    if options.wgpu_first:
        renderers = tuple(reversed(renderers))
    for renderer in renderers:
        renderer_directory = directory / renderer
        renderer_directory.mkdir()
        for continuous in modes:
            validate(renderer_directory / ("continuous" if continuous else "event-driven"),
                     continuous, renderer, options.configuration, options.timing_frames)
    if options.renderer == "both":
        for continuous in modes:
            mode = "continuous" if continuous else "event-driven"
            captures = [directory / renderer / mode / "paused-editor.jpg" for renderer in renderers]
            comparison = subprocess.run(["swift", str(ROOT / "scripts/compare-editor-captures.swift"),
                                         *map(str, captures)], capture_output=True, text=True, timeout=30)
            assert comparison.returncode == 0, comparison.stderr
            report = json.loads(comparison.stdout)
            (directory / f"{mode}-comparison.json").write_text(json.dumps(report, indent=2) + "\n")
            # Allow a small amount of dynamic status text. Component tests use
            # lossless readbacks; these JPEG mirrors cover the assembled window.
            assert report["meanAbsoluteRGBByteError"] < 0.25, report
            assert report["pixelsOverThree"] / report["pixelCount"] < 0.001, report
            print(f"{mode} Editor window comparison passed: {report}", flush=True)


if __name__ == "__main__":
    main()
