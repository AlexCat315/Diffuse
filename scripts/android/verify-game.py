#!/usr/bin/env python3
"""Exercise the exported CrystalRush APK: native scene, script HUD, touch gameplay and lifecycle."""
import argparse
import json
import re
import shlex
import subprocess
import tempfile
import time
import xml.etree.ElementTree as ET
from pathlib import Path
from PIL import Image, ImageStat
from common import OUTPUT, adb_device, sdk_root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial')
    parser.add_argument('--android-sdk')
    parser.add_argument('--package', default='com.guava.game.crystalrush')
    args = parser.parse_args()
    adb = list(map(str, adb_device(sdk_root(args.android_sdk), args.serial)))
    directory = Path(tempfile.mkdtemp(prefix='game-run-', dir=OUTPUT))
    checks = []
    def shell(*arguments): return subprocess.check_output(adb + ['shell', shlex.join(map(str, arguments))], text=True)
    def read(): return json.loads(subprocess.check_output(adb + ['exec-out', 'run-as', args.package, 'cat', 'files/demo-state.json']))
    def wait(predicate, name):
        deadline = time.monotonic() + 30
        last = None
        while time.monotonic() < deadline:
            try:
                last = read()
                if predicate(last):
                    checks.append({'check': name, 'snapshot': last}); print('PASS', name, flush=True); return last
            except (ValueError, subprocess.CalledProcessError): pass
            time.sleep(.2)
        raise RuntimeError(f'{name}: {last}')
    def screenshot(name):
        (directory / (name + '.png')).write_bytes(subprocess.check_output(adb + ['exec-out', 'screencap', '-p']))
        image = Image.open(directory / (name + '.png')).convert('RGB')
        bounds = read()['surface']
        image = image.crop((bounds['x'], bounds['y'], bounds['x'] + bounds['width'], bounds['y'] + bounds['height']))
        assert max(ImageStat.Stat(image).stddev) > 20, 'Game image is blank'
    def action(name, scancode): shell('am', 'broadcast', '-a', 'com.guava.probe.DEMO_INPUT', '-p', args.package, '--es', 'demoAction', name, '--ei', 'scancode', scancode)
    try: old = read().get('session')
    except (ValueError, subprocess.CalledProcessError): old = None
    shell('am', 'start', '-W', '-S', '-n', args.package + '/com.guava.probe.MainActivity', '--ei', 'orientation', 0)
    ready = wait(lambda s: s.get('session') != old and s.get('mode') == 'game' and s.get('game', {}).get('rendered') and any('按空格开始' in t for t in s['game']['hud']), 'exported scene and Chinese HUD render')
    assert ready['game']['scripts'] == 1 and ready['game']['entities'] == 60
    screenshot('ready')
    shell('uiautomator', 'dump', '/data/local/tmp/guava-game-ui.xml')
    root = ET.fromstring(shell('cat', '/data/local/tmp/guava-game-ui.xml'))
    buttons = {}
    for node in root.iter('node'):
        if node.get('class') == 'android.widget.Button':
            bounds = list(map(int, re.findall(r'\d+', node.get('bounds'))))
            buttons[node.get('text').lower()] = [(bounds[0]+bounds[2])//2, (bounds[1]+bounds[3])//2]
    shell('input', 'tap', *buttons['start'])
    playing = wait(lambda s: not any('按空格开始' in t for t in s['game']['hud']), 'touch Start drives project script')
    action('keyDown', 26)
    moved = wait(lambda s: s['game']['player'][2] < -.5, 'held W moves the scene player')
    action('keyUp', 26)
    before = moved['game']['player'][0]
    shell('input', 'swipe', *buttons['d →'], *buttons['d →'], 700)
    moved = wait(lambda s: s['game']['player'][0] > before + .5, 'touch D moves player continuously')
    screenshot('playing')
    shell('input', 'keyevent', 'KEYCODE_HOME')
    time.sleep(.5)
    paused = read()
    time.sleep(.5)
    assert read()['frames'] == paused['frames'], 'background keeps ticking the game'
    shell('am', 'start', '-W', '-n', args.package + '/com.guava.probe.MainActivity')
    resumed = wait(lambda s: s['session'] == moved['session'] and s['frames'] > paused['frames'], 'resume retains the live game session')
    assert resumed['game']['entities'] == 60
    shell('am', 'start', '-W', '-n', args.package + '/com.guava.probe.MainActivity', '--ei', 'orientation', 1)
    portrait = wait(lambda s: s['height'] > s['width'] and s['session'] == resumed['session'] and s['game']['rendered'], 'rotation rebuilds Vulkan surface and retains simulation')
    screenshot('portrait')
    shell('am', 'start', '-W', '-n', args.package + '/com.guava.probe.MainActivity', '--ei', 'orientation', 0)
    wait(lambda s: s['width'] > s['height'], 'landscape game surface restores')
    action('keyDown', 21); action('keyUp', 21)
    restarted = wait(lambda s: s['game']['player'] == [0, .6, 0] and any('50 秒' in t for t in s['game']['hud']), 'restart restores the round deterministically')
    screenshot('restarted')
    pid = shell('pidof', args.package).strip()
    log = subprocess.check_output(adb + ['logcat', '-d', '--pid=' + pid, '-s', 'GuavaAndroid:I', 'AndroidRuntime:E', '*:S'], text=True)
    (directory / 'app.log').write_text(log)
    assert 'FAIL' not in log and 'FATAL' not in log, log[-4000:]
    (directory / 'report.json').write_text(json.dumps({'passed': True, 'checks': checks}, ensure_ascii=False, indent=2)+'\n')
    print('Exported game checks passed:', directory / 'report.json')


if __name__ == '__main__': main()
