# Repository guidance

Performance Dashboard: a performance analysis tool for GNUstep (an Apple
Instruments equivalent). Read README.md, then docs/architecture.md.
Never name the product, app, bundle or files "Instruments" (Apple's
trademark); "instrument" stays as the generic word for a recording type.

## Layout

- `Runtime/` — C: `libgsperf-agent.so` (LD_PRELOAD recording agent) and
  `libgsperf.so` (os_signpost/os_log API). Plain make, no gnustep-make.
  The agent must only depend on libc: never link GNUstep, libobjc or a C++
  runtime into it; resolve Objective-C runtime functions with dlsym.
  `include/GSPerformance/gsp_format.h` defines the trace format and is shared
  by every component.
- `GSPerformance/` — Objective-C (ARC) framework: reader, symbolicator, call
  trees, analyses, recorder, exporters.
- `Tools/gstrace/` — CLI. `Tools/gstrace-helper/` — privileged perf_event
  helper (C, runs as root through pkexec: keep it small and defensive).
- `Dashboard/` — the AppKit app, programmatic UI (no nibs).
- `Tests/Unit/` — tools-xctest bundle with a synthetic trace builder.
  `Tests/fixtures/` — C, Objective-C and AppKit programs with known
  behaviour. `Tests/run.sh` — the regression suite.
- `docs/` — architecture, trace format, release process, upstream issues
  and the upstream policy, xctest integration, Windows plan.

## Build and validation

In a shell with GNUstep.sh sourced:

```sh
make
make check          # = sh Tests/run.sh (needs tools-xctest; Xvfb for GUI checks)
```

Judge the suite by its exit status and the final "All N checks passed."
line. Add a unit test for analysis changes and an end-to-end check for agent
or CLI changes. Report which checks ran; do not describe unrun checks as
passing.

GUI changes: run the app under a private Xvfb display (never another
session's display) and look at screenshots; check at least Adwaita and one
other theme (Sombre). Use standard controls and theme colours (`PDTheme`).

## Conventions

- C code: GNU style as in the existing files; signal handlers must not lock
  or allocate; agent memory comes from `gsp_map`.
- Objective-C: ARC in GSPerformance, gstrace, Dashboard and tests; GNU
  brace style; match the surrounding code.
- Commits as Daniel Boyd <danieljboyd@icloud.com>. Releases follow
  docs/release.md; every tag and publish needs Dan's approval in-session.
- Anything sent to another project (issues, pull requests, patches,
  comments) follows docs/upstream-policy.md: nothing leaves without Dan's
  sign-off on the exact hash, recorded in docs/upstream-signoff.md.
  libobjc2 gets bug reports only, never code of ours.
- Never mention private package repositories or build hosts in this repo.

## Pre-push CI-parity checklist

v0.1.8 needed 7 CI rounds because each failure passed locally. Before asking for a push:

1. If the dependency set changed, build the SDK with `.github/scripts/install-gnustep.sh` (the CI path), not the local SDK.
2. Link with `-fuse-ld=lld -Wl,--no-allow-shlib-undefined`, as CI does. Every new library declares `LIBRARIES_DEPEND_UPON` explicitly.
3. Run `make check` through `scripts/with-private-home.py` in CI. It selects `PD_PRIVATE_HOME_MODE=ephemeral-ci` only on an explicitly marked ephemeral CI home; setting that variable alone cannot bypass local isolation. The harness asserts that defaults and persisted files stay inside the private home.
4. GUI probes collect all failures rather than stopping at the first, and run with two font profiles. Use `<label>`, not `<text>`, for one-line UI text.
5. For any change touching paths, files, ELF or system headers: build on the Windows CI runner (MSYS2 clang64), or at least audit for MinGW-only identifiers. Tests cannot assume `<elf.h>`; on Windows, `fileSystemRepresentation` is UTF-16.
6. Release scripts and workflows: derive every versioned filename from the version and fail closed. Do not hardcode version literals (CI enforces this with `.github/scripts/check-version-literals.py`); only explicit immutable documentation baselines are allowlisted.
