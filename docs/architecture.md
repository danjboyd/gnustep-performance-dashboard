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

## The Windows agent (gsperf-agent.dll)

`Runtime/win/`; the trace format is the same. There is no `LD_PRELOAD` and
there are no asynchronous signals, so:

- **Injection.** The recorder starts the target suspended, loads the DLL
  with a remote `LoadLibraryW` thread, waits for `Local\gsperf-ready-<pid>`
  (set when the sampler runs) and resumes it. To attach, it puts the
  settings in shared memory (`Local\gsperf-config-<pid>`), loads the DLL
  the same way and calls the `gsp_agent_attach` export in a second remote
  thread. `Local\gsperf-stop-<pid>` stops a recording.
- **Sampling** (`gsp_agent_win.c`). One sampler thread suspends each thread
  whose cycle count moved since the last tick, reads its context, unwinds it
  with `RtlVirtualUnwind` and resumes it; the weight is the cycles used over
  the cycles of an interval (the nominal rate from the registry). While a
  thread is suspended the sampler takes no lock it could hold: function
  entries come from its own copy of the modules' `.pdata`, not
  `RtlLookupFunctionEntry` (which takes the loader's lock), and records are
  written after resuming. A second, low-priority thread records modules and
  the Objective-C method table.
- **Hooks** (`gsp_heap_win.c`, `gsp_io_win.c`). Import address tables of
  every module except the agent, kernel32 and kernelbase are patched: UCRT
  heap functions, libobjc2 allocation and reference counting, `exit`, the
  kernel32 file functions, winsock and `LoadLibrary*` (so modules loaded
  later are patched too). What does not go through an import table is
  replaced through the Objective-C runtime: `-[NSObject retain/release/
  autorelease]` (clang on Windows sends them as messages) and
  `-[NSZombie forwardInvocation:]`. A thread-local flag keeps the hooks
  from recording the agent's own work.
- **Leaks** (`gsp_leaks_win.c`). The scan suspends every other thread and
  marks from all writable committed memory that is not a tracked block,
  the agent, an agent thread's stack or a dead stack area, plus the threads'
  registers. Blocks allocated before injection are untracked and so count
  as roots.

## The privileged helper

`gstrace-helper record` opens a `perf_event` (software cpu-clock, callchains,
`CLOCK_MONOTONIC`) per thread of the target, rescans for new threads, reads
`/proc/<pid>/maps` for images and `/proc/kallsyms` for kernel symbols (written
as method-name records), and writes the same stream format. It stops at the
time limit, when the target exits, or when a `stop` file appears in the bundle
(the recorder cannot signal a root process). As root it only accepts targets
whose real, effective, saved and filesystem user and group ids are all
`PKEXEC_UID`'s (re-checked every 100 ms, together with the executable's
identity, so an exec or a credential change ends the recording), an output
directory owned by that user, and creates files with `O_NOFOLLOW|O_EXCL`,
mode 0600, before handing them to the user. Image files are inspected
through `/proc/<pid>/map_files` with `O_NONBLOCK` and a regular-file check.
Installation stages the helper and policy in a fresh `mkdtemp` directory;
the installer only accepts sources owned by root or the invoking user and
not writable by others, and the installed copy (which runs under the
`auth_admin_keep` sampling policy) refuses `install` and `uninstall`.

During a leak scan the writer allocates only with unregistered `mmap`s (a
stopped thread may hold the agent's mapping lock). A stop requested from a
signal handler skips every finalisation step that takes a lock and waits at
most five seconds; fork children turn all tracking off.

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
