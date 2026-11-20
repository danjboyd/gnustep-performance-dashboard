# Worker wall-signal EINTR audit

This is a prerequisite audit, not an implementation or approval of all-thread
wall sampling. Linux x86_64, glibc 2.41, 2026-11-20. The fixture installs
SA_SIGINFO | SA_RESTART and sends SIGRTMIN+3 to each worker at 100 Hz with a
CLOCK_MONOTONIC SIGEV_THREAD_ID timer, matching the proposed wall timer.
Each worker waits for about 120 ms and retries interruptions against its
original deadline. No server, database or recording helper is involved.

| Call | Delivered signals | EINTR returns | Result |
| --- | ---: | ---: | --- |
| poll | 12 | 12 | Caller must retry |
| epoll_wait | 12 | 12 | Caller must retry |
| select | 12 | 12 | Caller must retry |
| nanosleep | 12 | 11 | Caller must retry remaining duration |
| sem_timedwait | 12 | 11 | Caller must retry original deadline |
| pthread_cond_timedwait | 12 | 0 | Timed out normally, mutex reacquired |

Counts are one observed run, not fixed test expectations. The fixture asserts
at least three signals per worker, EINTR on the first five calls and none on
the condition wait. All six retained their intended deadline (about120ms).
Run with the opt-in `make check-wall-eintr` target, or include it in the full
suite using `PD_TEST_WALL_EINTR=1 make check`. Ordinary `make check` skips
this timing-sensitive matrix. It needs Linux, not AppKit or a display. The
binary and optional suite log are retained under Tests/out/.

## Source audit

PostgreSQL18's internal `pqSocketCheck` repeats `PQsocketPoll` on EINTR using
an absolute end time. The public `PQsocketPoll` itself returns an interrupt
to its caller. Read/send paths also handle EINTR. This supports libpq's own
blocking path; it does not promise that every application calling the public
poll helper retries. See [fe-misc.c](https://github.com/postgres/postgres/blob/REL_18_STABLE/src/interfaces/libpq/fe-misc.c#L1187).

GNUstep's `NSCondition wait` calls pthread_cond_wait; waitUntilDate calls
pthread_cond_timedwait and handles success/timeout. There is no EINTR retry,
but these POSIX condition waits do not expose EINTR; the fixture checks that
on this libc. See [NSLock.m](https://github.com/gnustep/libs-base/blob/master/Source/NSLock.m#L522).

`NSThread`'s nanosleep path retries with the returned remainder. Its long-sleep
outer loop recalculates the deadline. See [NSThread.m](https://github.com/gnustep/libs-base/blob/master/Source/NSThread.m).

These are source observations, not end-to-end validation of an arbitrary
server's accept loop. All-thread wall sampling remains unimplemented here.
Before enabling it, audit the target's accept/read loops and libraries, retain
a total-signal budget, and disclose the residual EINTR/perturbation risk.
Thread-state polling introduces no new signals and is separate from this work.
