#!/usr/bin/env python3
"""Small Linux capture thresholds and failure propagation; run in a private home.

Builds only owned test programs. ENOSPC is a deterministic writer-helper fault;
RLIMIT_FSIZE integration is EFBIG, not a disk-full claim. Never fills a disk.
"""
import errno
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(command, *, env=None, timeout=25):
    process = subprocess.Popen(list(map(str, command)), env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        # Every process in this new session belongs to this exact test call.
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        process.communicate()
        raise
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def checked(command, **kwargs):
    result = run(command, **kwargs)
    if result.returncode:
        raise RuntimeError(f'{command[0]} returned {result.returncode}: {result.stderr.decode(errors="replace")}')
    return result


def streams_complete(trace):
    streams = list(trace.glob('events-*.bin'))
    assert streams, 'no streams'
    for path in streams:
        data = path.read_bytes()
        assert data[:8] == b'GSPTRACE'
        position = struct.unpack_from('<I', data, 12)[0]
        ends = 0
        last = None
        while position < len(data):
            assert position + 24 <= len(data), 'torn record header'
            kind, _, size, _, _, _ = struct.unpack_from('<HHIQII', data, position)
            assert size >= 24 and size % 8 == 0 and position + size <= len(data), 'torn record'
            ends += kind == 18
            position += size
            last = kind
        assert ends == 1 and last == 18


def main():
    if len(sys.argv) != 3 or sys.platform != 'linux':
        raise SystemExit('usage: capture-threshold-checks.py GSTRACE OUTPUT_DIRECTORY (Linux)')
    checked([sys.executable, ROOT/'scripts/with-private-home.py', '--check'])
    cli = Path(sys.argv[1]).resolve(strict=True)
    output = Path(sys.argv[2]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='capture-', dir=output))
    env = dict(os.environ, GSP_AGENT_PATH=str(ROOT/'Runtime/obj/libgsperf-agent.so'))
    env['LD_LIBRARY_PATH'] = str(ROOT/'GSPerformance/obj') + ':' + env.get('LD_LIBRARY_PATH', '')
    compiler = shlex.split(os.environ.get('CC', 'cc'))
    io = work/'capture-io'
    target = work/'capture-target'
    checked([*compiler, '-O2', '-Wall', '-Wextra', ROOT/'Tests/fixtures/capture-io.c', '-o', io])
    checked([*compiler, '-O1', '-g', ROOT/'Tests/fixtures/capture-target.c', '-o', target])
    flags = shlex.split(checked(['gnustep-config', '--objc-flags']).stdout.decode())
    libs = shlex.split(checked(['gnustep-config', '--base-libs']).stdout.decode())
    driver = work/'capture-recorder'
    checked(['clang', '-I'+str(ROOT), '-I'+str(ROOT/'Runtime/include'), *flags, '-fobjc-arc',
             ROOT/'Tests/fixtures/capture-recorder.m', '-L'+str(ROOT/'GSPerformance/obj'),
             '-lGSPerformance', '-Wl,-rpath,'+str(ROOT/'GSPerformance/obj'), '-o', driver, *libs])
    checked([io])
    receipt = {'qualification': 'local source-built Linux checks, not strict quotas or actual ENOSPC integration',
               'agentSHA256': hashlib.sha256((ROOT/'Runtime/obj/libgsperf-agent.so').read_bytes()).hexdigest(),
               'cases': []}
    for mode, options, code, trigger, complete in [
        ('natural', ['--max-size', '64M'], 0, 'exited', True),
        ('churn', ['--max-size', '128K'], 0, 'max-size', True),
        ('ignore', ['--max-size', '128K'], 137, 'max-size', True),
        ('efbig', [], 1, 'error', False),
        ('efbig-exit3', [], 3, 'error', False),
        ('bad-status', [], 1, 'error', False),
        ('lost-status', [], 1, 'exited', False),
    ]:
        trace = work/(mode+'.gstrace')
        result = run([cli, 'record', '--instrument', 'time-profiler', '--instrument', 'allocations',
                      '--min-free', '0', '--output', trace, *options, '--launch', target, mode], env=env)
        (work/(mode+'.log')).write_bytes(result.stdout+result.stderr)
        assert result.returncode == code, (mode, result.returncode, code)
        view = checked([cli, 'info', trace], env=env).stdout.decode()
        assert f'StopTrigger: {trigger}\n' in view, (mode, view)
        assert f'CaptureStatus: {"complete" if complete else "incomplete"}\n' in view
        if complete:
            streams_complete(trace)
        if mode.startswith('efbig'):
            assert f'({errno.EFBIG}:' in view, view
            assert not list(trace.glob('events-*.done')), 'false success marker after EFBIG'
        if mode == 'bad-status': assert f'({errno.EPROTO}:' in view
        if mode == 'lost-status': streams_complete(trace) # END alone must not confer complete status
        total = sum(p.stat().st_size for p in trace.rglob('*') if p.is_file() and not p.is_symlink())
        receipt['cases'].append({'case': mode, 'cliExit': code, 'trigger': trigger,
                                 'captureComplete': complete, 'actualBundleBytes': total,
                                 'overshootBytes': max(0, total-128*1024) if '--max-size' in options and mode != 'natural' else None})
        print('ok -', mode, flush=True)
    # If a later filesystem error appears after the time limit, preserve the
    # earlier time-limit trigger while independently marking capture failure.
    for mode in ('preflight', 'crossing', 'disabled', 'override', 'stat-error', 'late-error', 'stdout'):
        trace, result_file = work/(mode+'.gstrace'), work/(mode+'.json')
        # Reuse the target: recorder seam supplies only filesystem readings.
        checked([driver, mode, target, trace, result_file], env=env)
        result = json.loads(result_file.read_text())
        if mode == 'preflight':
            assert not result['started'] and result['pid'] == 0 and result['errorCode'] == errno.ENOSPC
            assert result['error'] == ('Free space 1073741824 bytes is below recording floor 2147483648 bytes; '
                                       'use --min-free 0 to disable or --min-free <size> to override.')
            assert '\n' not in result['error']
            assert not trace.exists()
        else:
            assert result['started']
            assert result['trigger'] == {'crossing': 'min-free', 'stat-error': 'error', 'stdout': 'max-size'}.get(mode, 'time-limit')
            assert result['errorCode'] == (errno.EIO if mode in ('stat-error', 'late-error') else 0)
            if mode == 'disabled': assert result['floor'] == 0 and result['measurements'] == 0
            elif mode == 'override': assert result['floor'] == 1
            else: assert result['floor'] == 2 * 1073741824
            if mode not in ('stat-error', 'late-error'): streams_complete(trace)
            if mode == 'late-error':
                streams_complete(trace)
                view = checked([cli, 'info', trace], env=env).stdout.decode()
                assert 'StopTrigger: time-limit\n' in view and 'CaptureStatus: incomplete\n' in view
        receipt['cases'].append(dict(case='filesystem-'+mode, **result))
        print('ok - filesystem-'+mode, flush=True)
    if os.geteuid() == 0:
        raise RuntimeError('metadata-denied check requires an ordinary user, not a privileged test process')
    trace = work/'metadata-denied.gstrace'
    try:
        result = run([cli, 'record', '--instrument', 'time-profiler', '--min-free', '0',
                      '--output', trace, '--launch', target, 'metadata-denied'], env=env)
    finally:
        if trace.exists(): trace.chmod(0o700)
    (work/'metadata-denied.log').write_bytes(result.stdout+result.stderr)
    assert result.returncode == 1, result.stderr.decode(errors='replace')
    assert f'({errno.EACCES}:' in result.stderr.decode(), 'independent agent marker error not reported'
    assert not list(trace.glob('events-*.done'))
    streams_complete(trace) # END exists despite failed marker and metadata writes.
    view = checked([cli, 'info', trace], env=env).stdout.decode()
    assert 'CaptureStatus: unverified (trace metadata was not finalized)\n' in view
    receipt['cases'].append({'case': 'metadata-denied', 'cliExit': 1,
                             'metadataFinalized': False, 'rawStreamHasEND': True})
    print('ok - metadata-denied', flush=True)
    for index, bad in enumerate(('-1', '1.5M', '1KB', '18446744073709551616', '18446744073709551615G')):
        trace = work/f'bad-{index}.gstrace'
        result = run([cli, 'record', '--max-size', bad, '-o', trace, '--launch', target, 'churn'], env=env)
        assert result.returncode == 2 and not trace.exists()
    trace = work/'unsupported-follow.gstrace'
    result = run([cli, 'record', '--follow-children', '--max-size', '128K', '-o', trace,
                  '--launch', target, 'churn'], env=env)
    assert result.returncode == 1 and not trace.exists()
    (work/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print('All small capture-threshold checks passed. Evidence:', work)


if __name__ == '__main__':
    main()
