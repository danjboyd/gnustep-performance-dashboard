# Windows port

## Status

- **Viewer.** `libGSPerformance`, `gstrace` and Instruments.app build with
  MSYS2 clang64 and read traces from either platform.
- **Recording** with `gsperf-agent.dll`:
  - *Time Profiler, Hangs*: a sampler thread suspends threads whose cycle
    count moved and unwinds them with `RtlVirtualUnwind`; the main thread
    is sampled every 10 ms regardless of state.
  - *Points of Interest, os_log*: `gsperf.dll` forwards to the agent.
  - *Allocations*: the UCRT heap functions and libobjc2's allocation entry
    points are hooked in every module's import table (and in modules
    loaded later, through a LoadLibrary hook); stacks come from
    `RtlCaptureStackBackTrace`.
  - *Leaks*: a live-block table and a stop-the-world conservative scan of
    writable memory and thread registers, at `exit()` (before atexit
    handlers), on stop and every leak interval.
  - *Zombies, retain/release*: `objc_retain`/`objc_release` hooks plus
    `-[NSObject retain/release/autorelease]` replaced through the runtime
    (clang on Windows sends them as messages);
    `-[NSZombie forwardInvocation:]` is replaced to catch messages to
    deallocated objects (GSLogZombie is an internal call in gnustep-base).
  - *File Activity, Network*: kernel32 file calls and winsock calls,
    hooked in import tables; the CRT's stdio is caught through ucrtbase's
    imports.
  - *Attach*: `gstrace record --attach <pid>` (or the app) injects the
    agent into a running program of the same user; the configuration is
    passed in shared memory. The program keeps running afterwards; the
    agent stays loaded and idle, so a process can be recorded once.
  - Symbolication: COFF symbol tables, exports and `.pdata` function
    bounds, plus the Objective-C method table the agent dumps.
- **CI** records C and Objective-C fixtures on `windows-latest` with every
  template and with attach (`Tests/windows-checks.sh`).
- **Not yet:** the System Time Profiler (ETW kernel sampling through a
  UAC-elevated helper), DWARF/PDB source lines, ARM64. Signposts emitted
  by a program that was attached to are not recorded (`gsperf.dll` looks
  for the agent once).

## Plan for recording

The analysis framework, `gstrace` and the app are portable GNUstep code; the
platform-specific parts are the recording agent and the helper.

| Linux | Windows equivalent |
|---|---|
| `LD_PRELOAD` injection | launch suspended (`CREATE_SUSPENDED`), inject `gsperf-agent.dll` with a remote `LoadLibraryW` thread (or Detours-style import patching), resume |
| interposing `malloc`/`free` | hook the CRT heap functions (UCRT `malloc` family) and `HeapAlloc`/`HeapFree` via IAT patching or Detours |
| per-thread CPU-time timers + signals | a sampler thread that `SuspendThread`s each thread, reads `GetThreadContext`, walks with `RtlVirtualUnwind`, resumes (Windows has no async signals) |
| libunwind | `RtlVirtualUnwind` / `StackWalk64` with PE `.pdata` |
| ELF / `.eh_frame` symbolication | PE exports, `.pdata` function bounds, DbgHelp + PDB, plus the Objective-C method dump (unchanged) |
| stop-the-world for leaks | `SuspendThread` on all threads; `GetThreadContext` for registers; `VirtualQuery` instead of `/proc/self/maps` |
| `os_signpost` / `os_log` | the same API on top of the agent; optionally also TraceLogging/ETW events so other Windows tools see them |
| `perf_event` helper via pkexec | ETW kernel sampling (`EVENT_TRACE_FLAG_PROFILE` + stack walk) in a separate UAC-manifested `gstrace-helper.exe`, elevated per operation (the packaged MSI is per-user) |

libobjc2 on Windows allocates objects with `_aligned_malloc`, so the 8-byte
object offset used for class tagging on Linux differs; tagging must look the
block up by containment instead.

The trace format is unchanged; `gsp_file_header` gains a platform field.
