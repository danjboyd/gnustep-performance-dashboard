#!/usr/bin/env python3
"""Actual generated AppRun -> GUI recorder -> owned target environment checks.

Use a fresh extracted package and a private passwd home. This creates and
cleans its own Xvfb; it never connects to an existing display. No test is run
merely by preparing this source.
"""
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

if len(sys.argv) not in (3, 5) or (len(sys.argv) == 5 and sys.argv[3] != '--case'):
    raise SystemExit('usage: target-config-gui-checks.py APPDIR OUTPUT_DIRECTORY [--case set|unset|empty]')
repo = Path(__file__).resolve().parents[1]
appdir = Path(sys.argv[1]).resolve()
launcher = appdir/'AppRun'
assert launcher.is_file() and 'GP_HOST_VARS' in launcher.read_text(), 'actual v0.1.10 generated AppRun required'
output = Path(sys.argv[2]).resolve()
output.mkdir(parents=True, exist_ok=True)
if len(sys.argv) == 3:
    # Each case gets a distinct passwd home, defaults, TMPDIR, fixture basename
    # and resulting GUI trace path. A prior failed case cannot collide with it.
    run = Path(tempfile.mkdtemp(prefix='gui-config-round-', dir=output))
    results = []
    for mode in ('set', 'unset', 'empty'):
        case_dir = run/mode
        case_dir.mkdir(mode=0o700)
        command = [sys.executable, str(repo/'scripts/with-private-home.py'),
                   str(case_dir/'private-home'), '--', sys.executable,
                   str(Path(__file__).resolve()), str(appdir), str(case_dir/'evidence'),
                   '--case', mode]
        with (case_dir/'case-console.log').open('w') as log:
            child = subprocess.run(command, stdout=log, stderr=log)
        files = list((case_dir/'evidence').glob('gui-config-*/results.json'))
        if len(files) == 1:
            entries = json.loads(files[0].read_text())
            assert len(entries) == 1 and entries[0]['case'] == mode
            result = entries[0]
        else:
            result = {'case': mode, 'status': 'FAIL', 'error': 'case did not produce one receipt'}
        result.update(case_exit=child.returncode, evidence=str(case_dir))
        if child.returncode != 0: result['status'] = 'FAIL'
        results.append(result)
        print(result['status'], mode, flush=True)
    (run/'results.json').write_text(json.dumps(results, indent=2)+'\n')
    print('GUI config evidence:', run)
    raise SystemExit(0 if all(x['status'] == 'PASS' for x in results) else 1)
mode_filter = sys.argv[4]
assert mode_filter in ('set', 'unset', 'empty')
subprocess.run([sys.executable, str(repo/'scripts/with-private-home.py'), '--check'], check=True)
root = Path(tempfile.mkdtemp(prefix='gui-config-', dir=output))
fixture = root/('target-'+root.name)
subprocess.run(shlex.split(os.environ.get('CC', 'cc'))+
    ['-O1', str(repo/'Tests/fixtures/exitstatus.c'), '-o', str(fixture)], check=True)
config = appdir/'usr/runtime/etc/GNUstep/GNUstep.conf'
scratch = root/'caller config.conf'
lines = []
for line in config.read_text().splitlines():
    if '=' in line and not line.lstrip().startswith('#'):
        key, value = line.split('=', 1)
        if value.startswith(('./', '../')): line = key+'='+str((config.parent/value).resolve())
    lines.append(line)
scratch.write_text('\n'.join(lines)+'\nGNUSTEP_USER_DEFAULTS_DIR='+str(root/'defaults')+'\n')
(root/'tmp').mkdir(mode=0o700)

def target_pid():
    for process in Path('/proc').iterdir():
        if not process.name.isdigit(): continue
        try:
            if str((process/'exe').readlink()) == str(fixture): return int(process.name)
        except OSError: pass
    return None

read_fd, write_fd = os.pipe()
with (root/'xvfb.log').open('w') as log:
    xvfb = subprocess.Popen(['Xvfb', '-displayfd', str(write_fd), '-screen', '0',
        '1280x800x24', '-nolisten', 'tcp'], pass_fds=(write_fd,), stdout=log, stderr=log)
os.close(write_fd)
results = []
try:
    import select
    assert select.select([read_fd], [], [], 10)[0], 'private Xvfb did not start'
    display = ':'+os.read(read_fd, 32).decode().strip()
    assert re.fullmatch(r':\d+', display)
    assert display != ':120', 'persistent desktop must never be used'
    for mode in (mode_filter,):
        env = {k: v for k, v in os.environ.items() if not k.startswith(('GP_HOST_', 'PD_TARGET_', 'GSP_'))
               and k not in ('APPDIR', 'APPIMAGE', 'ARGV0', 'OWD', 'GNUSTEP_CONFIG_FILE', 'WAYLAND_DISPLAY')}
        env.update(DISPLAY=display, TMPDIR=str(root/'tmp'), DBUS_SESSION_BUS_ADDRESS='unix:path=/nonexistent')
        if mode != 'unset': env['GNUSTEP_CONFIG_FILE'] = '' if mode == 'empty' else str(scratch)
        command = [str(launcher), '-PDRecordTarget', str(fixture), '-PDRecordArguments', 'loop',
                   '-PDRecordTemplate', 'Time Profiler', '-PDRecordTimeLimit', '2']
        case = {'case': mode, 'status': 'FAIL'}
        with (root/(mode+'.log')).open('w') as log:
            app = subprocess.Popen(command, env=env, stdout=log, stderr=log, start_new_session=True)
            try:
                deadline = time.monotonic()+10
                pid = None
                while time.monotonic() < deadline:
                    assert app.poll() is None, 'GUI exited before target environment check'
                    pid = target_pid()
                    if pid is not None: break
                    time.sleep(.02)
                # Read only known launch keys, after verifying that AppRun has
                # exec'd this package's actual GUI rather than sampling a shell.
                gui_exe = Path(f'/proc/{app.pid}/exe').readlink().resolve()
                expected_gui = (appdir/'usr/app/PerformanceDashboard.app/PerformanceDashboard').resolve()
                assert gui_exe == expected_gui, 'AppRun did not exec the expected GUI'
                gui_env = dict(x.split(b'=', 1) for x in Path(f'/proc/{app.pid}/environ').read_bytes().split(b'\0') if b'=' in x)
                case['gui_environment'] = {key: (None if key.encode() not in gui_env else os.fsdecode(gui_env[key.encode()]))
                    for key in ('APPDIR', 'GNUSTEP_CONFIG_FILE', 'GP_HOST_VARS', 'GP_HOST_UNSET', 'GP_HOST_GNUSTEP_CONFIG_FILE')}
                case['gui_executable'] = str(gui_exe)
                case['app_pid'] = app.pid
                case['private_home'] = os.environ.get('PD_PRIVATE_HOME_DIR')
                assert pid is not None, 'owned target did not start'
                actual = dict(x.split(b'=', 1) for x in Path(f'/proc/{pid}/environ').read_bytes().split(b'\0') if b'=' in x)
                expected = None if mode == 'unset' else b'' if mode == 'empty' else os.fsencode(scratch)
                observed = actual.get(b'GNUSTEP_CONFIG_FILE')
                markers = [k.decode(errors='replace') for k in actual if k.startswith((b'GP_HOST_', b'PD_TARGET_'))]
                case.update(observed_config_present=b'GNUSTEP_CONFIG_FILE' in actual,
                            observed_config=None if observed is None else os.fsdecode(observed),
                            expected_config=None if expected is None else os.fsdecode(expected),
                            transport_markers=markers)
                assert observed == expected, 'target caller configuration differs; see retained expected/observed values'
                assert not markers, 'transport markers reached target: '+', '.join(markers)
                case.update(status='PASS', target_pid=pid, config_present=b'GNUSTEP_CONFIG_FILE' in actual)
                deadline = time.monotonic()+6
                while target_pid() is not None and time.monotonic() < deadline: time.sleep(.05)
                assert target_pid() is None, 'time-limited GUI target remained alive'
            except (AssertionError, OSError) as error:
                case.update(status='FAIL', error=str(error))
                try:
                    shot = subprocess.run(['import', '-display', display, '-window', 'root',
                        str(root/(mode+'-failure.png'))], timeout=5, capture_output=True)
                    case['failure_screenshot_exit'] = shot.returncode
                except (OSError, subprocess.TimeoutExpired) as shot_error:
                    case['failure_screenshot_error'] = str(shot_error)
            finally:
                if app.poll() is None:
                    os.killpg(app.pid, signal.SIGTERM)
                    try: app.wait(timeout=8)
                    except subprocess.TimeoutExpired:
                        os.killpg(app.pid, signal.SIGKILL); app.wait(timeout=3)
                        case.update(status='FAIL', error='GUI required forced cleanup')
                if app.returncode != 0: case.update(status='FAIL', gui_exit=app.returncode)
                pid = target_pid()
                if pid is not None:
                    os.kill(pid, signal.SIGKILL)
                    case.update(status='FAIL', error='owned target required forced cleanup')
        results.append(case)
        print(case['status'], mode, flush=True)
finally:
    os.close(read_fd)
    xvfb.terminate()
    try: xvfb.wait(timeout=3)
    except subprocess.TimeoutExpired: xvfb.kill(); xvfb.wait(timeout=3)
    # Default GUI traces have the unique fixture basename; never delete another recording.
    for parent in [root/'tmp', Path('/tmp')/('GNUstepSecure'+str(os.getuid()))/'Performance Dashboard']:
        if parent.exists():
            for trace in parent.rglob(fixture.name+'*.gstrace'):
                if trace.is_dir() and not trace.is_symlink():
                    case.setdefault('trace_paths', []).append(str(trace))
                    info = trace/'Info.plist'
                    if info.is_file(): shutil.copy2(info, root/(mode+'-trace-Info.plist'))
                    shutil.rmtree(trace)
    (root/'cleanup.json').write_text(json.dumps({'xvfbPIDReaped': xvfb.pid,
        'appPIDsReaped': [] if 'app' not in locals() else [app.pid],
        'privateDisplay': locals().get('display'), 'noForeignDisplayTouched': True})+'\n')
    (root/'results.json').write_text(json.dumps(results, indent=2)+'\n')
print('GUI config evidence:', root)
raise SystemExit(0 if len(results) == 1 and all(x['status'] == 'PASS' for x in results) else 1)
