# Sampling unwinder safety

When Time Profiler or Hangs samples a thread, the signal handler calls the
unwinder. If the unwinder allocates while extending its internal state and
Allocations is also enabled, the malloc hook can try to record that allocation
by invoking the unwinder again. Its per-thread cache is not reentrant.

Normal allocation-stack collection already sets `gsp_in_agent`. The sampling
signal path did not. `sample_handler` now brackets its unwind and event emission
with the same thread-local recursion guard. This adds no allocation or lock to
the handler. It suppresses records of the agent's own work and restores the
interrupted guard depth; normal target allocation recording continues afterward.
CPU and wall samples remain enabled.

## Signal-unwinder allocation regression

`Tests/fixtures/allocating-unwinder.c` implements the small libunwind ABI subset
used by the x86-64 agent. Its signal-cursor initializer makes a distinctive
7,897-byte allocation. If recording that allocation recursively calls
`unw_backtrace`, the fixture writes `CONTROLLED_REENTRANT_UNWINDER` and exits86.
This is a controlled contract check, not a fabricated application crash.

`Tests/sampler-reentry-check.py` compiles that fixture and launches a C target
through the real `gstrace record` path. The allocation regression has four modes:
CPU only, allocations only,
CPU plus allocations, and wall sampling plus allocations. It checks the target
wait status, an END record, no dropped events, the expected sample/allocation
record types, absence of the unwinder's internal allocation and presence of an
ordinary 12,345-byte target allocation after the sampling workload. The last
check prevents a permanently set guard from appearing to fix the problem.

The regression fails against the released v0.1.4 agent in combined mode, after
the two single-instrument controls pass. The guarded agent passes all four
scenarios. The runtime source was identical between the v0.1.4 tag and the local
v0.1.5 base before this guard was added.

The test runs from `Tests/run.sh` on Linux x86-64, the ABI its controlled library
implements. It can also be run directly after building PD:

```sh
python3 Tests/sampler-reentry-check.py
```

Its `--agent`, `--gstrace` and `--output` options support before/after diagnosis.
Artifacts are retained in fresh subdirectories under the output directory.

## Frame-pointer bound overflow

A native AIManager core from a synthetic private-display study identifies a
separate SIGSEGV in the frame-pointer fallback. A sample interrupted the
allocation unwinder inside `unw_backtrace`. The existing `in_unwind` check
correctly selected frame pointers instead of entering libunwind again. The
frame-pointer candidate reached by the walker was `0xfffffffffffffff0` (-16).
The old `p + 16 <= stack_hi` check wrapped to zero, accepted that value and
faulted while reading `p + 8`.

`in_stack` now checks the upper bound before subtracting: `p <= stack_hi` and
`stack_hi - p >= 2 * sizeof(uintptr_t)`. The existing lower-bound, stack-pointer
and pointer-alignment checks remain. This rejects the overflowing candidate
without suppressing samples or changing the frame-pointer fallback policy.
No allocation or lock is added.

The same controlled unwinder supplies two additional cases. After initialization,
the target arms its allocation-stack routine to issue `tgkill` on its own thread
with RBP temporarily set to -16, directly testing the invalid candidate from the
core (the core's interrupted RBP itself was a normal stack address). The real
sampling handler must unwind that signal context while `in_unwind` is set. CPU and wall variants check normal
target exit, a post-signal marker, sample/allocation records, a clean END, zero
drops and subsequent ordinary allocations. Internal signal-cursor allocations
are disabled in these two cases to isolate the overflow from the re-entry test.
The released v0.1.4 agent reproduces SIGSEGV in the CPU variant; the fixed agent
passes both. Run just this pair with `--case invalid-fp`, or the four allocation
cases with `--case reentry`; the default runs all six.

A source audit found the same `in_stack` expression in the shared x86-64/arm64
unwinder on `port/linux-arm64`; that paused branch still needs the fix carried
forward and validated when resumed. The Windows unwinder does not use this
frame-pointer walker. Its separate leak scanner has addition-based range loops;
those are outside this Linux sampler fix and were not changed or tested here.

## Validation and application limits

The fixed Linux x86-64 agent passes all six controlled scenarios. The full
headless regression suite passes with exit status zero and **All 53 checks
passed**, including **30 unit tests** and the six-case sampler check. AppKit
fixture checks were explicitly skipped with `SKIP_GUI=1`; the suite's existing
headless viewer checks ran. The agent's direct dependencies remain libc and the
ELF loader only.

The native original-combination study failed after 87.94 seconds and produced
the core described above. Separate uninstrumented, CPU-only, allocations-only
and combined debugger runs survived about ten minutes; debugger timing did not
reproduce the native fault. The native run with both fixes completed its
scheduled ten-minute interval (601.26 seconds), with recorder and raw target
wait statuses zero, one END record and zero dropped records. It retained
137,238 CPU samples, 59,894 wall samples and 43,162,418 allocation events.
The recorder deliberately stopped the capture; this is not a normal user-exit
test or a long-term growth result. Host one-minute load ranged from 20.30 to
29.65. All five owned test processes and the private display were cleaned up.
No AIManager code or installed runtime was changed. The fixture and all raw
traces are synthetic and private.

The initial `gstrace record` returned zero despite the abnormal target wait
status. Abnormal-target-exit reporting is a separate backlog issue and is not
changed by these fixes. Long-term application growth, poll caching comparisons
and upstream library changes are also outside their scope. Application timings
were collected under substantial host load and are not reliable benchmarks.
