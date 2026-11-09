#!/usr/bin/env python3
"""Linux end-to-end checks for launched target exit and recorder escalation."""
import json
import os
import re
import resource
import shlex
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

if sys.platform != 'linux':
    raise SystemExit('These checks require Linux wait statuses.')
if len(sys.argv) != 3:
    raise SystemExit('usage: cli-exit-checks.py GSTRACE OUTPUT_DIRECTORY')
repo = Path(__file__).resolve().parents[1]
cli = Path(sys.argv[1]).resolve()
output = Path(sys.argv[2]).resolve()
output.mkdir(parents=True, exist_ok=True)
root = Path(tempfile.mkdtemp(prefix='run-', dir=output))
fixture = root/'exitstatus'
subprocess.run(shlex.split(os.environ.get('CC', 'cc')) +
               ['-O1', '-g', str(repo/'Tests/fixtures/exitstatus.c'), '-o', str(fixture)], check=True)

def no_core():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

cases = [
    ('exit0', [], 0, 'exited', None, 0),
    ('exit3', [], 3, 'exited', None, 3),
    ('segv', [], 128+signal.SIGSEGV, 'signal', signal.SIGSEGV, None),
    ('term', [], 128+signal.SIGTERM, 'signal', signal.SIGTERM, None),
    ('loop', ['--time-limit', '200ms'], 0, 'requested-terminate', signal.SIGTERM, None),
    ('ignore-term', ['--time-limit', '200ms'], 128+signal.SIGKILL, 'escalated-kill', signal.SIGKILL, None),
]
results = []
for mode, options, code, reason, sig, normal in cases:
    trace = root/(mode+'.gstrace')
    command = [str(cli), 'record', '--instrument', 'time-profiler', '--output', str(trace),
               *options, '--launch', str(fixture), mode]
    with (root/(mode+'.log')).open('w') as log:
        process = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                 preexec_fn=no_core, timeout=25)
    try:
        assert process.returncode == code, f'CLI returned {process.returncode}, expected {code}'
        info = (trace/'Info.plist').read_text()
        raw = int(re.search(r'ExitStatus\s*=\s*<\*I(-?\d+)>', info)[1])
        recorded_reason = re.search(r'StopReason\s*=\s*([^;\n]+)', info)[1].strip().strip('"')
        assert recorded_reason == reason, (recorded_reason, reason)
        if sig is not None:
            assert os.WIFSIGNALED(raw) and os.WTERMSIG(raw) == sig, raw
        else:
            assert os.WIFEXITED(raw) and os.WEXITSTATUS(raw) == normal, raw
        view = subprocess.check_output([str(cli), 'info', str(trace)], text=True, stderr=subprocess.DEVNULL)
        assert f'Stop reason: {reason}' in view
        assert f'Exit status: {raw}' in view
        if mode == 'ignore-term':
            text = (root/(mode+'.log')).read_text()
            assert text.count('target did not exit within 3 s of SIGTERM; killed') == 1
        result = dict(mode=mode, status='PASS', cli_exit=code, raw_status=raw, stop_reason=recorded_reason)
        print('ok -', mode, flush=True)
    except (AssertionError, OSError, TypeError, subprocess.CalledProcessError) as error:
        result = dict(mode=mode, status='FAIL', error=str(error), cli_exit=process.returncode)
        print('FAIL -', mode, error, flush=True)
    results.append(result)
(root/'results.json').write_text(json.dumps(results, indent=2)+'\n')
print('Evidence:', root)
if any(row['status'] != 'PASS' for row in results):
    raise SystemExit(1)
print(f'All {len(results)} CLI target-exit checks passed.')
