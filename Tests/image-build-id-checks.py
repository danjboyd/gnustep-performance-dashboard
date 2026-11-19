#!/usr/bin/env python3
"""Linux agent/reader identity contract; synthetic workload plus a pinned cached legacy reader."""
import legacy_reader
import os
import platform
from pathlib import Path
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get('PD_TEST_GSTRACE', ROOT / 'Tools/gstrace/obj/gstrace'))
EXPECTED = '11223344556677889900aabbccddeeff01020304'

def run(args):
    result = subprocess.run(list(map(str, args)), capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout

with tempfile.TemporaryDirectory(prefix='pd-loaded-id-') as directory:
    work = Path(directory)
    notes = work / 'elf-notes'
    run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror',
         ROOT / 'Tests/fixtures/elf-build-id-notes.c', '-o', notes])
    print(run([notes]).strip())
    source = work / 'target.c'
    target = work / 'target'
    source.write_text('#include <time.h>\n#include <stdint.h>\n'
        'static __attribute__((noinline)) void spin(void) {\n'
        'struct timespec a,b; clock_gettime(CLOCK_MONOTONIC,&a);\n'
        'volatile uint64_t n=0; do { for(int k=0;k<10000;k++) n+=k;\n'
        'clock_gettime(CLOCK_MONOTONIC,&b); } while((b.tv_sec-a.tv_sec)*1e9+b.tv_nsec-a.tv_nsec<150000000); }\n'
        'int main(void) { spin(); return 0; }\n')
    run(['cc', '-O1', '-g', '-fno-omit-frame-pointer', '-Wl,--build-id=0x'+EXPECTED, source, '-o', target])
    trace = work / 'capture.gstrace'
    run([CLI, 'record', '--instrument', 'time-profiler', '--min-free', '0', '--output', trace, '--launch', target])
    stream = next(trace.glob('events-*.bin')).read_bytes()
    offset = struct.unpack_from('<I', stream, 12)[0]
    images = []
    while offset + 24 <= len(stream):
        kind, flags, size, when, tid, aux = struct.unpack_from('<HHIQII', stream, offset)
        assert size >= 24 and size % 8 == 0 and offset+size <= len(stream)
        payload = stream[offset+24:offset+size]
        if kind == 4:
            end = payload.index(b'\0', 24)
            path = payload[24:end].decode()
            if aux & 0x80000000:
                magic, version, length = struct.unpack_from('<IHH', payload, end+1)
                assert magic == 0x44495347 and version == 1 and 1 <= length <= 64
                identifier = payload[end+9:end+9+length].hex()
                images.append((path,identifier))
            # This is precisely how an old reader sees the unchanged path.
            assert payload[24:].split(b'\0',1)[0].decode() == path
        offset += size
    assert (str(target), EXPECTED) in images, images
    info = run([CLI, 'info', trace])
    assert re.search(r'image build IDs: [1-9][0-9]* of [0-9]+ recorded; 0 invalid/ambiguous', info), info
    assert 'CaptureStatus: complete' in info and 'Exit status: 0' in info, info
    if platform.machine() == 'x86_64':
        legacy = os.environ.get('PD_LEGACY_GSTRACE') or legacy_reader.prepare(work / 'legacy')
        old = run([legacy, 'info', trace])
        assert str(target) in old and 'CaptureStatus: complete' in old, old
        print('PASS published legacy reader opens new IMAGE suffix')
    else:
        print('SKIP published legacy reader: fixture is x86_64 only; native IMAGE checks retained')
    run([CLI, 'symbolicate', trace, '--embed'])
    assert 'Symbols:' in run([CLI, 'info', trace])
    dependencies = run(['readelf', '-d', ROOT/'Runtime/obj/libgsperf-agent.so'])
    needed = re.findall(r'\(NEEDED\).*?\[([^]]+)\]', dependencies)
    assert needed and all(name in {'libc.so.6', 'libdl.so.2', 'libpthread.so.0'} or re.fullmatch(r'ld-linux[^/]*\.so\.[12]', name) for name in needed), needed
    print('PASS loaded GNU build ID matches explicit linked ID; new reader/snapshot and libc-only agent')
