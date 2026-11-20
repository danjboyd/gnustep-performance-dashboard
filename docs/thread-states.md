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
Old streams have no suffix and show `thread states: not recorded`.
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
