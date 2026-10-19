# Trace format

A trace is a directory bundle, `Name.gstrace/`:

| File | Written by | Contents |
|---|---|---|
| `Info.plist` | recorder | template, instruments, target path and arguments, `TargetPID`, start/end dates, exit status, host |
| `events-<pid>.bin` | agent or helper | the event stream of one process |
| `events-<pid>.done` | agent or helper | empty; the stream is complete |
| `output.txt` | recorder (app) | the target's stdout/stderr |
| `symbols-<pid>.plist` | `gstrace symbolicate --embed` | address (hex) → symbol name, for reading the trace elsewhere |

The authoritative definition is
[`Runtime/include/GSPerformance/gsp_format.h`](../Runtime/include/GSPerformance/gsp_format.h).

## Streams

A stream starts with `gsp_file_header` (magic `GSPTRACE`, version 1, pid,
parent pid, start time on `CLOCK_MONOTONIC` and `CLOCK_REALTIME`, sampling
intervals, executable path), followed by records. Each record starts with a
24-byte `gsp_record` header: type, flags, total size (a multiple of 8), time
(`CLOCK_MONOTONIC` ns), thread id and a type-specific `aux` word.

Records are **not** in time order (each thread's buffers are flushed
independently), and definitions may follow their uses. Readers make a second
pass to resolve ids and sort by time. A final record may be incomplete while
recording; readers stop at it.

| Type | Payload |
|---|---|
| STRING | `aux` = id; UTF-8 bytes |
| THREAD / THREAD_END | `aux` = flags (main, internal); thread name |
| IMAGE | load bias, executable range, path |
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

Frame 0 of a sample is the interrupted PC; later frames are return addresses
and are symbolicated at `address - 1`.

Record 22, `DIAGNOSTIC`, adds an optional NUL-terminated UTF-8 warning.
`aux=1` means a leak scan was unavailable; no leak snapshot is emitted for
that attempt. A later successful LEAK_END restores latest-scan availability,
while diagnostics remain in the recording history. `aux=2` means stack
unwinding is limited to frame pointers. Readers expose these in the CLI and
GUI. Version 1 is retained because unknown record types are skipped; older
readers will not display these diagnostics and should not be used to assess
recording quality for v0.1.0.
