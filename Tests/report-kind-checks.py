#!/usr/bin/env python3
"""Mixed synthetic samples: selection, timer weights, old v1 compatibility."""
import plistlib
from pathlib import Path
import struct
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / 'Tools/gstrace/obj/gstrace'
with tempfile.TemporaryDirectory(prefix='pd-report-kind-') as tmp:
    trace = Path(tmp) / 'mixed.gstrace'
    trace.mkdir()
    header = struct.pack('<8sIIIIQQIIII256s', b'GSPTRACE', 1, 312, 42, 0, 1000000000, 0, 8, 1, 1000, 10000, b'/synthetic')
    records = []
    def emit(kind, tid, aux=0, payload=b''):
        size = (24 + len(payload) + 7) & ~7
        records.append(struct.pack('<HHIQII', kind, 0, size, 1001000000, tid, aux) + payload + bytes(size - 24 - len(payload)))
    for tid, name in ((42, b'main'), (43, b'worker'), (44, b'worker')):
        emit(2, tid, int(tid == 42), name + b'\0')
    for pc, name in ((0x1000, b'cpu_only'), (0x2000, b'wall_only'), (0x3000, b'other_worker')):
        emit(15, 0, payload=struct.pack('<Q', pc) + name + b'\0')
    for tid, kind, weight, pc in ((42, 1, 3, 0x1000), (43, 2, 7, 0x2000), (44, 2, 2, 0x3000)):
        emit(5, tid, kind, struct.pack('<IHHQ', 1, 0, weight, pc))
    emit(18, 42)
    (trace / 'events-42.bin').write_bytes(header + b''.join(records))
    (trace / 'Info.plist').write_bytes(plistlib.dumps({'TargetPID': 42, 'Template': 'Synthetic'}))
    def run(*args, code=0):
        p = subprocess.run([str(CLI), *map(str, args)], text=True, capture_output=True)
        assert p.returncode == code, (p.returncode, p.stdout, p.stderr)
        return p.stdout + p.stderr
    cpu = run('report', trace, 'top')
    assert 'cpu_only' in cpu and 'wall_only' not in cpu and 'other_worker' not in cpu, cpu
    wall = run('report', trace, 'top', '--kind', 'wall', '--thread', 'worker')
    assert 'wall_only' in wall and 'other_worker' in wall and 'cpu_only' not in wall, wall
    assert '90' in wall and 'sampled thread wall time' in wall, wall
    one = run('report', trace, 'top', '--kind', 'wall', '--thread', '43')
    assert 'wall_only' in one and 'other_worker' not in one, one
    assert 'other_worker' in run('report', trace, 'top', '--kind', 'wall', '--thread', 'all')
    for kind in ('wall-blocked', 'wall-running'):
        assert 'this trace has no blocked/running flags' in run('report', trace, 'top', '--kind', kind, code=1)
    run('report', trace, 'top', '--kind', 'wat', code=2)
    run('report', trace, 'top', '--thread', 'nope', code=2)
    run('report', trace, 'top', '--thread', 'all', '--thread', '43', code=2)
    info = run('info', trace)
    assert 'cpu 3; wall 0;' in info and 'cpu 0; wall 7;' in info and 'thread states: not recorded' in info, info
    prefix = struct.pack('<8sIIIIQQIIII256sII', b'GSPTRACE', 1, 320, 42, 0, 1000000000, 0, 8, 1, 1000, 10000, b'/synthetic', 10000, 0)
    records = []
    emit(2, 43, payload=b'worker\0')
    emit(23, 43, ord('S'), struct.pack('<QII', 1000000000, 80, 0))
    emit(23, 43, ord('R'), struct.pack('<QII', 1000000000, 20, 0))
    emit(22, 42, 3, b'Thread-state polling disabled: errno 24 (Too many open files).\0')
    emit(18, 42)
    (trace / 'events-42.bin').write_bytes(prefix + b''.join(records))
    info = run('info', trace)
    assert 'disabled at 0.001s' in info and 'errno 24 (Too many open files)' in info, info
    assert '100 polls' in info and 'S 80.0%' in info and 'runnable) 20.0%' in info, info
    assert 'no /proc' not in info, info
print('Report kind/thread checks passed (mixed legacy trace, weights, names, flags absent)')
