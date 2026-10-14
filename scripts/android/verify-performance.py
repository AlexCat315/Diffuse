#!/usr/bin/env python3
"""Measure native UI CPU work and SurfaceFlinger presentation on a connected Android device."""
import argparse
import concurrent.futures
import json
import math
import re
import shlex
import statistics
import struct
import subprocess
import tempfile
import time
import zlib
from pathlib import Path

from common import OUTPUT, ROOT, adb_device, sdk_root


PACKAGE = 'com.guava.probe'


def distribution(values):
    if not values:
        return None
    ordered = sorted(values)
    return {
        'samples': len(values),
        'median': statistics.median(values),
        'p95': ordered[math.ceil(len(ordered) * .95) - 1],
        'p99': ordered[math.ceil(len(ordered) * .99) - 1],
        'maximum': ordered[-1],
        'mean': statistics.mean(values),
    }


def numeric_fields(line):
    return {key: float(value) if '.' in value else int(value)
            for key, value in re.findall(r'(\w+)=([0-9]+(?:\.[0-9]+)?)(?:ms)?', line)}


class Device:
    def __init__(self, adb):
        self.adb = list(map(str, adb))

    def shell(self, *arguments):
        return subprocess.check_output(self.adb + ['shell', shlex.join(map(str, arguments))], text=True)

    def snapshot(self):
        self.shell('am', 'broadcast', '-a', PACKAGE + '.DEMO_INPUT', '-p', PACKAGE,
                   '--es', 'demoAction', 'snapshot')
        return json.loads(subprocess.check_output(self.adb + [
            'exec-out', 'run-as', PACKAGE, 'cat', 'files/demo-state.json']))

    def layer(self):
        lines = self.shell('dumpsys', 'SurfaceFlinger', '--list').splitlines()
        candidates = [line for line in lines if PACKAGE in line and 'SurfaceView[' in line and '(BLAST)' in line]
        if not candidates:
            raise RuntimeError('The native GuavaUI SurfaceView is not visible')
        return candidates[0].removeprefix('RequestedLayerState{').split(' parentId=')[0].rstrip('}')

    def screenshot(self, path):
        pixels = subprocess.check_output(self.adb + ['exec-out', 'screencap', '-p'])
        path.write_bytes(pixels)
        return struct.unpack('>II', pixels[16:24])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial')
    parser.add_argument('--android-sdk')
    parser.add_argument('--configuration', choices=['debug', 'release'], required=True)
    parser.add_argument('--component', default='introduction')
    parser.add_argument('--scenario', choices=['benchmark', 'benchmark-scroll', 'scroll', 'idle'], default='benchmark')
    parser.add_argument('--vsync', choices=['on', 'off'], default='on')
    parser.add_argument('--timings', choices=['on', 'off'], default='on')
    parser.add_argument('--trace', action='store_true', help='Trace Vulkan lifecycle calls and reject per-frame swapchain rebuilds in a static benchmark')
    parser.add_argument('--seconds', type=float, default=10)
    parser.add_argument('--warmup', type=float, default=3)
    args = parser.parse_args()
    if args.seconds <= 0 or args.warmup < 0:
        parser.error('seconds must be positive and warmup must not be negative')
    OUTPUT.mkdir(parents=True, exist_ok=True)
    directory = Path(tempfile.mkdtemp(prefix=f'perf-{args.configuration}-{args.component}-{args.scenario}-', dir=OUTPUT))
    device = Device(adb_device(sdk_root(args.android_sdk), args.serial))
    metadata = {
        'configuration': args.configuration, 'requestedComponent': args.component,
        'scenario': args.scenario, 'requestedVSync': args.vsync == 'on',
        'timingsEnabled': args.timings == 'on',
        'traceEnabled': args.trace,
        'warmupSeconds': args.warmup, 'measurementSeconds': args.seconds,
        'model': device.shell('getprop', 'ro.product.model').strip(),
        'android': device.shell('getprop', 'ro.build.version.release').strip(),
        'api': device.shell('getprop', 'ro.build.version.sdk').strip(),
        'gitRevision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
    }
    (directory / 'package.txt').write_text(device.shell('dumpsys', 'package', PACKAGE))
    (directory / 'thermal-before.txt').write_text(device.shell('dumpsys', 'thermalservice'))
    device.shell('am', 'force-stop', PACKAGE)
    launch = ['am', 'start', '-W', '-n', PACKAGE + '/.MainActivity', '--ei', 'orientation', 0,
              '--ez', 'benchmark', str(args.scenario.startswith('benchmark')).lower(), '--ez', 'timings', str(args.timings == 'on').lower(),
              '--ez', 'snapshots', 'false', '--ez', 'vsync', str(args.vsync == 'on').lower()]
    if args.configuration == 'debug':
        launch += ['--es', 'mode', 'gallery', '--es', 'component', args.component]
    (directory / 'launch.txt').write_text(device.shell(*launch))
    pid = device.shell('pidof', PACKAGE).strip()
    if not pid:
        raise RuntimeError('The application failed to start')
    log_path = directory / 'app.log'
    trace_started = False
    with log_path.open('wb') as output:
        startup = subprocess.check_output(device.adb + ['logcat', '-d', '-v', 'threadtime', '--pid=' + pid,
                                                       'Guava:I', 'AndroidRuntime:E', '*:S'])
        output.write(startup)
        output.flush()
        # Measurement markers come from adb's shell process, not the app PID.
        # Keep both tags here and filter app records after isolating the window.
        logger = subprocess.Popen(device.adb + ['logcat', '-v', 'threadtime', '-T', '1',
                                              'Guava:I', 'GuavaPerf:I', 'AndroidRuntime:E', '*:S'], stdout=output)
        try:
            time.sleep(args.warmup)
            width, height = device.screenshot(directory / 'screen.png')
            metadata['screenPixels'] = [width, height]
            layer = device.layer()
            metadata['surfaceLayer'] = layer
            (directory / 'cpu-hints.txt').write_text(device.shell('dumpsys', 'performance_hint'))
            if args.configuration == 'debug':
                (directory / 'state-before.json').write_text(json.dumps(device.snapshot(), ensure_ascii=False, indent=2))
            baseline = device.shell('dumpsys', 'SurfaceFlinger', '--latency', layer)
            previous_presentations = [int(parts[1]) for line in baseline.splitlines()[1:]
                                      if len(parts := line.split()) == 3 and all(value.isdigit() for value in parts)
                                      and 0 < int(parts[1]) < 2**63 - 1]
            first_presentation = max(previous_presentations, default=0)
            begin_marker = directory.name + ' MEASURE_BEGIN'
            end_marker = directory.name + ' MEASURE_END'
            if args.trace:
                device.shell('atrace', '--async_start', '-z', '-b', 32768, 'gfx', 'view')
                trace_started = True
            device.shell('log', '-t', 'GuavaPerf', begin_marker)
            start = time.monotonic()
            deadline = start + args.seconds
            presentations = {}
            refresh_periods = []
            raw_latency = []

            def scroll():
                turn = 0
                while time.monotonic() < deadline:
                    top, bottom = round(height * .35), round(height * .8)
                    device.shell('input', 'swipe', round(width * .75), bottom if turn % 2 == 0 else top,
                                 round(width * .75), top if turn % 2 == 0 else bottom, 500)
                    turn += 1
                return turn

            with concurrent.futures.ThreadPoolExecutor(1) as workers:
                gesture = workers.submit(scroll) if args.scenario.endswith('scroll') else None
                while True:
                    raw = device.shell('dumpsys', 'SurfaceFlinger', '--latency', layer)
                    raw_latency.append(raw)
                    lines = raw.splitlines()
                    if lines and lines[0].isdigit():
                        refresh_periods.append(int(lines[0]) / 1_000_000)
                    for line in lines[1:]:
                        parts = line.split()
                        if len(parts) == 3 and all(value.isdigit() for value in parts):
                            row = tuple(map(int, parts))
                            if first_presentation < row[1] < 2**63 - 1:
                                presentations[row[1]] = row
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    time.sleep(min(.5, remaining))
                metadata['gestures'] = gesture.result() if gesture else 0
            metadata['actualMeasurementSeconds'] = time.monotonic() - start
            device.shell('log', '-t', 'GuavaPerf', end_marker)
            time.sleep(.2)
            (directory / 'surface-latency.txt').write_text('\n'.join(raw_latency))
            if args.configuration == 'debug':
                (directory / 'state-after.json').write_text(json.dumps(device.snapshot(), ensure_ascii=False, indent=2))
        finally:
            if trace_started:
                trace = subprocess.check_output(device.adb + ['shell', 'atrace --async_stop -z gfx view'])
                (directory / 'system.atrace').write_bytes(trace)
            logger.terminate()
            logger.wait(timeout=5)
    (directory / 'thermal-after.txt').write_text(device.shell('dumpsys', 'thermalservice'))
    device.shell('am', 'force-stop', PACKAGE)
    text = log_path.read_text(errors='replace')
    if begin_marker not in text or end_marker not in text:
        raise RuntimeError('Missing measurement boundary markers; see ' + str(log_path))
    measurement = text.split(begin_marker, 1)[1].split(end_marker, 1)[0]
    app_record = re.compile(r'\s' + re.escape(pid) + r'\s+\d+\s+[A-Z]\s')
    measurement = '\n'.join(line for line in measurement.splitlines() if app_record.search(line))
    app_text = '\n'.join(line for line in text.splitlines() if app_record.search(line))
    frames = [numeric_fields(line) for line in measurement.splitlines() if '[timing] android.frame ' in line]
    pacing = [numeric_fields(line) for line in measurement.splitlines() if '[timing] android.pacing ' in line]
    gpu = [numeric_fields(line) for line in measurement.splitlines() if '[timing] android.gpu ' in line]
    timestamps = [frame['displayTime'] for frame in frames]
    phases = ['scenePrepare', 'frameSlot', 'drawableAcquire', 'atlasUpload', 'commandRecord', 'queueSubmit', 'present', 'total']
    actual = sorted(presentations)
    lifecycle = None
    if args.trace:
        trace = zlib.decompress((directory / 'system.atrace').read_bytes().split(b'TRACE:\n', 1)[1]).decode(errors='replace')
        calls = re.findall(r'tracing_mark_write: B\|' + re.escape(pid) + r'\|([^\n|]+)', trace)
        lifecycle = {name: calls.count(name) for name in ['CreateSwapchainKHR', 'DestroySwapchainKHR', 'AllocateCommandBuffers', 'AcquireNextImageKHR', 'QueuePresentKHR']}
    # Per-pass GPU intervals arrive from the RHI timestamp profile. The log line
    # carries one average and one worst value per pass label, so aggregate each
    # key separately. `ms` is the unit on the value, not part of the key.
    gpu_passes = {}
    for window in gpu:
        for key, value in window.items():
            if key in ('window', 'passes'):
                continue
            gpu_passes.setdefault(key, []).append(value)
    # The baseline history was excluded above, so presentation statistics remain
    # independent of CPU telemetry, including its bounded sample count.
    intervals = [(b - a) / 1_000_000 for a, b in zip(actual, actual[1:])]
    report = {
        'metadata': metadata,
        'open': [line for line in app_text.splitlines() if 'OPEN ' in line],
        'cpuMilliseconds': {phase: distribution([frame[phase] for frame in frames]) for phase in phases},
        'callbackIntervalMilliseconds': distribution([(b - a) / 1_000_000 for a, b in zip(timestamps, timestamps[1:])]),
        'geometry': {key: distribution([frame[key] for frame in frames]) for key in ['vertices', 'indices']},
        'pacingWindows': pacing,
        'gpuMilliseconds': {key: distribution(values) for key, values in gpu_passes.items()},
        'vulkanLifecycle': lifecycle,
        'presentation': {'samples': len(actual), 'refreshPeriodMilliseconds': distribution(refresh_periods),
                         'intervalMilliseconds': distribution(intervals),
                         'observedFramesPerSecond': (len(actual) - 1) * 1e9 / (actual[-1] - actual[0]) if len(actual) > 1 else None},
        'notes': ['CPU samples include native waits and exclude the final per-frame log formatting.',
                  'Callback work includes telemetry; callback cadence is not displayed FPS.',
                  'SurfaceFlinger samples are actual presentation timestamps from the native SurfaceView.',
                  'Release component is selected in APK launch.json; its Intent component override is disabled.',
                  'Native phase logging is capped at 6000 samples per surface.',
                  'gpuMilliseconds are GPU execution intervals between timestamp pairs; they exclude queue wait,'
                  ' swapchain acquire and present, and cover only the passes reported by the RHI profile.'],
    }
    if 'FAIL ' in app_text or 'FATAL EXCEPTION' in app_text:
        raise RuntimeError('Android application reported a failure; see ' + str(log_path))
    if args.timings == 'on' and args.scenario != 'idle' and len(frames) < 5:
        raise RuntimeError('Insufficient native frame telemetry; see ' + str(log_path))
    if args.scenario != 'idle' and len(actual) < 5:
        raise RuntimeError('Insufficient presented frames; see ' + str(directory / 'surface-latency.txt'))
    if args.scenario == 'idle' and len(frames) > 1:
        raise RuntimeError('An idle scene continued rendering during measurement; see ' + str(log_path))
    report['passed'] = True
    if args.trace and args.scenario == 'benchmark':
        report['passed'] = lifecycle['CreateSwapchainKHR'] == 0 and lifecycle['AllocateCommandBuffers'] == 0 and lifecycle['AcquireNextImageKHR'] > 0
    (directory / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'report': str(directory / 'report.json'), 'cpuTotal': report['cpuMilliseconds']['total'],
                      'presentation': report['presentation']}, ensure_ascii=False), flush=True)
    if not report['passed']:
        raise RuntimeError('Swapchain stability regression: see ' + str(directory / 'report.json'))


if __name__ == '__main__':
    main()
