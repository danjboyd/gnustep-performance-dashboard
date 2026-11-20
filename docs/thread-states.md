# Linux thread states

`gstrace record --thread-states --launch ./program` opts into a state track.
Direct agent users can set `GSP_THREAD_STATES=1`. The default remains off.
The existing writer polls registered threads' `/proc/self/task/<tid>/stat` at
10 ms nominal intervals; this introduces no additional signals. Work done by
loader scans or leak snapshots can delay observations. Missed polls are not
invented. This is an observation track, not an exact scheduler trace.

`gstrace info` reports R (running or runnable), S (sleeping), D (disk wait)
and other/unknown as **share of polls**, never CPU or off-CPU time. Unreadable
or malformed proc data is unknown and remains in the denominator. A thread
that exits has a final zero-weight exited record. Threads that are still
alive when recording stops are not marked exited. The internal writer is
not registered or polled. Thread IDs reused within a recording remain subject
to the reader's existing TID-based thread grouping.

The v1 stream keeps its original 312-byte prefix and appends an optional
8-byte header suffix: `thread_state_interval_us` and a reserved zero word.
Old streams have no suffix and show `thread states: not recorded`. The
writer probes its own TID's proc stat before polling. If unavailable, it
disables the track and emits diagnostic 3. `info` then says
`thread states: unavailable` with the disable time and actual diagnostic errno.
The header retains the requested nominal interval. Earlier observations stay
visible in the poll-share summary; no user-thread exit is inferred from this
failure.
`GSP_REC_THREAD_STATE` (23) uses aux for the proc state character (`?` for
unavailable, `X` for exited). Its 16-byte payload contains `first_ns` (u64),
`polls` (u32), and reserved zero (u32). The record timestamp is the last poll
in that batch. Each actual poll occurs in exactly one batch. Changes emit
immediately; unchanged observations flush about once a second and at stop.
Readers can distinguish long observation gaps using the batch endpoints,
counts and nominal interval; they must not interpolate scheduler transitions.

This first stage retains state events for a future GUI lane. It does not add
wchan names, a Waits view, or all-thread wall signals. R is ambiguous, and a
10 ms proc observation cannot classify a particular wall sample as blocked
or running. Those sample flags need separate signal-handler CPU-clock data
and an EINTR audit before all-thread wall sampling can ship.

`gstrace report trace.gstrace top --kind wall --thread worker` selects wall
samples for every thread whose recorded name is exactly `worker`. A numeric
TID selects that thread; `--thread all` selects every thread. Repeat name/TID
selectors to form a union. Unknown selectors fail instead of silently showing
an empty result. `--kind cpu` remains the default, including perf CPU samples.
Wall weights use the recorded wall interval, CPU weights the CPU interval;
wall totals sum sampled thread time and can exceed process elapsed time.
`info` gives per-thread CPU/wall weights including timer overruns.
`wall-blocked` and `wall-running` fail clearly until classification flags are
implemented; proc-state polls never substitute for them.

The loader-state guard resolves the main executable's DT_DEBUG pointer during
normal startup, before timers are enabled. Signal handlers only read that
cached object's state. GOT `_r_debug` remains the fallback if DT_DEBUG is
absent. The non-PIE GCC regression requires a real `_r_debug` COPY relocation
and verifies both the loader pointer and the actual unwinder fallback counter.
With `PD_GLIBC239_LOADER` set to a retained Ubuntu 2.39 loader beside its libc,
the fixture additionally verifies stale-copy state 1 versus authoritative
state 0 and proves that restoring the old guard fails. No library download or
system installation is performed by the test.
