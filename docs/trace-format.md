# Trace format

A trace is a directory bundle, `Name.gstrace/`:

| File | Written by | Contents |
|---|---|---|
| `Info.plist` | recorder | template, instruments, target path and arguments, `TargetPID`, start/end dates, exit status, host |
| `events-<pid>.bin` | agent or helper | the event stream of one process |
| `events-<pid>.done` | agent or helper | empty; writer-ready marker, not sufficient proof of capture completion |
| `output.txt` | recorder (app) | the target's stdout/stderr |
| `symbols-<pid>.plist` | `gstrace symbolicate --embed` | address (hex) → symbol name, for reading the trace elsewhere |

The authoritative definition is
[`Runtime/include/GSPerformance/gsp_format.h`](../Runtime/include/GSPerformance/gsp_format.h).

For Linux launch recordings, `Info.plist` separates `StopTrigger` (`exited`,
`time-limit`, `user`, `max-size`, `min-free`, `error`) from `StopReason`
(the child's exit disposition) and `CaptureStatus` (`complete`, `incomplete`).
The first stop trigger is retained even if a later error makes the capture
incomplete. `CaptureError` and `CaptureErrorCode` describe the first recording
failure. A trace from an older recorder may lack these fields.

A failed process wait is recorded separately as `WaitPIDErrno`, with optional
`WaitPIDErrorName` and `WaitPIDError` text. `StopTrigger` equal to `error`,
with `WaitPIDErrno` present but no `CaptureError`, means that the target's
process status was lost; the recorded stream may still be complete.
`CaptureStatus` determines capture completeness. A wait error does not supply
an exit status or establish which code reaped the child.

`MaximumTraceBytes`, `TimeLimitSeconds`, `MinimumFreeBytes` and
`AutomaticMinimumFreeSpace` record the configured/effective policy.
`ObservedTraceBytes` counts regular bundle files at the last measurement,
before the final metadata rewrite. `ObservedAvailableBytes` is the filesystem's
available-to-this-user byte count when the free-space floor is enabled.
The recorder does not follow symlinks when counting files.

The Linux agent reports its first I/O error and its successful completion
through a private inherited datagram endpoint, independently of the trace
filesystem. Completion requires a matching stream epoch and byte count,
the final END record, the writer's successful sync/close status and its marker.
An END alone does not establish that a later fsync or close succeeded.
If writing metadata itself fails, the recorder still reports the error to
its caller; retained initial metadata is not evidence of final completion.
The error protocol does not add or change on-disk trace record types.

## Streams

A stream starts with `gsp_file_header` (magic `GSPTRACE`, version 1, pid,
parent pid, start time on `CLOCK_MONOTONIC` and `CLOCK_REALTIME`, sampling
intervals, executable path), followed by records. Each record starts with a
24-byte `gsp_record` header: type, flags, total size (a multiple of 8), time
(`CLOCK_MONOTONIC` ns), thread id and a type-specific `aux` word.

The original v1 header is a 312-byte prefix. `header_size` is where records
begin; seek to it instead of assuming the reader's own header size. Accept
headers at least 312 bytes long and skip unknown suffix bytes. The optional
suffix at offset 312 adds `thread_state_interval_us` (u32) and a reserved zero
word (u32), making the header 320 bytes. A missing suffix or zero interval
means polling was not requested. A nonzero interval is its nominal cadence,
not proof of available observations. Recorder completion validation uses the
declared header size, final END and separate writer receipt/marker checks.

Records are **not** in time order (each thread's buffers are flushed
independently), and definitions may follow their uses. Readers make a second
pass to resolve ids and sort by time. A final record may be incomplete while
recording; readers stop at it.

| Type | Payload |
|---|---|
| STRING | `aux` = id; UTF-8 bytes |
| THREAD / THREAD_END | `aux` = flags (main, internal); thread name |
| IMAGE | load bias, executable range, path; optional loaded GNU build ID |
| SAMPLE | `aux` = kind (cpu, wall, perf); frame count, kernel frame count, weight; frames |
| STACK | `aux` = stack id; frames (allocation stacks are interned) |
| ALLOC / FREE | address, size, stack id, realloc source |
| OBJC_TAG | object address, class-name string id |
| REFCOUNT | `aux` = retain/release/autorelease; address, stack id |
| SIGNPOST / LOG | `aux` = begin/end/event or log level; id, subsystem, category, name, message |
| LEAK_BEGIN / LEAK / LEAK_END | snapshot summary, leaked blocks |
| METHOD | implementation address, `-[Class selector]` (or a kernel symbol) |
| ZOMBIE | object address, selector string id, stack id |
| DROPPED | samples dropped because a ring was full |
| MARK / END | recording start, user marks, clean end |
| THREAD_STATE (23) | `aux` = proc state character; first poll time (u64), actual poll count (u32), reserved zero (u32) |

Frame 0 of a sample is the interrupted PC; later frames are return addresses
and are symbolicated at `address - 1`.

Record 22, `DIAGNOSTIC`, adds an optional NUL-terminated UTF-8 warning.
`aux=1` means a leak scan was unavailable; no leak snapshot is emitted for
that attempt. A later successful LEAK_END restores latest-scan availability,
while diagnostics remain in the recording history. `aux=2` means stack
unwinding is limited to frame pointers. Readers expose these in the CLI and
GUI. Version 1 is retained because unknown record types are skipped; older
readers will not display these diagnostics and should not be used to assess
recording quality for v0.1.0. `aux=3` means thread states are unavailable:
`/proc/self/task` did not expose the writer's own TID, was unreadable, or
became unavailable later. The header retains the requested nominal interval,
but later state polling is disabled. `info` reports
`thread states: unavailable (no /proc)` rather than inventing thread exits.
This diagnostic is independent of CPU/wall samples and capture completion.

Record 23's timestamp is the last actual observation in its batch;
`first_ns` is the first. Each poll contributes once. State changes emit
immediately; unchanged batches emit about once a second and at stop.
Counts represent share of polls, not elapsed scheduler time. R means running
or runnable, S sleeping, D disk wait, `?` unavailable/malformed observation
(included in the denominator), and `X` a final exited event with zero polls.
The writer verifies its own proc entry before ENOENT can mean an exited TID;
ESRCH after opening a proc fd also means exit. Threads still alive at capture
stop are not marked exited. Polling gaps are not interpolated.
See [thread-states.md](thread-states.md) for CLI selection and limitations.

## Optional Linux IMAGE identity suffix

The version1 stream keeps its existing IMAGE header and NUL-terminated path.
When aux bit `GSP_IMAGE_BUILD_ID_AUX`(0x80000000) is set, immediately after the
path NUL come uint32 magic0x44495347(GSID), uint16 version1, uint16 ID length,
and1..64 raw GNU build-ID bytes. Padding remains8-byte record alignment.
Legacy readers stop at the path NUL and ignore the suffix; new readers keep
legacy records without the flag as identity-unverified. Flagged malformed or
unsupported suffixes are invalid identity, never silently treated as legacy.

The agent reads mapped readable PT_NOTE data during its ordinary image scan,
not from sample handlers or from a possibly replaced disk file. Identity is
attached to that exact IMAGE record, so no separate record pairing is needed.
If a later scan observes a different identity at a previously seen mapping, it
emits another IMAGE. Conflicting overlapping images are conservatively
ambiguous for address-only lookup: samples lack lifetime IDs, so the reader
refuses local/method/snapshot attribution rather than guessing. Unload/reload
ordering that is not observed between scans cannot be reconstructed.

Version2 portable symbol snapshots contain FormatVersion2, Images(path, load
bias/range, captured ID and validity) and Symbols(address-to-name). Images
with captured IDs require an equal binding before cached names are accepted;
old flat name-only snapshots remain usable for legacy traces. Build IDs are
identity assertions, not downloaded symbol data or cryptographic attestations.

Image identity comparison work is capped at 8,388,608 comparisons per stream.
If exhausted, all image records in that stream are conservatively marked
ambiguous; readers retain module/offset fallbacks rather than infer identity.
This bounds malformed or unusually large IMAGE inventories to linear work
after the fixed comparison budget.
