# Changelog

## Unreleased

Since the first implementation:

- Renamed from "GNUstep Instruments" to Performance Dashboard: the app
  is `PerformanceDashboard.app`, the bundle id
  `org.gnustep.PerformanceDashboard`, the polkit policy
  `org.gnustep.performancedashboard.policy` (installing or removing the
  helper also removes the old policy file). Trace bundles are unchanged.
- Record on an opened trace shows the template chooser, filled in from
  the trace, and records into a new window.
- Windows recording: `gsperf-agent.dll` injected at launch or into a
  running program (no elevation for the user's own programs). Time
  Profiler and Hangs (thread suspension + `RtlVirtualUnwind`), Points of
  Interest and os_log, Allocations, Leaks, Zombies and retain/release
  history (import-table hooks on the UCRT heap, libobjc2 and NSObject
  methods), File Activity and Network (kernel32 and winsock hooks). PE
  symbolication from COFF symbols, exports and `.pdata`. CI records the
  fixtures on `windows-latest`.
- Trace comparison (`gstrace diff`, Compare in the app).
- File Activity and Network instruments (agent hooks, analysis, CLI
  reports, timeline tracks and detail views, CSV/JSON export).
- Leak scanner: heap blocks scanned at a 4-byte stride (GSInlineArray
  stores objects 4-byte aligned; GUI apps reported ~1,900 false leaks);
  robustness fixes from a code review; per-thread CPU tracks; call tree
  data mining in the app; GitHub Actions CI.

First implementation (phases 0–3):

- Recording agent: CPU and main-thread wall-clock sampling, allocations with
  stacks and Objective-C classes, retain/release history, zombies,
  conservative leak checks, signposts and os_log; flushes on stop, exit and
  termination signals.
- `os_signpost` / `os_log` API (`libgsperf`).
- `libGSPerformance`: trace reader, symbolication (ELF, `.eh_frame`, ObjC
  method tables, debug files), call trees with Apple Instruments' options and data
  mining, Hangs / Allocations / Leaks / signpost analyses, recorder,
  exporters (JSON, Chrome/Perfetto, speedscope, folded stacks, CSV).
- `gstrace` command-line tool (record, info, report, export, symbolicate,
  list, install-helper).
- `gstrace-helper`: perf_event sampling of running processes through pkexec
  (polkit policy) or without privileges when perf_event_paranoid allows.
- PerformanceDashboard.app: template chooser, live recording, timeline with
  per-instrument tracks, inspection ranges, detail views, extended detail,
  attach to process, helper installation, save/export.
- Regression suite: tools-xctest unit tests and end-to-end recordings.
