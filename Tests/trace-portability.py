#!/usr/bin/env python3
"""Check portable traces, or capture/verify native traces on another host.

Synthetic bytes use the documented little-endian v1 format independently of
the host C ABI. Native captures contain fixture recordings only, with embedded
symbols and a JSON baseline; they never bundle the target executable.
"""

import argparse
import hashlib
import json
import math
import pathlib
import plistlib
import shutil
import struct
import subprocess
import tempfile


def invoke(cli, *args, success=True):
    result = subprocess.run([str(cli), *map(str, args)], capture_output=True,
                            text=True, encoding="utf-8", timeout=90)
    if success and result.returncode:
        raise RuntimeError(f"gstrace {args}: {result.stderr}")
    return result


def summary(cli, trace):
    return json.loads(invoke(cli, "export", trace, "--format", "json").stdout)


def canonical(value):
    if isinstance(value, dict):
        return {key: canonical(item) for key, item in value.items()}
    if isinstance(value, list):
        items = [canonical(item) for item in value]
        return sorted(items, key=lambda item: json.dumps(item, sort_keys=True))
    return value


def equivalent(expected, actual, where="summary"):
    if isinstance(expected, dict):
        assert isinstance(actual, dict) and expected.keys() == actual.keys(), where
        for key in expected:
            equivalent(expected[key], actual[key], where + "." + key)
    elif isinstance(expected, list):
        assert isinstance(actual, list) and len(expected) == len(actual), where
        for index, (a, b) in enumerate(zip(expected, actual)):
            equivalent(a, b, f"{where}[{index}]")
    elif isinstance(expected, float):
        assert math.isclose(expected, actual, rel_tol=1e-10, abs_tol=1e-12), where
    else:
        assert expected == actual, f"{where}: {expected!r} != {actual!r}"


def check_exports(cli, trace):
    for format_name in ("chrome", "speedscope"):
        data = json.loads(invoke(cli, "export", trace, "--format", format_name).stdout)
        assert data, format_name
    assert invoke(cli, "export", trace, "--format", "collapsed").stdout.strip()
    invoke(cli, "diff", trace, trace)


def synthetic(directory, windows=False, incomplete=False, unavailable=False):
    directory.mkdir()
    exe = "C:/Portable Tests/Échantillon.exe" if windows else "/nonexistent/Échantillon"
    pid, tid, start, base = 4242, 70001, 1_000_000_000, 0x140000000
    header = struct.pack("<8sIIIIQQIIII256s", b"GSPTRACE", 1, 312, pid, 0,
                         start, 0, 8, 1, 1000, 10000, exe.encode())
    assert len(header) == 312
    records = []

    def emit(kind, time=0, aux=0, payload=b""):
        length = (24 + len(payload) + 7) & ~7
        records.append(struct.pack("<HHIQII", kind, 0, length, start + time,
                                   tid, aux) + payload + bytes(length - 24 - len(payload)))

    def text(value):
        return value.encode("utf-8") + b"\0"

    emit(2, aux=1, payload=text("Main – portable"))
    emit(4, payload=struct.pack("<QQQ", base, base + 0x1000, base + 0x4000) + text(exe))
    frames = struct.pack("<QQ", base + 0x2010, base + 0x1010)
    # Uses precede string/stack definitions, as real per-thread ring flushes can.
    emit(5, 20_000_000, 1, struct.pack("<IHH", 2, 0, 2) + frames)
    emit(5, 10_000_000, 1, struct.pack("<IHH", 2, 0, 3) + frames)
    emit(7, 2_000_000, payload=struct.pack("<QQIIQ", 0x180000100, 4096, 7, 1, 0))
    emit(7, 3_000_000, payload=struct.pack("<QQIIQ", 0x180000200, 64, 7, 0, 0))
    emit(8, 4_000_000, payload=struct.pack("<QII", 0x180000200, 7, 0))
    for kind, time in ((1, 5_000_000), (2, 15_000_000)):
        emit(11, time, kind, struct.pack("<QIIII", 0x100000001, 0, 2, 3, 0) + b"\0")
    for identifier, value in ((1, "PortableWidget"), (2, "PointsOfInterest"), (3, "Round")):
        emit(1, aux=identifier, payload=text(value))
    emit(6, aux=7, payload=struct.pack("<IHH", 2, 0, 0) + frames)
    emit(15, payload=struct.pack("<Q", base + 0x1000) + text("main"))
    emit(15, payload=struct.pack("<Q", base + 0x2000) + text("-[PortableWorker crunch:]"))
    if unavailable:
        emit(22, 25_000_000, 1, text("Leak scan unavailable: synthetic access denial."))
    else:
        emit(12, 25_000_000, 1, struct.pack("<QQQ", 1, 4096, 0))
        emit(13, 25_000_000, 1, struct.pack("<QQIIII", 0x180000100, 4096, 7, 1, 1, 0))
        emit(14, 25_000_000, 1, struct.pack("<QQQ", 1, 4096, 100))
    # Future records must be skipped without losing alignment or later records.
    emit(60000, 26_000_000, payload=b"future record")
    if not incomplete:
        emit(18, 30_000_000)
    else:
        records.append(struct.pack("<HHI", 5, 0, 48))  # torn final header
    (directory / f"events-{pid}.bin").write_bytes(header + b"".join(records))
    (directory / "Info.plist").write_bytes(plistlib.dumps({
        "Template": "Portable", "TargetPID": pid, "TargetPath": exe,
        "Instruments": ["time-profiler", "allocations", "leaks", "points-of-interest"],
    }))
    return exe


def check_synthetic(cli):
    with tempfile.TemporaryDirectory(prefix="gsp-portable-") as temporary:
        root = pathlib.Path(temporary)
        for windows in (False, True):
            for state in ("complete", "incomplete", "unavailable"):
                trace = root / f"{'windows' if windows else 'linux'}-{state}.gstrace"
                exe = synthetic(trace, windows, state == "incomplete", state == "unavailable")
                result = summary(cli, trace)
                assert result["executable"] == exe
                assert result["cpuSamples"] == 5 and result["cpuSeconds"] == 0.005
                assert result["finishedCleanly"] == (state != "incomplete")
                assert result["leakScanUnavailable"] == (state == "unavailable")
                assert result["peakLiveBytes"] == 4160
                assert result["allocations"][0]["category"] == "All Heap Allocations"
                assert result["allocations"][0]["persistentBytes"] == 4096
                assert any(t["tid"] == 70001 for t in result["threads"])
                assert result["topFunctions"][0]["symbol"] == "-[PortableWorker crunch:]"
                assert result["topFunctions"][0]["image"] == exe.rsplit("/", 1)[-1]
                assert result["signposts"][0]["count"] == 1
                assert math.isclose(result["signposts"][0]["totalDuration"], 0.01)
                if state == "unavailable":
                    assert "leaks" not in result and result["warnings"]
                    assert invoke(cli, "report", trace, "leaks", success=False).returncode != 0
                else:
                    assert result["leaks"] == [{"category": "PortableWidget", "count": 1, "bytes": 4096}]
                if state == "incomplete":
                    assert result["warnings"]
                # Portable symbol sidecars must give the same report as METHOD records.
                invoke(cli, "symbolicate", trace, "--embed")
                equivalent(canonical(result), canonical(summary(cli, trace)))
                if state != "unavailable":
                    check_exports(cli, trace)
                print(f"ok - portable {trace.stem}", flush=True)
    print("All 6 synthetic trace portability checks passed.")


def capture(cli, trace, output):
    output.mkdir(parents=True, exist_ok=False)
    saved = output / "recording.gstrace"
    shutil.copytree(trace, saved)
    invoke(cli, "symbolicate", saved, "--embed")
    baseline = summary(cli, saved)
    assert baseline["finishedCleanly"] and baseline["cpuSamples"] > 0
    check_exports(cli, saved)
    (output / "summary.json").write_text(json.dumps(baseline, indent=2), encoding="utf-8")
    hashes = {p.relative_to(output).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in output.rglob("*") if p.is_file()}
    (output / "hashes.json").write_text(json.dumps(hashes, indent=2), encoding="utf-8")
    print("Captured portable native fixture:", output)


def verify(cli, bundle):
    for name, digest in json.loads((bundle / "hashes.json").read_text()).items():
        path = (bundle / name).resolve()
        assert path.is_relative_to(bundle.resolve()), name
        assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, name
    trace = bundle / "recording.gstrace"
    expected = json.loads((bundle / "summary.json").read_text(encoding="utf-8"))
    equivalent(canonical(expected), canonical(summary(cli, trace)))
    check_exports(cli, trace)
    print("Native trace summary and exports match on this host:", bundle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gstrace", required=True, type=pathlib.Path)
    command = parser.add_mutually_exclusive_group(required=True)
    command.add_argument("--synthetic", action="store_true")
    command.add_argument("--capture", type=pathlib.Path)
    command.add_argument("--verify", type=pathlib.Path)
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    cli = args.gstrace.resolve()
    if args.synthetic:
        check_synthetic(cli)
    elif args.capture:
        if args.output is None:
            parser.error("--capture needs --output (a new directory)")
        capture(cli, args.capture.resolve(), args.output.resolve())
    else:
        verify(cli, args.verify.resolve())


if __name__ == "__main__":
    main()
