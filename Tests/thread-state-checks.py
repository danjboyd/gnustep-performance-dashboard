#!/usr/bin/env python3
"""Live Linux writer/reader contract; no signals enabled in the fixture."""
import os
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REC = struct.Struct('<HHIQII')

with tempfile.TemporaryDirectory(prefix='pd-thread-states-') as tmp:
    tmp = Path(tmp)
    source = tmp / 'worker.c'
    source.write_text('''#define _GNU_SOURCE
#include <pthread.h>
#include <sys/prctl.h>
#include <unistd.h>
static void *worker(void *p) { (void)p; prctl(PR_SET_NAME, "wait) worker"); usleep(1350000); return 0; }
int main(void) { pthread_t t; pthread_create(&t, 0, worker, 0); pthread_join(t, 0); usleep(40000); return 0; }
''')
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', str(source), '-pthread', '-o', str(tmp / 'worker')], check=True)
    trace = tmp / 'states.gstrace'
    subprocess.run([str(ROOT / 'Tools/gstrace/obj/gstrace'), 'record', '--thread-states', '--output', str(trace), '--launch', str(tmp / 'worker')], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    streams = list(trace.glob('events-*.bin'))
    assert len(streams) == 1, streams
    data = streams[0].read_bytes()
    offset = struct.unpack_from('<I', data, 12)[0]
    assert offset >= 320
    assert struct.unpack_from('<I', data, 312)[0] == 10000
    names, states = {}, []
    while offset + REC.size <= len(data):
        kind, flags, size, stamp, tid, aux = REC.unpack_from(data, offset)
        assert size >= REC.size and offset + size <= len(data)
        payload = data[offset + REC.size:offset + size]
        if kind == 2:
            names[tid] = payload.split(b'\0')[0]
        elif kind == 23:
            first, count, reserved = struct.unpack_from('<QII', payload)
            assert first <= stamp and not reserved
            states.append((tid, aux, count, stamp))
        offset += size
    # Thread definition precedes prctl name change: identify the exited non-main.
    main = struct.unpack_from('<I', data, 16)[0]
    worker = next(tid for tid in names if tid != main)
    observed = [s for s in states if s[0] == worker]
    assert any(s[1] == ord('S') and s[2] > 50 for s in observed), observed
    assert observed[-1][1:] == (ord('X'), 0, observed[-1][3]), observed
    assert 70 <= sum(s[2] for s in observed) <= 180, observed
    assert not any(name == b'gsp-writer' for name in names.values())
    info = subprocess.check_output([str(ROOT / 'Tools/gstrace/obj/gstrace'), 'info', str(trace)], text=True)
    assert 'share of polls' in info and 'R (running or runnable)' in info, info
    # Explicit opt-in: a regular recording keeps the header interval zero.
    plain = tmp / 'plain.gstrace'
    subprocess.run([str(ROOT / 'Tools/gstrace/obj/gstrace'), 'record', '--output', str(plain), '--launch', '/bin/true'], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    info = subprocess.check_output([str(ROOT / 'Tools/gstrace/obj/gstrace'), 'info', str(plain)], text=True)
    assert 'thread states: not recorded' in info
print('Thread-state live checks passed (keyframe, exit, poll weights, opt-in, reader)')
