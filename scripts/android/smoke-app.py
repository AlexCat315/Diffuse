#!/usr/bin/env python3
"""Check Android surface creation, portrait/landscape, touch and foreground recovery."""
import argparse
import json
import subprocess
import time
from common import OUTPUT, run, sdk_root, adb_device


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android-sdk')
    parser.add_argument('--serial')
    args = parser.parse_args()
    adb = adb_device(sdk_root(args.android_sdk), args.serial)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    results = []
    def read():
        return json.loads(subprocess.check_output(list(map(str, adb + [
            'exec-out', 'run-as', 'com.guava.probe', 'cat', 'files/demo-state.json'])), stderr=subprocess.DEVNULL))
    def wait(predicate, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                snapshot = read()
                if predicate(snapshot): return snapshot
            except (ValueError, subprocess.CalledProcessError): pass
            time.sleep(0.2)
        raise ValueError('Android surface did not publish the expected rendered frame')
    for orientation, name in [(1, 'portrait'), (0, 'landscape')]:
        try: old = read().get('session')
        except (ValueError, subprocess.CalledProcessError): old = None
        run(adb + ['shell', 'am', 'start', '-W', '-S', '-n', 'com.guava.probe/.MainActivity',
                   '--ei', 'orientation', str(orientation), '--ez', 'snapshots', 'true'])
        pid = subprocess.check_output(list(map(str, adb + ['shell', 'pidof', 'com.guava.probe'])), text=True).strip()
        def logs():
            return subprocess.check_output(list(map(str, adb + ['logcat', '-d', '--pid=' + pid, '-s', 'GuavaAndroid:I', '*:S'])), text=True)
        # Published snapshots count actual successful submissions without adding
        # unconditional per-frame logging to the normal application.
        before = wait(lambda s: s.get('session') != old and s.get('frames', 0) > 0, 10)
        run(adb + ['shell', 'input', 'tap', '400', '500'])
        wait(lambda s: s.get('session') == before['session'] and s['frames'] > before['frames'], 5)
        text = logs()
        if 'FAIL' in text:
            raise ValueError(f'{name} surface/touch failed: {text}')
        (OUTPUT / f'app-{name}.log').write_text(text)
        with (OUTPUT / f'app-{name}.png').open('wb') as image:
            run(adb + ['exec-out', 'screencap', '-p'], stdout=image)
        # Home destroys the surface, and resuming must create and present again.
        run(adb + ['shell', 'input', 'keyevent', 'KEYCODE_HOME'])
        deadline = time.monotonic() + 5
        while 'CLOSE' not in logs() and time.monotonic() < deadline: time.sleep(0.2)
        before = read()
        run(adb + ['shell', 'am', 'start', '-W', '-n', 'com.guava.probe/.MainActivity', '--ez', 'snapshots', 'true'])
        wait(lambda s: s.get('session') == before['session'] and s['frames'] > before['frames'], 10)
        text = logs()
        if 'CLOSE' not in text or 'FAIL' in text:
            raise ValueError(f'{name} foreground recovery failed: {text}')
        (OUTPUT / f'app-{name}.log').write_text(text)
        results.append({'orientation': name, 'surface': True, 'touch': True, 'foregroundRecovery': True})
    # Restore sensor-driven orientation without changing any system setting.
    run(adb + ['shell', 'am', 'start', '-W', '-S', '-n', 'com.guava.probe/.MainActivity', '--ez', 'snapshots', 'true'])
    report = OUTPUT / 'app-smoke.json'; report.write_text(json.dumps(results, indent=2) + '\n')
    print(f'Android app lifecycle checks passed: {report}')


if __name__ == '__main__':
    main()
