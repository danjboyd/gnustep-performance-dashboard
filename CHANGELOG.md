# Changelog

## Unreleased

First implementation (phases 0–3):

- Recording agent: CPU and main-thread wall-clock sampling, allocations with
  stacks and Objective-C classes, retain/release history, zombies,
  conservative leak checks, signposts and os_log; flushes on stop, exit and
  termination signals.
- `os_signpost` / `os_log` API (`libgsperf`).
- `libGSPerformance`: trace reader, symbolication (ELF, `.eh_frame`, ObjC
  method tables, debug files), call trees with Instruments' options and data
  mining, Hangs / Allocations / Leaks / signpost analyses, recorder,
  exporters (JSON, Chrome/Perfetto, speedscope, folded stacks, CSV).
- `gstrace` command-line tool (record, info, report, export, symbolicate,
  list, install-helper).
- `gstrace-helper`: perf_event sampling of running processes through pkexec
  (polkit policy) or without privileges when perf_event_paranoid allows.
- Instruments.app: template chooser, live recording, timeline with
  per-instrument tracks, inspection ranges, detail views, extended detail,
  attach to process, helper installation, save/export.
- Regression suite: tools-xctest unit tests and end-to-end recordings.
