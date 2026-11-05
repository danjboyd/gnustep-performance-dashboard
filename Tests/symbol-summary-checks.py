#!/usr/bin/env python3
"""End-to-end CLI coverage checks with local synthetic trace streams only."""
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get("PD_TEST_GSTRACE", str(ROOT/"Tools/gstrace/obj/gstrace")))


def record(kind, payload=b"", aux=0, when=1000000000):
    size = (24 + len(payload) + 7) & ~7
    return struct.pack("<HHIQII", kind, 0, size, when, 4242, aux) + payload + bytes(size-24-len(payload))


def stack(frames, weight=0):
    return struct.pack("<IHH", len(frames), 0, weight) + struct.pack("<"+"Q"*len(frames), *frames)


def fixture(path, cpu=False, empty=False):
    path.mkdir()
    header = struct.pack("<8sIIIIQQIIII256s", b"GSPTRACE", 1, 312, 4242, 0,
                         1000000000, 0, 8, 1, 1000, 10000, b"/fixture/application")
    data = header + record(4, struct.pack("<QQQ", 0x1000000, 0x1000100, 0x1001000)+b"/missing/libpartial.so\0")
    data += record(6, stack([0xdeadbeef]), 99)  # deliberately unreferenced
    if not empty:
        data += record(6, stack([0x1000100, 0x1000201, 0]), 1)
        data += record(7, struct.pack("<QQIIQ", 0x1234, 16, 1, 0, 0))
        if cpu:
            data += record(5, stack([0x1000100, 0x1000201, 0], 3), 1)
            data += record(5, stack([0x1000100, 0x1000201, 0], 2), 1)
            data += record(5, stack([0x1000100, 0x1000201, 0], 99), 2)
    data += record(18, when=1001000000)
    (path/"events-4242.bin").write_bytes(data)
    (path/"Info.plist").write_bytes(plistlib.dumps({"TargetPID":4242,"Template":"Synthetic","Instruments":["allocations"]}))
    (path/"symbols-4242.plist").write_bytes(plistlib.dumps({"1000100":"resolved_function", "1000200":"libpartial.so+0x200", "0":"0x0"}))


def run(*args):
    p = subprocess.run([str(CLI), *map(str,args)], capture_output=True, text=True)
    assert p.returncode == 0, p.stderr
    return p.stdout


with tempfile.TemporaryDirectory(prefix="pd-symbol-cli-") as tmp:
    root=Path(tmp)
    for cpu in [False,True]:
        path=root/("cpu.gstrace" if cpu else "alloc.gstrace")
        fixture(path,cpu)
        info=run("info",path)
        assert "2 of 3 frames unresolved across 1 distinct referenced stacks" in info,info
        assert "libpartial.so: 1 of 2 unresolved" in info,info
        assert "[unknown image]: 1 of 1 unresolved" in info,info
        assert ("CPU-sample-weighted frames: 10 of 15 unresolved (weight 5" in info)==cpu,info
        assert "0/0" not in info
        report=run("report",path,"allocations","--symbol-summary")
        assert "Symbols:" in report and "Peak live heap:" in report
        assert "Symbols:" not in run("report",path,"allocations")
        csv=run("export",path,"--format","csv","--table","allocations")
        assert csv.startswith("time,free_time,address,size,category,tid,responsible\n"),csv
        assert "Symbols:" not in csv
        run("symbolicate",path,"--embed")
        after=run("info",path)
        assert [l for l in info.splitlines() if "Symbols:" in l]==[l for l in after.splitlines() if "Symbols:" in l]
        # GNUstep writes its legacy text plist; the unit test checks parsed keys.
        names=(path/"symbols-4242.plist").read_bytes()
        assert b"0x0" in names and b"ffffffffffffffff" not in names
        print("PASS", "CPU-weighted" if cpu else "Allocations-only", "summary/module/embedding/report/CSV checks")
    empty=root/"empty.gstrace";fixture(empty,empty=True)
    info=run("info",empty)
    assert "Symbols: no frames in referenced stacks." in info and "CPU-sample-weighted" not in info
    print("PASS unused definitions excluded and empty trace has no fabricated denominator")
print("All 3 CLI symbol-summary scenarios passed.")
