# Profiling your GNUstep application on Linux

Build Performance Dashboard with Clang and libobjc2. Targets run against
their own libraries; the injected C agent does not link GNUstep or libobjc.
Linux x86_64/glibc is the v0.1.0 target platform. GCC and Clang C programs
are tested; Clang/libobjc2 GNUstep programs are tested. GCC Objective-C with
the legacy GNU runtime is not yet verified. Musl, static launch recording,
32-bit binaries and Windows packages are outside this release's contract.

## Build a useful target

Keep debug information (`-g`) alongside your optimized build (`-O2`).
Install the host libunwind runtime (`libunwind8` on Debian/Ubuntu) so launch
recordings can unwind code without frame pointers. Attach uses kernel
frame-pointer chains: use `-fno-omit-frame-pointer` for useful callers there.
`addr2line` from binutils enables source-line lookup. Stripped binaries can
still expose Objective-C method names, but that is not a replacement for
keeping the matching executable and debug files.

## Record a repeatable operation

Choose Time Profiler, select the executable or .app bundle, and record a
specific interaction. Stop, select the relevant timeline range, and inspect
the call tree and Extended Detail. Hangs identify main-thread stalls.
Start a separate Allocations or Leaks recording for memory questions:
allocation instrumentation and stop-the-world scanning change timing.

Use the same inputs and interaction before and after a change. Warm up both
runs consistently, avoid competing workloads, and repeat runs rather than
treating one difference as conclusive.

```sh
gstrace record --template 'Time Profiler' -o before.gstrace -- ./MyApp.app/MyApp
gstrace record --template 'Time Profiler' -o after.gstrace -- ./MyApp.app/MyApp
gstrace diff before.gstrace after.gstrace
gstrace diff before.gstrace after.gstrace --fail-above 10
```

The threshold compares the measured workload, not a statistically established
regression. CPU samples, wall-clock hangs and allocation bytes measure different
things. Conservative leaks are candidates: hidden pointers can cause false
reports and stale pointer values can hide real leaks.

## Read warnings and preserve evidence

Recording warnings disclose dropped samples, incomplete recordings,
unavailable leak scans and fallback to frame pointers. An unavailable scan
does not mean zero leaks. `gstrace info` shows diagnostics; `report ... leaks`
and `diff --kind leaks` fail when their latest leak result is unavailable.

Save As copies the trace bundle. Before moving it to another machine, embed
symbol names while the matching executable and libraries are still available:

```sh
gstrace symbolicate before.gstrace --embed
gstrace info before.gstrace
```

Embedding names does not bundle source or debug files. Preserve those
separately if source locations are needed. Inspect recordings before sharing:
they may contain file paths, peer addresses, log text and application data
included in signpost messages.
