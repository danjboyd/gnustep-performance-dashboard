# Release process

Public releases go through the shared GNUstep release toolchain
(gnustep-packager + gnustep-cli-new). No release has been made yet. This file
records the conventions to follow so the design stays release-ready.

## Conventions

- Tags: `vX.Y.Z` (semver, first release `v0.1.0`); release candidates
  `vX.Y.Z-rcN` published as GitHub pre-releases and tested on every platform
  (install, launch, in-app update) before the final.
- Every tag and publish is approved by Dan directly in this session.
- Assets: `PerformanceDashboard-<version>-x86_64.AppImage` (+ `.zsync`),
  `PerformanceDashboard-<version>-win64.msi`, `PerformanceDashboard-<version>-win64-portable.zip`,
  plus `SHA256SUMS`, the packager's `provenance.json` and the update feed.
- README leads with a download table, per-platform install steps (including
  the unsigned-binary SmartScreen workaround), real screenshots, then
  build-from-source.
- Packaging is described by `package.manifest.json` (gnustep-packager
  `docs/consumer-setup.md`), using `themeInputs` for Adwaita (Linux) and
  WinUITheme (Windows) and `packagedDefaults.defaultTheme`.
- Commits as `Daniel Boyd <danieljboyd@icloud.com>`.

## Design constraints that follow from packaging

- `libgsperf.so` (the injected agent) links only libc/libpthread/libdl. It
  must never link GNUstep, libobjc or a C++ runtime: it is injected into
  arbitrary processes with their own versions.  Objective-C hooks are made
  through `dlsym` at runtime; libunwind is optional and loaded with `dlopen`.
- Before injecting, the recorder copies the agent to a stable per-user path
  (`$XDG_RUNTIME_DIR/performance-dashboard/` or `~/.cache/performance-dashboard/`)
  because an AppImage mount disappears when Performance Dashboard quits.
- Targets are launched with a scrubbed environment: AppRun's
  `LD_LIBRARY_PATH`, `GNUSTEP_*` and similar variables from the packaged app
  are removed so the target runs against its own libraries.  Only
  `LD_PRELOAD` and `GSP_*` are added.
- `LD_PRELOAD` is ignored for setuid/setcap binaries; the UI says so.
- Privileged sampling (attach to a running process, kernel stacks) uses a
  helper that cannot live inside the AppImage (polkit needs a root-owned
  absolute path and a policy in `/usr/share/polkit-1/actions`).  A one-time
  "Install Profiling Helper…" action runs a small, auditable installer via
  `pkexec` that installs `/usr/local/libexec/gstrace-helper` and the policy,
  version-checked so updates prompt for a reinstall.  Users who prefer no
  helper can lower `kernel.perf_event_paranoid` to 1 or grant `CAP_PERFMON`.
- Windows (after phase 3): ETW/TraceLogging for signposts and logs, DLL
  injection at launch for the agent, and a separate UAC-manifested
  helper.exe for per-operation elevation (packager MSIs are per-user).
- Flatpak is out of scope for v1.

## Open questions for gnustep-packager

- Can the AppImage backend stage an extra system payload (helper + polkit
  policy) next to the app for the installer to copy?
- Can the update feed trigger the helper reinstall check?
