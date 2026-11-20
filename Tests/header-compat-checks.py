#!/usr/bin/env python3
"""Legacy/current/future header offsets in dump tool and completed capture."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'Tools/gstrace/obj/gstrace'
with tempfile.TemporaryDirectory(prefix='pd-header-compat-') as tmp:
    tmp = Path(tmp)
    dump = tmp/'gsp-dump'
    agent = tmp/'header-writer.so'
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-I'+str(ROOT/'Runtime/include'), str(ROOT/'Tools/gsp-dump.c'), '-o', str(dump)], check=True)
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', '-shared', '-fPIC', '-I'+str(ROOT/'Runtime/include'), str(ROOT/'Tests/fixtures/header-writer.c'), '-o', str(agent)], check=True)
    for size in (312, 320, 328):
        trace = tmp/f'header-{size}.gstrace'
        env = dict(os.environ, GSP_AGENT_PATH=str(agent))
        p = subprocess.run([str(CLI), 'record', '--output', str(trace), '--env', f'PD_FIXTURE_HEADER_SIZE={size}', '--launch', '/bin/true'], env=env, text=True, capture_output=True)
        assert p.returncode == 0, (size, p.stdout, p.stderr)
        info = subprocess.check_output([str(CLI), 'info', str(trace)], text=True)
        assert 'CaptureStatus: complete' in info, info
        stream = next(trace.glob('events-*.bin'))
        data = stream.read_bytes()
        # Include known last types and an unknown future type to exercise names bounds.
        records = b''.join(struct.pack('<HHIQII', kind, 0, 24, 1000000000, 42, 0) for kind in (21, 22, 23, 60000, 18))
        stream.write_bytes(data[:size]+records)
        output = subprocess.check_output([str(dump), str(stream), '-v'], text=True)
        for name in ('IO', 'DIAGNOSTIC', 'THREAD_STATE', '?', 'END'):
            assert name in output, output
        assert 'END        1' in output, output
    bad = tmp/'bad.gstrace'
    p = subprocess.run([str(CLI), 'record', '--output', str(bad), '--env', 'PD_FIXTURE_HEADER_SIZE=304', '--launch', '/bin/true'], env=env, text=True, capture_output=True)
    assert p.returncode != 0, p.stdout + p.stderr
print('Header compatibility checks passed (312/320/328, recorder receipt, dump names/offsets, invalid header)')
