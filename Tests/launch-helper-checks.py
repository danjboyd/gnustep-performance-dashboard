#!/usr/bin/env python3
"""Bounded libc trampoline transport checks, without an agent or GUI."""
import array
import errno
import json
import os
from pathlib import Path
import resource
import socket
import signal
import struct
import subprocess
import sys
import tempfile

HELPER = str(Path(sys.argv[1]).resolve())
HEADER = struct.Struct("=8IQ")
REPLY = struct.Struct("=Ii")
MAGIC = 0x47534C31


def launch(strings, argc, envc, fds, mask=7, *, magic=MAGIC, ignored=0, send_payload=True):
    parent, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_SEQPACKET)
    parent.settimeout(3)
    # Deliberately inherit an unrelated descriptor above NSTask's close range;
    # the trampoline must close it too.
    leak = os.open("/dev/null", os.O_RDONLY)
    high = __import__("fcntl").fcntl(leak, __import__("fcntl").F_DUPFD, 300)
    proc = subprocess.Popen([HELPER], stdin=child, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL, env={}, pass_fds=(high,))
    child.close()
    os.close(leak)
    os.close(high)
    payload = b"\0".join(s.encode() for s in strings) + b"\0"
    try:
        header = HEADER.pack(magic, 1, len(payload), argc, envc, mask, 0, 0, ignored)
        parent.sendmsg([header], [(socket.SOL_SOCKET, socket.SCM_RIGHTS,
                                   array.array("i", fds))])
        if magic == MAGIC and send_payload:
            for offset in range(0, len(payload), 16384):
                parent.sendall(payload[offset:offset + 16384])
        first = REPLY.unpack(parent.recv(REPLY.size))
        second = parent.recv(REPLY.size) if first == (1, 0) else None
        return proc, first, second
    except BaseException:
        proc.kill()
        proc.wait(timeout=3)
        raise
    finally:
        parent.close()


with tempfile.TemporaryDirectory(prefix="pd-launch-test-") as directory:
    root = Path(directory)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    null = os.open("/dev/null", os.O_RDWR)
    status_parent, status_child = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
    status_parent.settimeout(3)
    stdin = os.open(root / "stdin", os.O_RDWR | os.O_CREAT, 0o600)
    os.write(stdin, b"hello input\n")
    os.lseek(stdin, 0, 0)
    output = os.open(root / "out", os.O_RDWR | os.O_CREAT, 0o600)
    target = r"""
import json, os, socket, sys
fd = socket.socket(fileno=4)
fd.send(b'writer-receipt')
# fstat rather than listdir's own transient enumeration fd.
fds = []
for value in os.listdir('/proc/self/fd'):
    try: os.fstat(int(value))
    except OSError: continue
    fds.append(int(value))
print(json.dumps(dict(argv=sys.argv[1:],cwd=os.getcwd(),env=dict(os.environ),
  input=sys.stdin.readline(),fds=sorted(fds),pid=os.getpid())), flush=True)
print('stderr too', file=sys.stderr)
"""
    args = [sys.executable, "-c", target, "spaced arg", "üñîcode", ""]
    env = ["PD_EMPTY=", "PD_VALUE=" + "x" * 40000, "GSP_STATUS_FD=4"]
    proc, reply, eof = launch([str(root)] + args + env, len(args), len(env),
                              [stdin, output, output, status_child.fileno()])
    assert reply == (1, 0) and eof == b"", (reply, eof)
    assert proc.wait(timeout=3) == 0
    assert status_parent.recv(100) == b"writer-receipt"
    lines = (root / "out").read_text().splitlines()
    result = json.loads(lines[0])
    assert result["argv"] == ["spaced arg", "üñîcode", ""]
    assert result["cwd"] == str(root) and result["input"] == "hello input\n"
    assert result["env"]["PD_EMPTY"] == "" and result["env"]["PD_VALUE"] == "x" * 40000
    assert "PD_UNSET" not in result["env"] and "LD_PRELOAD" not in result["env"]
    assert result["fds"] == [0, 1, 2, 4], result["fds"]
    assert result["pid"] == proc.pid and lines[1] == "stderr too"
    print("PASS same PID, argv/cwd/env/stdio, chunked payload, writer FD, no extra FDs")
    for executable, cwd, expected in [("/no/such/pd-target", "", errno.ENOENT),
                                       ("/bin/true", "/no/such/pd-cwd", errno.ENOENT)]:
        proc, first, second = launch([cwd, executable], 1, 0,
                                    [null, null, null, status_child.fileno()])
        actual = REPLY.unpack(second)[1] if second else first[1]
        assert actual == expected and proc.wait(timeout=3) == 125, (first, second)
    print("PASS exec and cwd failures distinguish startup from target exit")
    proc, first, second = launch(["", "/bin/true"], 1, 0,
                                [null, null, null, status_child.fileno()], magic=0)
    assert first == (0, errno.EPROTO) and proc.wait(timeout=3) == 125
    # Invalid ancillary framing is rejected before payload reads. Sending a
    # payload here races close with unread SOCK_SEQPACKET data and can reset
    # the socket before the parent receives the explicit EPROTO reply.
    proc, first, second = launch(["", "/bin/true"], 1, 0, [status_child.fileno()],
                                 send_payload=False)
    assert first == (0, errno.EPROTO) and proc.wait(timeout=3) == 125
    print("PASS malformed framing and incomplete SCM_RIGHTS fail closed")
    args = [sys.executable, "-c", "import os; assert not os.path.exists('/proc/self/fd/0')"]
    proc, first, second = launch([""] + args, len(args), 0,
                                [null, null, status_child.fileno()], mask=6)
    assert first == (1, 0) and second == b"" and proc.wait(timeout=3) == 0
    print("PASS closed target stdin preserved")
    args = [sys.executable, "-c", "import signal; assert signal.getsignal(signal.SIGUSR1) == signal.SIG_IGN"]
    proc, first, second = launch([""] + args, len(args), 0,
                                [null, null, null, status_child.fileno()],
                                ignored=1 << (signal.SIGUSR1 - 1))
    assert first == (1, 0) and second == b"" and proc.wait(timeout=3) == 0
    print("PASS ignored-signal disposition restored after NSTask reset")
    proc, first, second = launch(["", "/bin/true"], 1, 0,
                                [null, null, null, status_child.fileno()],
                                ignored=sum(1 << (n - 1) for n in (9, 19, 32, 33)))
    assert first == (1, 0) and second == b"" and proc.wait(timeout=3) == 0
    print("PASS unchangeable/reserved ignored-signal bits skipped on EINVAL")
    proc, first, second = launch(["/bin", "true", "PATH=/bin"], 1, 1,
                                [null, null, null, status_child.fileno()])
    assert first == (0, errno.EINVAL) and proc.wait(timeout=3) == 125
    print("PASS bare executable rejected without PATH lookup")
    for fd in [null, stdin, output]:
        os.close(fd)
    status_parent.close()
    status_child.close()
print("All launch-helper checks passed (9 bounded child processes).")
