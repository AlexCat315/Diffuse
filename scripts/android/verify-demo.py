#!/usr/bin/env python3
"""Validate the actual SharedCounter APK: pixels, touch, Compose, IME and recreation (requires Pillow)."""
import argparse
import hashlib
import json
import shlex
import subprocess
import tempfile
import time
from pathlib import Path
from PIL import Image
from common import OUTPUT, run, sdk_root, adb_device


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--android-sdk')
    parser.add_argument('--serial')
    args = parser.parse_args()
    adb = adb_device(sdk_root(args.android_sdk), args.serial)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix='demo-run-', dir=OUTPUT))
    checkpoints = []

    def read():
        data = subprocess.check_output(list(map(str, adb + ['exec-out', 'run-as', 'com.guava.probe', 'cat', 'files/demo-state.json'])), stderr=subprocess.DEVNULL)
        return json.loads(data)

    def wait(predicate, description):
        deadline = time.monotonic() + 15
        last = None
        while time.monotonic() < deadline:
            try:
                last = read()
                if predicate(last):
                    checkpoints.append({'check': description, 'snapshot': last})
                    print('PASS', description, flush=True)
                    return last
            except (subprocess.CalledProcessError, ValueError):
                pass
            time.sleep(0.2)
        raise ValueError(f'{description}: timed out; latest state={last}')

    def shell(*arguments):
        run(adb + ['shell', shlex.join(map(str, arguments))])

    def action(name, text=None):
        arguments = ['am', 'broadcast', '-a', 'com.guava.probe.DEMO_INPUT', '-p', 'com.guava.probe',
                     '--es', 'demoAction', name]
        if text is not None: arguments += ['--es', 'text', text]
        shell(*arguments)

    def center(snapshot, name):
        control, surface, scale = snapshot['controls'][name], snapshot['surface'], snapshot['scale']
        return [round(surface['x'] + (control['x'] + control['width'] / 2) * scale),
                round(surface['y'] + (control['y'] + control['height'] / 2) * scale)]

    def tap(snapshot, name):
        shell('input', 'tap', *center(snapshot, name))

    def screenshot(name):
        path = directory / f'{name}.png'
        with path.open('wb') as output: run(adb + ['exec-out', 'screencap', '-p'], stdout=output)
        return Image.open(path).convert('RGB')

    def counter_pixels(image, snapshot):
        bounds, surface, scale = snapshot['controls']['counter.value'], snapshot['surface'], snapshot['scale']
        x, y = surface['x'] + bounds['x'] * scale, surface['y'] + bounds['y'] * scale
        crop = image.crop((round(x), round(y), round(x + min(160, bounds['width']) * scale), round(y + bounds['height'] * scale)))
        pixels = crop.tobytes()
        ink = sum(1 for r, g, b in zip(pixels[0::3], pixels[1::3], pixels[2::3]) if r < 100 and g < 120 and b < 160)
        if ink < 100: raise ValueError(f'Counter glyphs are absent from screenshot: {ink} ink pixels')
        return hashlib.sha256(crop.tobytes()).hexdigest()

    try: old = read().get('session')
    except (ValueError, subprocess.CalledProcessError): old = None
    shell('am', 'start', '-W', '-S', '-n', 'com.guava.probe/.MainActivity', '--ei', 'orientation', 0, '--es', 'mode', 'counter', '--ez', 'snapshots', 'true')
    initial = wait(lambda s: s.get('session') != old and s['state'] == {'count': '0', 'dark': 'false', 'note': ''}, 'fresh shared Compose scene')
    assert initial['typography']['fonts'] >= 2 and initial['typography']['missingGlyphs'] == 0
    assert initial['typography']['atlasPixels'] > 1000 and initial['indices'] > 1000
    zero = counter_pixels(screenshot('counter-zero'), initial)
    tap(initial, 'counter.increment')
    one = wait(lambda s: s['state']['count'] == '1', 'touch increments State')
    assert counter_pixels(screenshot('counter-one'), one) != zero, 'State changed without changing the displayed glyph'
    tap(one, 'counter.increment')
    two = wait(lambda s: s['state']['count'] == '2', 'recomposition preserves button routes')
    # A captured drag released outside must not invoke the click action.
    shell('input', 'swipe', *center(two, 'counter.increment'), 2, two['surface']['y'] + 4, 300)
    time.sleep(0.3)
    assert read()['state']['count'] == '2'
    tap(two, 'counter.theme')
    dark = wait(lambda s: s['state']['dark'] == 'true', 'theme recomposes')
    image = screenshot('dark-theme')
    x, y = dark['surface']['x'] + 4, dark['surface']['y'] + 4
    assert max(image.getpixel((x, y))) < 80, 'Theme state changed without painting a dark background'
    tap(dark, 'counter.note')
    focused = wait(lambda s: s.get('focused') == 'counter.note', 'GuavaUI note receives focus')
    # Verify that the real IME is bound to our view, then inject physical keys.
    # Some IMEs keep the word in their candidate window until Space selects it.
    ime = subprocess.check_output(list(map(str, adb + ['shell', 'dumpsys', 'input_method'])), text=True)
    assert 'connection=com.guava.probe.DemoInputConnection' in ime and 'mInputShown=true' in ime
    shell('input', 'text', 'Vulkan')
    deadline = time.monotonic() + 2
    while not read()['state']['note'] and time.monotonic() < deadline: time.sleep(0.2)
    if not read()['state']['note']: shell('input', 'keyevent', 'KEYCODE_SPACE')
    entered = wait(lambda s: s['state']['note'] in ['Vulkan', 'Vulkan '], 'active Android IME commits injected keys')
    if entered['state']['note'].endswith(' '):
        action('delete')
        wait(lambda s: s['state']['note'] == 'Vulkan', 'remove IME word separator')
    action('compose', '你好')
    wait(lambda s: s['preedit'] == '你好' and s['state']['note'] == 'Vulkan', 'IME composition remains transient')
    action('compose', '')
    wait(lambda s: not s['preedit'] and s['state']['note'] == 'Vulkan', 'IME composition cancellation')
    action('compose', '你好')
    wait(lambda s: s['preedit'] == '你好', 'IME composition replacement')
    action('commit', '你好')
    wait(lambda s: s['state']['note'] == 'Vulkan你好' and not s['preedit'], 'IME commits Unicode once')
    action('commit', '🚀')
    wait(lambda s: s['state']['note'] == 'Vulkan你好🚀', 'JNI preserves UTF-16 surrogate pairs')
    action('delete')
    wait(lambda s: s['state']['note'] == 'Vulkan你好', 'backspace removes one Unicode grapheme')
    action('compose', 'e\u0301')
    wait(lambda s: s['preedit'] == 'e\u0301', 'combining mark preedit')
    action('finish')
    wait(lambda s: s['state']['note'] == 'Vulkan你好e\u0301' and not s['preedit'], 'finishComposingText commits once')
    action('delete')
    wait(lambda s: s['state']['note'] == 'Vulkan你好', 'backspace preserves grapheme boundaries')
    action('compose', '未提交')
    current = wait(lambda s: s['preedit'] == '未提交', 'pending text before recreation')
    expected = current['state']
    action('recreate')
    recreated = wait(lambda s: s['session'] == current['session'] and s['frames'] > current['frames'] and s['state'] == expected and not s['preedit'], 'Activity recreation retains scene and clears transient input')
    shell('input', 'keyevent', 'KEYCODE_HOME')
    time.sleep(0.5)
    shell('am', 'start', '-W', '-n', 'com.guava.probe/.MainActivity', '--ez', 'snapshots', 'true')
    resumed = wait(lambda s: s['session'] == recreated['session'] and s['frames'] > recreated['frames'] and s['state'] == expected, 'foreground restores surface and demo state')
    shell('am', 'start', '-W', '-n', 'com.guava.probe/.MainActivity', '--ei', 'orientation', 1, '--ez', 'snapshots', 'true')
    portrait = wait(lambda s: s['height'] > s['width'] and s['state'] == expected, 'portrait relayout retains demo state')
    screenshot('portrait')
    shell('am', 'start', '-W', '-n', 'com.guava.probe/.MainActivity', '--ei', 'orientation', 0, '--ez', 'snapshots', 'true')
    landscape = wait(lambda s: s['width'] > s['height'] and s['state'] == expected, 'landscape relayout retains demo state')
    tap(landscape, 'counter.reset')
    reset = wait(lambda s: s['state']['count'] == '0' and s['state']['note'] == expected['note'], 'reset changes only counter')
    assert reset['typography']['missingGlyphs'] == 0, reset['typography']
    time.sleep(0.8)
    assert read()['frames'] == reset['frames'], 'Idle scene keeps submitting GPU frames'
    screenshot('landscape')
    # Restore sensor orientation after the explicit orientation checks.
    shell('am', 'start', '-W', '-n', 'com.guava.probe/.MainActivity', '--ei', 'orientation', -1, '--ez', 'snapshots', 'true')
    wait(lambda s: s['state']['count'] == '0' and s['state']['note'] == expected['note'], 'sensor orientation restored')
    pid = subprocess.check_output(list(map(str, adb + ['shell', 'pidof', 'com.guava.probe'])), text=True).strip()
    log = subprocess.check_output(list(map(str, adb + ['logcat', '-d', '--pid=' + pid, '-s', 'GuavaAndroid:I', '*:S'])), text=True)
    (directory / 'app.log').write_text(log)
    assert 'FAIL' not in log, log
    (directory / 'report.json').write_text(json.dumps({'passed': True, 'checks': checkpoints}, ensure_ascii=False, indent=2) + '\n')
    print(f'SharedCounter Android checks passed: {directory / "report.json"}')


if __name__ == '__main__':
    main()
