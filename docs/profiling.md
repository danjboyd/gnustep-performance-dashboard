# Profiling your GNUstep application on Linux

Build Performance Dashboard with Clang and libobjc2. Targets run against
their own libraries; the injected C agent does not link GNUstep or libobjc.
Linux x86_64/glibc is the v0.1.0 target platform. GCC and Clang C programs
are tested; Clang/libobjc2 GNUstep programs are tested. CPU profiling of GCC Objective-C with
Debian 13’s legacy GNU runtime passes at -O0 and -O2. Objective-C allocation
class labels and Zombies with that runtime remain unverified. Musl, static launch recording,
32-bit binaries and Windows packages are outside this release's contract.

Run GCC/legacy-runtime targets from an environment configured for their own
runtime. The managed libobjc2 toolchain uses SONAME `libobjc.so.4.6`, but also
provides a compatibility symlink `libobjc.so.4` pointing to it. If its library
directory remains on `LD_LIBRARY_PATH` after sourcing its `GNUstep.sh`, a
legacy target needing `libobjc.so.4` can load libobjc2 instead of the GNU
runtime. Before profiling, check `ldd /path/to/target` in the target's intended
environment and confirm that `libobjc.so.4` resolves to the distribution's
legacy runtime, outside the managed toolchain. The issue is the compatibility
alias and search path, not identical SONAMEs.

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

On Linux, `gstrace record --launch` propagates a program's normal exit code.
A recorder-requested time limit or user stop remains successful when the
program exits successfully or terminates from the requested SIGTERM. If it
ignores SIGTERM for three seconds and the recorder kills it, the command
returns 137 and reports the escalation. Other signals return 128 plus the
signal number. `gstrace info` shows the raw `ExitStatus` and the `StopReason`
(`exited`, `requested-terminate`, `escalated-kill`, or `signal`). A complete
trace stream can survive an abnormal target exit: “finished cleanly” describes
the stream's final record, not a successful program shutdown. Attach and
Windows exit policies are unchanged.

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

## Choose instruments and account for their cost

Start with Time Profiler for a CPU question, then make a separate memory
recording. Enabling more recording types changes the work done by the target.
There is no fixed overhead percentage: it depends on event volume, stack
depth, live heap size, number of threads, and scan frequency.

| Recording type | Expected cost and effect on interpretation |
|---|---|
| Time Profiler | A CPU-time timer per thread, normally every 1 ms of CPU, interrupts it to unwind a stack. More active threads and deeper stacks cost more. Libunwind and frame-pointer fallback have different coverage and cost. |
| Hangs | Main-thread wall samples, normally every 10 ms, plus run-loop observations. Distinguish main-loop stalls from CPU consumption and background loading. |
| Allocations | Hooks every allocation/free, captures allocation stacks, interns definitions, and writes events through rings. Allocation-heavy workloads can incur substantial CPU, memory and trace-size costs; sampled CPU can include work induced by these hooks. |
| Leaks | Enables allocation/live-block tracking and periodically stops threads to scan roots and the heap. Larger live heaps and more frequent scans increase memory and pause costs. A scan-induced pause is not evidence of the same pause without recording. |
| Zombies | Retains deallocated objects and records reference-count history. Memory growth is intentional and changes object lifetimes; use a short targeted reproduction. |
| File Activity / Network | Interposes I/O calls, captures stacks and emits records. Cost scales with call count, especially many tiny operations, rather than just transferred bytes. |
| Points of Interest / os_log | Emits strings and events for enabled annotations. Usually sparse, but high-volume logging still allocates/buffers/writes; unrecorded signposts are no-ops. |
| System Time Profiler | Kernel perf sampling avoids target preload hooks. Sampling frequency and stack capture still cost resources; it is a different recording mode, not a zero-cost control. |

For example, the same local Arlen API-reference workload completed 900
successful requests in each of two recordings. CPU-only sampled CPU was
1.134 s; combined CPU/allocations/leaks was 1.831 s. RSS after the third batch
was 34,324 versus 58,108 KiB. These observations explain why combined totals
should not be read as app-only cost. They are one pair, with scheduling,
background work and scans, **not a calibrated slowdown factor**. The combined
run's latest conservative scan reported zero leaked blocks; that does not
remove its tracking cost. See [the workload and limits](v0.1.3-dogfood.md).

To measure recording overhead, repeat a fixed workload unrecorded, CPU-only,
and with one additional recording type at a time. Compare externally measured
elapsed time, throughput/latency and peak resident memory; keep input, build,
warm-up, hardware and background load consistent. Repeat runs and report
variation. Preserve scan intervals, sample periods, event counts, dropped
records and exact target/recorder identities. Sample weights and a signpost
interval answer different questions from elapsed performance of an
uninstrumented application.


## Inspect unresolved function names

`gstrace info TRACE` reports how many display-frame entries remain unresolved
across distinct stacks referenced by the process's recorded events, with a
breakdown for modules containing unnamed frames. Repeated addresses in two
stacks count twice; repeating one stack in many events does not increase this
primary denominator. Unused stack definitions and transparent agent frames
are excluded. The summary is process-wide, even when requested alongside a
filtered report with `gstrace report TRACE allocations --symbol-summary`.

For traces with CPU samples, a separate CPU-sample-weighted line counts those
frame entries using each sample's overrun weight (zero means one); wall samples
are excluded. It is omitted for Allocations-only traces. CSV export and normal
report output do not acquire these extra lines.

An image can contain both named and unnamed functions. Raw image+offset labels
can reflect stripped or missing exact images/debug files; they are not a claim
of broken unwinding or missing allocations. Embedded name snapshots retain
raw fallback labels too. The summary recognizes the exact legacy raw-address
and image-name/hex-offset label forms against the recorded image/address,
including a zero return address, without treating an arbitrary function-name
`+0x` suffix as unresolved. It does not fetch symbols or rewrite trace files.
