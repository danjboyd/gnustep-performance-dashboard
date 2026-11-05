# Signal unwinder allocations must stay inside the agent

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

## Deterministic regression

`Tests/fixtures/allocating-unwinder.c` implements the small libunwind ABI subset
used by the x86-64 agent. Its signal-cursor initializer makes a distinctive
7,897-byte allocation. If recording that allocation recursively calls
`unw_backtrace`, the fixture writes `CONTROLLED_REENTRANT_UNWINDER` and exits86.
This is a controlled contract check, not a fabricated application crash.

`Tests/sampler-reentry-check.py` compiles that fixture and launches a C target
through the real `gstrace record` path in four modes: CPU only, allocations only,
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

## Application evidence and limits

The investigation began when a synthetic, private-display AIManager study ended
with target wait status11 under the released CPU/Hangs/Allocations combination.
An uninstrumented debugger run and individual CPU-only and allocations-only
debugger runs subsequently survived ten minutes. This motivated the controlled
test, but it does not prove that unwinder re-entry caused that GUI SIGSEGV.
Application/debugger observations and the controlled regression are separate
evidence. No AIManager code or installed runtime was changed.

The initial `gstrace record` returned zero despite the abnormal target wait
status. Abnormal-target-exit reporting is a separate backlog issue and is not
changed by this fix. Long-term application growth, poll caching comparisons and
upstream library changes are also outside its scope.

Full-suite and guarded application validation are recorded after completion;
the four controlled regression scenarios above are the completed check so far.
