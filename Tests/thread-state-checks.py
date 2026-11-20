#!/usr/bin/env python3
"""Live Linux writer/reader contract; no signals enabled in the fixture."""
import os
import shutil
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REC = struct.Struct('<HHIQII')

with tempfile.TemporaryDirectory(prefix='pd-thread-states-') as tmp:
    tmp = Path(tmp)
    parser = tmp / 'parser.c'
    parser.write_text('''#include <assert.h>
#include <GSPerformance/gsp_format.h>
#include "gsp_thread_states.h"
static int fake_error = ESRCH;
static ssize_t failed_read(int fd, void *data, size_t length)
{ (void)fd; (void)data; (void)length; errno = fake_error; return -1; }
static int changed_errno_close(int fd) { (void)fd; errno = EBADF; return 0; }
int main(void) {
  assert(gsp_read_proc_state(3, failed_read, changed_errno_close) == GSP_STATE_EXITED);
  fake_error = EIO;
  assert(gsp_read_proc_state(3, failed_read, changed_errno_close) == GSP_STATE_UNKNOWN);
  assert(gsp_proc_state("12 (wait) worker) S 1 2") == 'S');
  assert(gsp_proc_state("12 (gone) X 1 2") == GSP_STATE_EXITED);
  assert(gsp_proc_state("12 (cut) ") == GSP_STATE_UNKNOWN);
  assert(gsp_proc_state("no proc fields") == GSP_STATE_UNKNOWN);
  return 0;
}
''')
    subprocess.run(['cc', '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-I' + str(ROOT / 'Runtime/include'), '-I' + str(ROOT / 'Runtime'), str(parser), '-o', str(tmp / 'parser')], check=True)
    subprocess.run([str(tmp / 'parser')], check=True)
    source = tmp / 'worker.c'
    source.write_text('''#define _GNU_SOURCE
#include <pthread.h>
#include <sys/prctl.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <time.h>
#include <errno.h>
static int raw_exit;
static void pause_for(long ns) {
  struct timespec deadline;
  clock_gettime(CLOCK_MONOTONIC, &deadline);
  deadline.tv_sec += ns / 1000000000;
  deadline.tv_nsec += ns % 1000000000;
  if (deadline.tv_nsec >= 1000000000) { deadline.tv_nsec -= 1000000000; deadline.tv_sec++; }
  while (clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &deadline, 0) == EINTR) { }
}
static void *worker(void *p) {
  (void)p; prctl(PR_SET_NAME, "wait) worker"); pause_for(1350000000);
  if (raw_exit) syscall(SYS_exit, 0); /* Bypass agent pthread cleanup deliberately. */
  return 0;
}
int main(int argc, char **argv) {
  (void)argv; raw_exit = argc > 1;
  pthread_t t; pthread_create(&t, 0, worker, 0); pthread_join(t, 0);
  pause_for(250000000); return 0;
}
''')
    subprocess.run(['cc', '-Wall', '-Wextra', '-Werror', str(source), '-pthread', '-o', str(tmp / 'worker')], check=True)
    def observations(data):
        offset = struct.unpack_from('<I', data, 12)[0]
        names, states, ends = {}, [], {}
        while offset + REC.size <= len(data):
            kind, flags, size, stamp, tid, aux = REC.unpack_from(data, offset)
            assert size >= REC.size and offset + size <= len(data)
            payload = data[offset + REC.size:offset + size]
            if kind == 2:
                names[tid] = payload.split(b'\0')[0]
            elif kind == 3:
                ends[tid] = stamp
            elif kind == 23:
                first, count, reserved = struct.unpack_from('<QII', payload)
                assert first <= stamp and not reserved
                states.append((tid, aux, count, stamp))
            offset += size
        return names, states, ends
    for vanished in (False, True):
        trace = tmp / ('vanished.gstrace' if vanished else 'states.gstrace')
        command = [str(ROOT / 'Tools/gstrace/obj/gstrace'), 'record', '--thread-states', '--output', str(trace), '--launch', str(tmp / 'worker')]
        if vanished: command.append('raw-exit')
        p = subprocess.run(command, text=True, capture_output=True)
        assert p.returncode == 0, p.stdout + p.stderr
        streams = list(trace.glob('events-*.bin'))
        assert len(streams) == 1, streams
        data = streams[0].read_bytes()
        assert struct.unpack_from('<I', data, 12)[0] >= 320
        assert struct.unpack_from('<I', data, 312)[0] == 10000
        names, states, ends = observations(data)
        main = struct.unpack_from('<I', data, 16)[0]
        worker = next(tid for tid in names if tid != main)
        observed = [s for s in states if s[0] == worker]
        sleeping = [s for s in observed if s[1] == ord('S')]
        # Immediate S, 1s keyframe, and final partial batch: exit flushing alone
        # only gives two. The keyframe must also precede exit by >=150ms.
        assert len(sleeping) >= 3, observed
        assert any(s[2] > 50 and s[3] < observed[-1][3] - 150000000 for s in sleeping), observed
        exits = [s for s in observed if s[1] == ord('X')]
        assert len(exits) == 1 and exits[0][2] == 0 and observed[-1] == exits[0], observed
        assert exits[0][3] >= sleeping[-1][3], observed
        assert (worker not in ends) if vanished else (worker in ends and exits[0][3] >= ends[worker])
        assert 70 <= sum(s[2] for s in observed) <= 180, observed
        assert not any(name == b'gsp-writer' for name in names.values())
        info = subprocess.check_output([str(ROOT / 'Tools/gstrace/obj/gstrace'), 'info', str(trace)], text=True)
        assert 'share of polls' in info and 'R (running or runnable)' in info, info
    # A genuinely absent proc mount must disable the track, without fabricated
    # exited user threads. Start the preload inside the namespace, not in bwrap.
    if shutil.which('bwrap'):
        no_proc = tmp / 'no-proc.gstrace'
        no_proc.mkdir()
        command = ['bwrap', '--unshare-user', '--die-with-parent', '--ro-bind', '/', '/',
            '--dev-bind', '/dev', '/dev', '--bind', '/tmp', '/tmp', '--tmpfs', '/proc',
            '--setenv', 'GSP_OUTPUT', str(no_proc), '--setenv', 'GSP_THREAD_STATES', '1',
            '--setenv', 'GSP_CPU_SAMPLING', '0', '--setenv', 'GSP_WALL_SAMPLING', '0',
            '--setenv', 'LD_PRELOAD', str(ROOT / 'Runtime/obj/libgsperf-agent.so'), '--', str(tmp / 'worker')]
        p = subprocess.run(command, text=True, capture_output=True)
        assert p.returncode == 0, p.stdout + p.stderr
        data = next(no_proc.glob('events-*.bin')).read_bytes()
        assert observations(data)[1] == [], 'unavailable proc must not invent states/exits'
        info = subprocess.check_output([str(ROOT / 'Tools/gstrace/obj/gstrace'), 'info', str(no_proc)], text=True)
        assert 'thread states: unavailable (no /proc)' in info, info
    else:
        print('SKIP absent-proc namespace fixture: bwrap not installed')
    # Explicit opt-in: a regular recording keeps the header interval zero.
    plain = tmp / 'plain.gstrace'
    subprocess.run([str(ROOT / 'Tools/gstrace/obj/gstrace'), 'record', '--output', str(plain), '--launch', '/bin/true'], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    info = subprocess.check_output([str(ROOT / 'Tools/gstrace/obj/gstrace'), 'info', str(plain)], text=True)
    assert 'thread states: not recorded' in info
print('Thread-state live checks passed (keyframe, exit, poll weights, opt-in, reader)')
