#!/usr/bin/env python3
"""Render every repository Gallery page on Android and check real pixels and semantics."""
import argparse
import hashlib
import json
import re
import shlex
import subprocess
import tempfile
import time
from pathlib import Path
from PIL import Image, ImageStat
from common import ROOT, OUTPUT, adb_device, sdk_root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial')
    parser.add_argument('--android-sdk')
    parser.add_argument('--pages', nargs='+')
    parser.add_argument('--interactions-only', action='store_true')
    args = parser.parse_args()
    adb = list(map(str, adb_device(sdk_root(args.android_sdk), args.serial)))
    directory = Path(tempfile.mkdtemp(prefix='gallery-run-', dir=OUTPUT))
    catalog = re.findall(r'\.init\(\.(\w+),', (ROOT / 'GuavaUI/Sources/GuavaUIGallery/GalleryCatalog.swift').read_text())
    if args.pages and (unknown := set(args.pages) - set(catalog)):
        parser.error('Unknown Gallery pages: ' + ', '.join(sorted(unknown)))
    pages = [] if args.interactions_only else args.pages or catalog
    checks = []
    def shell(*arguments):
        return subprocess.check_output(adb + ['shell', shlex.join(map(str, arguments))], text=True)
    def read():
        return json.loads(subprocess.check_output(adb + ['exec-out', 'run-as', 'com.guava.probe', 'cat', 'files/demo-state.json']))
    def wait(predicate):
        deadline = time.monotonic() + 20
        last = None
        while time.monotonic() < deadline:
            try:
                last = read()
                if predicate(last): return last
            except (ValueError, subprocess.CalledProcessError): pass
            time.sleep(.15)
        (directory / 'failure.json').write_text(json.dumps(last, ensure_ascii=False, indent=2))
        raise RuntimeError(f'Gallery did not reach requested state; snapshot: {directory / "failure.json"}')
    def launch(page):
        try: old = read().get('session')
        except Exception: old = None
        shell('am', 'start', '-W', '-n', 'com.guava.probe/.MainActivity', '--es', 'mode', 'gallery', '--es', 'component', page, '--ei', 'orientation', 0, '--ez', 'snapshots', 'true')
        return wait(lambda s: s.get('mode') == 'gallery' and s.get('page') == page and s.get('session') != old)
    def tap(snapshot, node):
        bounds, scale, surface = node['bounds'], snapshot['scale'], snapshot['surface']
        shell('input', 'tap', round(surface['x'] + (bounds['x'] + bounds['width']/2)*scale), round(surface['y'] + (bounds['y']+bounds['height']/2)*scale))
    def screenshot(page):
        data = subprocess.check_output(adb + ['exec-out', 'screencap', '-p'])
        (directory / (page + '.png')).write_bytes(data)
        image = Image.open(directory / (page + '.png')).convert('RGB')
        bounds = read()['surface']
        image = image.crop((bounds['x'], bounds['y'], bounds['x'] + bounds['width'], bounds['y'] + bounds['height']))
        assert max(ImageStat.Stat(image).stddev) > 12, f'{page}: blank Swift surface'
        return hashlib.sha256(data).hexdigest()
    for page in pages:
        snapshot = launch(page)
        assert snapshot['indices'] > 1000 and len(snapshot['nodes']) > 10, page
        checks.append({'page': page, 'pixels': screenshot(page), 'snapshot': snapshot})
        print('PASS page', page, flush=True)
    if args.pages is None or args.interactions_only:
        snapshot = launch('checkbox')
        target = next(n for n in snapshot['nodes'] if n['role'] == 'checkbox' and n['enabled'] and n['bounds']['y'] > 180)
        tap(snapshot, target)
        changed = wait(lambda s: any(n['id'] == target['id'] and n['selected'] != target['selected'] for n in s['nodes']))
        checks.append({'check': 'checkbox touch updates controlled state', 'snapshot': changed})
        snapshot = launch('slider')
        target = next(n for n in snapshot['nodes'] if n['role'] == 'slider' and n['enabled'] and n['bounds']['y'] > 180)
        adjusted = dict(target); adjusted['bounds'] = dict(target['bounds'])
        adjusted['bounds']['x'] += adjusted['bounds']['width'] * .3
        tap(snapshot, adjusted)
        changed = wait(lambda s: any(n['id'] == target['id'] and n['value'] != target['value'] for n in s['nodes']))
        checks.append({'check': 'slider touch updates value', 'snapshot': changed})
        snapshot = launch('contextMenu')
        target = next(n for n in snapshot['nodes'] if n['label'] == 'Right-click this surface')
        bounds, scale, surface = target['bounds'], snapshot['scale'], snapshot['surface']
        x = round(surface['x'] + (bounds['x'] + bounds['width']/2)*scale)
        y = round(surface['y'] + (bounds['y'] + bounds['height']/2)*scale)
        shell('input', 'swipe', x, y, x, y, 900)
        opened = wait(lambda s: any(n['label'] == 'Duplicate' for n in s['nodes']))
        checks.append({'check': 'long press opens context menu', 'snapshot': opened})
        shell('input', 'keyevent', 'KEYCODE_ESCAPE')
        snapshot = launch('textField')
        target = next(n for n in snapshot['nodes'] if n['role'] == 'textField' and n['value'] == 'GuavaUI')
        tap(snapshot, target)
        focused = wait(lambda s: s.get('editor') is not None)
        def action(name, **values):
            command = ['am', 'broadcast', '-a', 'com.guava.probe.DEMO_INPUT', '-p', 'com.guava.probe', '--es', 'demoAction', name]
            for key, value in values.items(): command += ['--ei' if isinstance(value, int) else '--es', key, value]
            shell(*command)
        action('select', start=0, end=7)
        action('commit', text='Android你好')
        edited = wait(lambda s: s.get('editor', {}).get('text') == 'Android你好')
        action('compose', text='世界')
        wait(lambda s: s.get('editor', {}).get('compositionStart', -1) >= 0)
        action('commit', text='世界')
        committed = wait(lambda s: s.get('editor', {}).get('text') == 'Android你好世界')
        checks.append({'check': 'TextField selection, replacement and Chinese composition', 'snapshot': committed})
        screenshot('textfield-edited')
        shell('input', 'keyevent', 'KEYCODE_HOME')
        time.sleep(.5)
        paused = read()
        time.sleep(.3)
        assert read()['frames'] == paused['frames'], 'background Gallery keeps submitting frames'
        shell('am', 'start', '-W', '-n', 'com.guava.probe/.MainActivity', '--ez', 'snapshots', 'true')
        resumed = wait(lambda s: s.get('session') == committed['session'] and s.get('page') == 'textField' and s['frames'] > paused['frames'])
        assert any(n['role'] == 'textField' and n['value'] == 'Android你好世界' for n in resumed['nodes'])
        checks.append({'check': 'background retains Gallery control state', 'snapshot': resumed})
        viewport = resumed['controls']['gallery-content']; scale = resumed['scale']; origin = resumed['surface']
        x = round(origin['x'] + (viewport['x'] + viewport['width']*.85)*scale)
        y = round(origin['y'] + (viewport['y'] + viewport['height']*.85)*scale)
        shell('input', 'swipe', x, y, x, y-round(viewport['height']*.6*scale), 500)
        scrolled = wait(lambda s: any(n['label'] == 'Names and emoji' for n in s['nodes']))
        checks.append({'check': 'finger scrolling reveals clipped fields', 'snapshot': scrolled})

    pid = shell('pidof', 'com.guava.probe').strip()
    log = subprocess.check_output(adb + ['logcat', '-d', '--pid=' + pid, '-s', 'GuavaAndroid:I', 'AndroidRuntime:E', '*:S'], text=True)
    (directory / 'app.log').write_text(log)
    assert 'FAIL' not in log and 'FATAL' not in log, log[-4000:]
    (directory / 'report.json').write_text(json.dumps({'passed': True, 'pages': len(pages), 'checks': checks}, ensure_ascii=False, indent=2)+'\n')
    print('Gallery checks passed:', directory / 'report.json')


if __name__ == '__main__': main()
