#!/usr/bin/env python3
"""Verify a running Profile app's Java/JNI/Swift journal and lifecycle flush."""
import argparse
import json
from pathlib import Path
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path, help="Application launched by guava run --android --profile --devtools")
    args = parser.parse_args()
    sessions = [json.loads(path.read_text()) for path in (args.project / ".guava/build/devtools").glob("*/session.json")]
    sessions = [session for session in sessions if session["platform"] == "android"]
    assert len(sessions) == 1, "Expected one live Android session"
    session = sessions[0]
    package = session["application"]["id"]
    pid = session["runtime"]["pid"]
    device = session["device"]
    adb = [device["adb"], "-s", device["serial"]]

    def shell(*arguments):
        return subprocess.check_output(adb + ["shell", *arguments], text=True)

    def records():
        paths = shell("run-as", package, "find", "files/logs", "-name", "events.jsonl").splitlines()
        result = []
        for path in paths:
            data = subprocess.check_output(adb + ["exec-out", "run-as", package, "cat", path])
            current = [json.loads(line) for line in data.splitlines()]
            current = [record for record in current if record["process"]["pid"] == pid]
            assert [record["sequence"] for record in current] == sorted(record["sequence"] for record in current)
            result.extend(current)
        return result

    initial = records()
    assert initial, "No application journal"
    assert len({record["process"]["runID"] for record in initial}) == 1, "Startup logs kept a provisional run ID"
    assert any(record["label"] == "com.guava.engine.rhi" for record in initial)
    java = [record for record in initial if record["metadata"].get("origin") == "java"]
    assert java and all(record["location"]["file"] == "RuntimeLog.java" and record["location"]["source"] == "JNI" for record in java)
    sequence = max(record["sequence"] for record in initial)
    shell("input", "keyevent", "KEYCODE_HOME")
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            flushed = records()
            if any(record["sequence"] > sequence and record["message"] == "Activity paused" for record in flushed):
                break
            time.sleep(0.05)
        else:
            raise AssertionError("onPause did not flush the Java lifecycle record")
    finally:
        shell("am", "start", "-n", package + "/com.guava.probe.MainActivity")
    print(json.dumps({"pid": pid, "runID": initial[0]["process"]["runID"], "records": len(flushed),
                      "modules": sorted({record["label"] for record in flushed}), "javaJNI": True, "pauseFlush": True}, indent=2))


if __name__ == "__main__":
    main()
