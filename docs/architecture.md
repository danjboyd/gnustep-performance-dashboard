# Architecture

```
 target process                                   recorder (gstrace / Instruments.app)
 ┌──────────────────────────────────────────┐     ┌──────────────────────────────────┐
 │ app code ── malloc/free ─┐                │     │ GSPRecorder                      │
 │ GNUstep ── objc_alloc ───┤ libgsperf-     │     │  posix_spawn + LD_PRELOAD        │
 │          ── retain/rel ──┤ agent.so       │     │  sigqueue(STOP / LEAK CHECK)     │
 │ timers ── SIGPROF ───────┤  per-thread    │     │  writes Info.plist               │
 │ os_signpost (libgsperf) ─┘  rings ─► writer├──►  │                                  │
 │                              thread       │ events-<pid>.bin                       │
 └──────────────────────────────────────────┘     │ GSPTrace ► analyses ► views/CLI   │
                                                  └──────────────────────────────────┘
 running process ◄── perf_event ── gstrace-helper (pkexec) ──► events-<pid>.bin
```

## Components

| Directory | Builds | Language | Depends on |
|---|---|---|---|
| `Runtime/` | `libgsperf-agent.so`, `libgsperf.so` | C | libc only (libunwind via dlopen) |
| `GSPerformance/` | `libGSPerformance` | Objective-C (ARC) | gnustep-base |
| `Tools/gstrace/` | `gstrace` | Objective-C | GSPerformance |
| `Tools/gstrace-helper/` | `gstrace-helper` | C | libc |
| `Instruments/` | `Instruments.app` | Objective-C (ARC) | gnustep-gui, GSPerformance |
| `Tests/` | unit tests, fixtures, `run.sh` | | tools-xctest |

## The agent (libgsperf-agent.so)

Injected with `LD_PRELOAD`; records only when `GSP_OUTPUT` names a trace
bundle. It must never link GNUstep, libobjc or a C++ runtime — it lands in
arbitrary processes — so Objective-C hooks resolve the runtime with `dlsym`.

**Threads and rings.** Every traced thread gets two single-producer rings:
one written only from signal handlers (samples), one only from normal code
(allocations, signposts, definitions). A handler that interrupts normal code
writes to the other ring, so no ring ever has two producers and handlers never
lock. One internal writer thread drains all rings to the stream every 20 ms
and also performs leak scans and finalisation. Normal-context producers wait
briefly when their ring is full; signal producers drop and count.

**Sampling.** `timer_create(CLOCK_THREAD_CPUTIME_ID)` per thread (created in
the thread: `pthread_create` is interposed, other threads register lazily on
their first allocation). CPU-time timers fire on the scheduler tick, so each
sample carries its overrun count as a weight. The main thread also has a
`CLOCK_MONOTONIC` timer whose samples feed the Hangs analysis. Stacks are
unwound with libunwind (`unw_init_local2` with `UNW_INIT_SIGNAL_FRAME`,
per-thread caching); while the thread is itself inside libunwind or the loader
is changing the link map, frame pointers are walked instead.

**Allocations.** `malloc` and friends call glibc's `__libc_*` entry points
directly. Stacks are interned (a hash table in agent-owned `mmap` memory) so an
`ALLOC` record carries a stack id. `class_createInstance`, `objc_alloc`,
`objc_allocWithZone` and `objc_alloc_init` are interposed to label blocks with
their class (libobjc2 places objects 8 bytes into their block).

**Leaks.** The live-block table is kept from the very first allocation (before
the agent's constructor runs) so libraries' early data structures are known. A
scan locks the table, stops every registered thread with a signal (each saves
its registers, stack pointer and TLS base), then marks conservatively from
roots: writable mappings other than malloc heaps — with the agent's buffers,
thread stacks and large blocks cut out of merged regions — each thread's live
stack, saved registers and TLS. Memory is read with `process_vm_readv` so
nothing can fault. Pointers to glibc's next-chunk headers are ignored, and
self-relative offsets in block headers (fontconfig) are followed.
Uninitialised memory in live blocks is full of stale free-list pointers, so
Objective-C objects (class-tagged blocks) count as referenced only through
their start or object pointer; other blocks also accept interior pointers
(GObject instances and ld.so link maps are referenced from the inside)
unless the target looks like a stale chunk header. `GSP_LEAK_INTERIOR=0`
(start only) and `=1` (any interior pointer) select the other policies. Unmarked
blocks are leaks. The final scan runs from an interposed `exit()` before
`atexit` handlers clear the globals that keep objects alive.

**Control.** The recorder `sigqueue`s `SIGRTMIN+5` with a request (stop, leak
check, mark). On stop the writer disarms timers, drains, dumps the
Objective-C method table (GNUstep's libraries are stripped), runs the final
leak scan, writes `END` and creates `events-<pid>.done`; the recorder then
ends the target. `SIGINT`/`SIGTERM`/`SIGHUP` with default dispositions
finish the recording before the process dies.

**Children.** GNUstep caches the environment before the agent can scrub it, so
helper processes (gdnc, gpbs) inherit `LD_PRELOAD`. The agent records only when
its parent is the recorder (`GSP_RECORDER_PID`) unless children are followed.

## The privileged helper

`gstrace-helper record` opens a `perf_event` (software cpu-clock, callchains,
`CLOCK_MONOTONIC`) per thread of the target, rescans for new threads, reads
`/proc/<pid>/maps` for images and `/proc/kallsyms` for kernel symbols (written
as method-name records), and writes the same stream format. It stops at the
time limit, when the target exits, or when a `stop` file appears in the bundle
(the recorder cannot signal a root process). As root it only accepts targets
owned by `PKEXEC_UID`, an output directory owned by that user, and creates
files with `O_NOFOLLOW|O_EXCL` before handing them to the user.

## libGSPerformance

- `GSPTrace` / `GSPProcess`: incremental parsing (live traces reload cheaply),
  definitions resolved after each pass, C arrays for samples and allocation
  events, signpost interval matching.
- `GSPSymbolicator`: per-image ELF symbol tables (and debug files by build-id
  or debuglink), `.eh_frame_hdr` function starts for exact function bounds in
  stripped code, the dumped Objective-C method table, C++ demangling, an
  embedded `symbols-<pid>.plist` for traces opened elsewhere, `addr2line` for
  source lines. `-symbolsForStack:` hides the agent's frames.
- `GSPCallTree`: the call tree and its options and data mining.
- `GSPAnalysis`: Hangs, Allocations, Leaks, signpost summaries, zombie history.
- `GSPRecorder`, `GSPInstruments`, `GSPExporter`.

## Instruments.app

Programmatic AppKit UI (no nibs), standard controls everywhere so the theme
applies; custom drawing (timeline, tracks) uses the theme's system colours
plus fixed data-series hues. `INTimelineView` (ruler, tracks, inspection
range, pan/zoom), `INTrackRenderer` (per-instrument drawing and shared
analyses), `INDetailController` (per-instrument modes in one outline view),
`INInspectorView` (Extended Detail), `INRecordPanel` (templates, target,
attach).
