# Windows port (planned after phase 3)

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
