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
    for orientation, name in [(1, 'portrait'), (0, 'landscape')]:
        run(adb + ['shell', 'am', 'start', '-W', '-S', '-n', 'com.guava.probe/.MainActivity', '--ei', 'orientation', str(orientation)])
        pid = subprocess.check_output(list(map(str, adb + ['shell', 'pidof', 'com.guava.probe'])), text=True).strip()
        def logs():
            return subprocess.check_output(list(map(str, adb + ['logcat', '-d', '--pid=' + pid, '-s', 'GuavaAndroid:I', '*:S'])), text=True)
        # Wait for first present and check errors only from this app process.
        deadline = time.monotonic() + 10
        while 'PRESENT' not in logs() and time.monotonic() < deadline: time.sleep(0.2)
        before = logs().count('PRESENT')
        run(adb + ['shell', 'input', 'tap', '400', '500'])
        deadline = time.monotonic() + 5
        while logs().count('PRESENT') <= before and time.monotonic() < deadline: time.sleep(0.2)
        text = logs()
        if not before or text.count('PRESENT') <= before or 'FAIL' in text:
            raise ValueError(f'{name} surface/touch failed: {text}')
        (OUTPUT / f'app-{name}.log').write_text(text)
        with (OUTPUT / f'app-{name}.png').open('wb') as image:
            run(adb + ['exec-out', 'screencap', '-p'], stdout=image)
        # Home destroys the surface, and resuming must create and present again.
        run(adb + ['shell', 'input', 'keyevent', 'KEYCODE_HOME'])
        deadline = time.monotonic() + 5
        while 'CLOSE' not in logs() and time.monotonic() < deadline: time.sleep(0.2)
        before = logs().count('PRESENT')
        run(adb + ['shell', 'am', 'start', '-W', '-n', 'com.guava.probe/.MainActivity'])
        deadline = time.monotonic() + 10
        while logs().count('PRESENT') <= before and time.monotonic() < deadline: time.sleep(0.2)
        text = logs()
        if 'CLOSE' not in text or text.count('PRESENT') <= before or 'FAIL' in text:
            raise ValueError(f'{name} foreground recovery failed: {text}')
        (OUTPUT / f'app-{name}.log').write_text(text)
        results.append({'orientation': name, 'surface': True, 'touch': True, 'foregroundRecovery': True})
    # Restore sensor-driven orientation without changing any system setting.
    run(adb + ['shell', 'am', 'start', '-W', '-S', '-n', 'com.guava.probe/.MainActivity'])
    report = OUTPUT / 'app-smoke.json'; report.write_text(json.dumps(results, indent=2) + '\n')
    print(f'Android app lifecycle checks passed: {report}')


if __name__ == '__main__':
    main()
