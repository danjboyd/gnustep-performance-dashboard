# tools-xctest integration (proposal)

[tools-xctest](https://github.com/danjboyd/tools-xctest) already implements
XCTest's performance API (`measureBlock:`, `XCTMetric`, baselines). These are
the places where it and Performance Dashboard can meet. Nothing here requires
tools-xctest to depend on Performance Dashboard's framework or app.

## 1. XCTOSSignpostMetric

Apple's `XCTOSSignpostMetric` measures the duration of signpost intervals
emitted by the code under test. Performance Dashboard ships `<os/signpost.h>`
(libgsperf), so the metric can be implemented in tools-xctest by:

- weak-linking or `dlopen`ing `libgsperf.so` (optional dependency), and
- registering a sink for signposts while a measured block runs.

The agent-side ABI today is `gsp_agent_signpost()` in `libgsperf-agent.so`.
For in-process measurement without the agent, libgsperf would gain a small
public hook, e.g.

```c
typedef void (*gsp_signpost_observer)(int kind, uint64_t id,
                                      const char *subsystem, const char *category,
                                      const char *name, uint64_t time_ns, void *ctx);
void gsp_signpost_add_observer(gsp_signpost_observer fn, void *ctx);
void gsp_signpost_remove_observer(gsp_signpost_observer fn, void *ctx);
```

which tools-xctest's metric would use to pair begin/end events by
(subsystem, category, name, id). This is the one interface change that needs
agreement between the two projects.

## 2. Profiling a test run

Already works:

```sh
gstrace record --template "Time Profiler" --launch xctest MyTests.xctest -XCTest MyTests/testParse
gstrace record --template Leaks --launch xctest MyTests.xctest
```

A convenience flag in tools-xctest (`xctest -performance-trace out.gstrace`)
could re-exec itself under the agent with `GSP_OUTPUT` set and wrap each
`measure` block in a signpost interval named after the test, so the trace's
Points of Interest track lines up with the measurements.

## 3. CPU counters

tools-xctest's `XCTCPUMetric` reports less than Apple's (no instructions
retired / cycles). With `kernel.perf_event_paranoid` ≤ 2 a process can count
its own instructions with `perf_event_open`; the counting code could live in
libgsperf and be shared.
