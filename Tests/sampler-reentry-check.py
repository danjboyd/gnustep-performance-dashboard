#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""End-to-end signal-unwinder safety regressions, Linux x86-64 only.

The controlled libunwind fixture allocates while creating a signal cursor and
rejects recursive unwinding. It tests the interposition boundary; it does not
pretend to reproduce any particular GUI application's crash. Separate bad-FP
cases reproduce the overflowing register value identified in the native core.
"""
import argparse
import os
from pathlib import Path
import re
import tempfile
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--gstrace', type=Path, default=ROOT / 'Tools/gstrace/obj/gstrace')
parser.add_argument('--agent', type=Path, default=ROOT / 'Runtime/obj/libgsperf-agent.so')
parser.add_argument('--output', type=Path, default=ROOT / 'Tests/out/sampler-reentry')
parser.add_argument('--case', choices=['all', 'reentry', 'invalid-fp'], default='all')
args = parser.parse_args()
if os.uname().sysname != 'Linux' or os.uname().machine != 'x86_64':
    raise SystemExit('This controlled libunwind ABI fixture requires Linux x86-64.')
args.output.mkdir(parents=True, exist_ok=True)
out = Path(tempfile.mkdtemp(prefix='run-', dir=args.output.resolve()))
print('Artifacts:', out)
shim = out / 'shim'
shim.mkdir()
subprocess.run(['cc', '-shared', '-fPIC', '-O2', '-g', '-fno-omit-frame-pointer',
                '-fno-builtin-malloc', '-fno-builtin-free',
                str(ROOT / 'Tests/fixtures/allocating-unwinder.c'),
                '-o', str(shim / 'libunwind.so.8')], check=True)
subprocess.run(['cc', '-O2', '-g', '-fno-omit-frame-pointer',
                str(ROOT / 'Tests/fixtures/unwinder-reentry-target.c'),
                '-o', str(out / 'target'), '-ldl'], check=True)
env = dict(os.environ, GSP_AGENT_PATH=str(args.agent.resolve()))
scenarios = [('cpu', ['time-profiler']), ('alloc', ['allocations']),
                          ('combined', ['time-profiler', 'allocations']),
                          ('wall-alloc', ['hangs', 'allocations'])]
invalid_scenarios = [('invalid-fp-cpu', ['time-profiler', 'allocations']),
                     ('invalid-fp-wall', ['hangs', 'allocations'])]
scenarios = (scenarios if args.case == 'reentry' else invalid_scenarios
             if args.case == 'invalid-fp' else scenarios + invalid_scenarios)
for mode, instruments in scenarios:
    trace = out / (mode + '.gstrace')
    command = [str(args.gstrace.resolve()), 'record', '--output', str(trace),
               '--sample-interval', '4ms', '--env', 'LD_LIBRARY_PATH=' + str(shim)]
    if mode.startswith('invalid-fp-'):
        command += ['--env', 'CONTROLLED_INVALID_FP=' + mode.removeprefix('invalid-fp-')]
    for instrument in instruments:
        command += ['--instrument', instrument]
    command += ['--launch', str(out / 'target')]
    result = subprocess.run(command, env=env, text=True, capture_output=True, timeout=30)
    (out / (mode + '.log')).write_text(result.stdout + result.stderr)
    assert result.returncode == 0, (mode, result.returncode, result.stderr)
    assert 'CONTROLLED_REENTRANT_UNWINDER' not in result.stderr, mode
    info = (trace / 'Info.plist').read_text()
    status = re.search(r'ExitStatus\s*=\s*<\*I(-?\d+)>', info)
    assert status and int(status[1]) == 0, (mode, 'target did not exit normally')
    if mode.startswith('invalid-fp-'):
        assert 'CONTROLLED_INVALID_FP_SAMPLE_RETURNED' in result.stderr, mode
    cpu = wall = allocations = ended = 0
    allocation_sizes = set()
    streams = list(trace.glob('events-*.bin'))
    assert len(streams) == 1, (mode, len(streams))
    with streams[0].open('rb') as stream:
        header = stream.read(312)
        assert header[:8] == b'GSPTRACE'
        stream.seek(struct.unpack_from('<I', header, 12)[0])
        while True:
            record = stream.read(24)
            if not record:
                break
            assert len(record) == 24, (mode, 'short record')
            kind, flags, size, timestamp, tid, aux = struct.unpack('<HHIQII', record)
            assert size >= 24 and size % 8 == 0
            payload = stream.read(size - 24)
            assert len(payload) == size - 24
            if kind == 5:
                cpu += aux == 1
                wall += aux == 2
            elif kind == 7:
                allocations += 1
                allocation_sizes.add(struct.unpack_from('<Q', payload, 8)[0])
                # The fixture's distinctive 7897-byte allocations are internal.
                if 'allocations' in instruments:
                    assert struct.unpack_from('<Q', payload, 8)[0] != 7897, mode
            elif kind == 17:
                assert struct.unpack_from('<Q', payload)[0] == 0, (mode, 'dropped events')
            elif kind == 18:
                ended += 1
    assert ended == 1, (mode, ended)
    assert bool(cpu) == ('time-profiler' in instruments), (mode, cpu)
    assert bool(wall) == ('hangs' in instruments), (mode, wall)
    assert bool(allocations) == ('allocations' in instruments), (mode, allocations)
    if 'allocations' in instruments:
        assert 12345 in allocation_sizes, (mode, 'ordinary allocations disabled after sampling')
    print(f'{mode}: target exited0; CPU={cpu} wall={wall} allocations={allocations}; no unwinder re-entry')
print(f'All {len(scenarios)} sampler safety scenarios passed.')
