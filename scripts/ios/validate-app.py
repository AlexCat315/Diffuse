#!/usr/bin/env python3
"""Launch the shared UI starter and reject an empty simulator frame."""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time


def simctl(*args, timeout=60):
    return subprocess.check_output(["xcrun", "simctl", *args], text=True, timeout=timeout).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--simulator", help="Reuse a supplied simulator; otherwise create an isolated device")
    args = parser.parse_args()
    app = args.app.resolve()
    identifier = plistlib.loads((app / "Info.plist").read_bytes())["CFBundleIdentifier"]
    owned = args.simulator is None
    simulator = args.simulator
    if owned:
        runtimes = json.loads(simctl("list", "runtimes", "--json"))["runtimes"]
        available = [r for r in runtimes if r.get("isAvailable") and ".iOS-" in r["identifier"]]
        runtime = max(available, key=lambda r: tuple(map(int, r["version"].split("."))))
        simulator = simctl("create", "GuavaStudio UI validation", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", runtime["identifier"])
    try:
        simctl("bootstatus", simulator, "-b", timeout=300)
        simctl("install", simulator, str(app))
        simctl("launch", "--terminate-running-process", simulator, identifier)
        with tempfile.TemporaryDirectory(prefix="guava-ios-frame-") as directory:
            screenshot = Path(directory) / "frame.png"
            # Wait for initial font/pipeline preparation and the first display tick.
            time.sleep(5)
            simctl("io", simulator, "screenshot", str(screenshot))
            subprocess.run(["swift", str(Path(__file__).with_name("FrameCheck.swift")), str(screenshot)], check=True, timeout=60)
        print("PASS iOS application rendered content")
    finally:
        if owned:
            subprocess.run(["xcrun", "simctl", "shutdown", simulator], check=False, timeout=60)
            subprocess.run(["xcrun", "simctl", "delete", simulator], check=False, timeout=60)


if __name__ == "__main__":
    main()
