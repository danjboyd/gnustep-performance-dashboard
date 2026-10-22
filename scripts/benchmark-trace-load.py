#!/usr/bin/env python3
"""Diagnostic Linux AppImage trace-open benchmark; never release acceptance.

Uses packaged Adwaita on private Xvfb, with the standard File > Open Recent
menu. Hashing warms the input cache. No artificial target delay is introduced.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import time
import plistlib


def identity(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return {'bytes': path.stat().st_size, 'sha256': digest.hexdigest()}


def trace_identity(path):
    return {str(p.relative_to(path)): identity(p) for p in sorted(path.rglob('*')) if p.is_file()}


def wait_for(probe, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(.1)
    raise RuntimeError('Timed out waiting for the recorded app/UI to respond')


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('appimage', type=Path)
parser.add_argument('trace', type=Path)
parser.add_argument('output', type=Path, help='Unused directory; all receipts/traces are retained')
parser.add_argument('--recorder-appimage', type=Path, help='Use a separate unchanged recorder package')
parser.add_argument('--runs', type=int, default=3, choices=range(1, 11))
parser.add_argument('--timeout', type=int, default=60, help='Per-operation limit in seconds')
args = parser.parse_args()
image, source, out = args.appimage.resolve(), args.trace.resolve(), args.output.resolve()
if out == source or source in out.parents or args.timeout < 5:
    parser.error('Choose output outside the input trace, and timeout >= 5')
out.mkdir(mode=0o700, parents=True)  # Refuse reuse, preserving previous evidence.
sample = Path(__file__).resolve().parents[1] / 'Tests/data/sample.gstrace'
receipt = {'diagnosticOnly': True, 'appimage': identity(image), 'inputPath': str(source),
           'inputFiles': trace_identity(source), 'initialFiles': trace_identity(sample), 'runs': []}
recorder_image = args.recorder_appimage.resolve() if args.recorder_appimage else image
receipt['recorderAppimage'] = identity(recorder_image)
xvfb = record = pid = None
try:
    subprocess.run([str(image), '--appimage-extract'], cwd=out, check=True, stdout=subprocess.DEVNULL)
    root = out / 'squashfs-root/usr'
    app, runtime = root / 'app/PerformanceDashboard.app/PerformanceDashboard', root / 'runtime'
    gst = runtime / 'bin/gstrace'
    binaries = [app, gst, runtime / 'bin/gstrace-bin', runtime / 'lib/libGSPerformance.so.0',
                runtime / 'lib/libgsperf-agent.so']
    if (runtime / 'lib/libgsperf.so.0').exists():
        binaries.append(runtime / 'lib/libgsperf.so.0')
    receipt['binaries'] = {str(p.relative_to(root)): identity(p) for p in binaries}
    recorder_root = root
    if recorder_image != image:
        (out / 'recorder').mkdir()
        subprocess.run([str(recorder_image), '--appimage-extract'], cwd=out / 'recorder',
                       check=True, stdout=subprocess.DEVNULL)
        recorder_root = out / 'recorder/squashfs-root/usr'
    recorder_runtime = recorder_root / 'runtime'
    gst = recorder_runtime / 'bin/gstrace'
    recorder_binaries = [gst, recorder_runtime / 'bin/gstrace-bin',
        recorder_runtime / 'lib/libGSPerformance.so.0', recorder_runtime / 'lib/libgsperf-agent.so']
    receipt['recorderBinaries'] = {str(p.relative_to(recorder_root)): identity(p) for p in recorder_binaries}
    read_fd, write_fd = os.pipe()
    with (out / 'xvfb.log').open('w') as log:
        xvfb = subprocess.Popen(['Xvfb', '-displayfd', str(write_fd), '-screen', '0',
                                '1280x900x24', '-nolisten', 'tcp', '-ac'],
                               pass_fds=(write_fd,), stdout=log, stderr=log)
    os.close(write_fd)
    if not select.select([read_fd], [], [], 10)[0]:
        raise RuntimeError('Private Xvfb did not start')
    with os.fdopen(read_fd) as stream:
        display = ':' + stream.readline().strip()
    (out / 'tmp').mkdir(mode=0o700)
    env = dict(os.environ, DISPLAY=display, XAUTHORITY='', LC_ALL='C.UTF-8', TMP=str(out / 'tmp'),
               LD_LIBRARY_PATH=str(runtime / 'lib'), DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent')
    for key in ('APPDIR', 'APPIMAGE', 'LD_PRELOAD', 'GSP_OUTPUT', 'GP_UPDATER_FEED_URL'):
        env.pop(key, None)

    def run(command, check=True):
        return subprocess.run([str(x) for x in command], env=env, text=True,
                              capture_output=True, check=check, timeout=args.timeout)

    def windows():
        return set(run(['xdotool', 'search', '--onlyvisible', '--name', '.+'], False).stdout.split())

    def idle():
        return 'poll' in Path(f'/proc/{pid}/task/{pid}/wchan').read_text()

    def screenshot(path):
        run(['import', '-window', 'root', path])
        return int(run(['identify', '-format', '%k', path]).stdout) > 1

    for number in range(1, args.runs + 1):
        folder = out / f'run-{number}'
        (folder / 'defaults').mkdir(parents=True)
        config_source = runtime / 'etc/GNUstep/GNUstep.conf'
        lines = []
        for line in config_source.read_text().splitlines():
            if line.startswith(('GNUSTEP_USER_CONFIG_FILE=', 'GNUSTEP_USER_DEFAULTS_DIR=')):
                continue
            key, sep, value = line.partition('=')
            lines.append(key + sep + (str((config_source.parent / value).resolve()) if value.startswith('../') else value))
        config = folder / 'GNUstep.conf'
        config.write_text('\n'.join(lines + ['GNUSTEP_USER_CONFIG_FILE=', f'GNUSTEP_USER_DEFAULTS_DIR={folder / "defaults"}']) + '\n')
        config.chmod(0o600)
        (folder / 'defaults/io.github.danjboyd.PerformanceDashboard.plist').write_bytes(
            plistlib.dumps({'PDRecentTraces': [str(source)],
                'GPUpdater.io.github.danjboyd.PerformanceDashboard.automaticChecksConfigured': True,
                'GPUpdater.io.github.danjboyd.PerformanceDashboard.automaticChecksEnabled': False}))
        env['GNUSTEP_CONFIG_FILE'] = str(config)
        validation = run([gst, 'info', source])
        if not re.search(r'Process \d+ \(target\):[^\n]*\n  finished cleanly: yes', validation.stdout):
            raise RuntimeError('Input must be a finished valid recording')
        command = [str(gst), 'record', '--template', 'Time Profiler', '--time-limit',
                   f'{args.timeout * 3}s', '--env', f'GNUSTEP_CONFIG_FILE={config}',
                   '--env', f'LD_LIBRARY_PATH={runtime / "lib"}', '-o', str(folder / 'load.gstrace'),
                   '--launch', str(app), '-PDOpenTrace', str(sample), '-GSTheme', 'Adwaita']
        (folder / 'command.json').write_text(json.dumps(command, indent=2) + '\n')
        pid = None
        with (folder / 'record.log').open('w') as log:
            record = subprocess.Popen(command, env=env, stdout=log, stderr=log)
        match = wait_for(lambda: re.search(r'\(pid (\d+)\)', (folder / 'record.log').read_text()), args.timeout)
        pid = int(match[1])
        if int(re.search(r'^PPid:\s*(\d+)', Path(f'/proc/{pid}/status').read_text(), re.M)[1]) != record.pid:
            raise RuntimeError('Recorded target is not a child of our recorder')
        main = wait_for(lambda: run(['xdotool', 'search', '--onlyvisible', '--name', 'objcwork.*Custom'], False).stdout.strip(), args.timeout).splitlines()[-1]
        wait_for(idle, args.timeout)
        run(['xdotool', 'windowfocus', '--sync', main, 'mousemove', '85', '56', 'click', '1'])
        time.sleep(.2)  # Allow the menu and its submenu to display, not target work.
        run(['xdotool', 'mousemove', '200', '160'])
        time.sleep(.2)
        run(['import', '-window', 'root', folder / 'open-recent.png'])
        run(['xdotool', 'mousemove', '460', '160'])
        time.sleep(.2)  # Let submenu tracking process pointer entry before clicking.
        before = windows()
        submitted = time.monotonic_ns()
        run(['xdotool', 'click', '1'])
        loaded = wait_for(lambda: next((w for w in windows() - before if ' — ' in
                          run(['xdotool', 'getwindowname', w], False).stdout), None), args.timeout)
        for unused in range(3):
            wait_for(idle, args.timeout)
            time.sleep(.1)
        wait_for(lambda: screenshot(folder / 'loaded.png'), args.timeout)
        loaded_title = run(['xdotool', 'getwindowname', loaded]).stdout.strip()
        maps = Path(f'/proc/{pid}/maps').read_text()
        (folder / 'loaded-maps.txt').write_text(maps)
        loaded_libraries = {}
        for library in (recorder_runtime / 'lib/libgsperf-agent.so', runtime / 'lib/libgsperf.so.0'):
            if not library.exists():
                continue
            paths = {line.split(None, 5)[5] for line in maps.splitlines()
                     if len(line.split(None, 5)) == 6 and line.split(None, 5)[5].endswith('/' + library.name)}
            actual = {path: identity(Path(path)) for path in paths}
            if not actual or any(value != identity(library) for value in actual.values()):
                raise RuntimeError(f'Loaded library does not match package: {library}')
            loaded_libraries.update(actual)  # The recorder may use its stable agent cache.
        os.kill(pid, signal.SIGTERM)
        if record.wait(timeout=15) != 0:
            raise RuntimeError('Recorder did not exit cleanly')
        record = None
        info = run([gst, 'info', folder / 'load.gstrace']).stdout
        (folder / 'info.txt').write_text(info)
        run([gst, 'export', folder / 'load.gstrace', '--format', 'json', '-o', folder / 'trace.json'])
        run([gst, 'export', folder / 'load.gstrace', '--format', 'csv', '--table', 'signposts', '-o', folder / 'signposts.csv'])
        data = json.loads((folder / 'trace.json').read_text())
        if not data['finishedCleanly'] or not data['runLoopDetected']:
            raise RuntimeError('Recording did not finish cleanly with run-loop evidence')
        result = {key: data[key] for key in ('cpuSamples', 'wallSamples', 'cpuSeconds', 'duration', 'hangs')}
        result['signposts'] = data.get('signposts', [])
        result['loadedLibraries'] = loaded_libraries
        result.update(hangCount=len(data['hangs']), longestHangSeconds=max((h['duration'] for h in data['hangs']), default=0),
                      droppedSamples=int(re.search(r'dropped:\s*(\d+)', info)[1]), operationSubmittedMonotonicNs=submitted,
                      loadedWindowTitle=loaded_title)
        receipt['runs'].append(result)
        (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
        print(json.dumps({'run': number, **result}), flush=True)
    if trace_identity(source) != receipt['inputFiles'] or trace_identity(sample) != receipt['initialFiles']:
        raise RuntimeError('Input hashes changed')
    if {str(p.relative_to(root)): identity(p) for p in binaries} != receipt['binaries'] or identity(image) != receipt['appimage']:
        raise RuntimeError('Binary hashes changed')
    if identity(recorder_image) != receipt['recorderAppimage'] or {str(p.relative_to(recorder_root)): identity(p) for p in recorder_binaries} != receipt['recorderBinaries']:
        raise RuntimeError('Recorder hashes changed')
    receipt['hashesUnchanged'] = True
except Exception as error:
    receipt['error'] = str(error)
    raise
finally:
    if record is not None and record.poll() is None:
        if pid and Path(f'/proc/{pid}/exe').exists() and os.readlink(f'/proc/{pid}/exe') == str(app):
            os.kill(pid, signal.SIGTERM)
        try:
            record.wait(timeout=10)
        except subprocess.TimeoutExpired:
            if pid and Path(f'/proc/{pid}/exe').exists() and os.readlink(f'/proc/{pid}/exe') == str(app):
                os.kill(pid, signal.SIGKILL)
            record.kill()
            record.wait()
    if xvfb is not None:
        xvfb.terminate()
        try:
            xvfb.wait(timeout=5)
        except subprocess.TimeoutExpired:
            xvfb.kill()
            xvfb.wait()
    (out / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
