# Release process

Public releases go through the shared GNUstep release toolchain
(gnustep-packager + gnustep-cli-new). No release has been made yet. This file
records the conventions to follow so the design stays release-ready, and how
the Linux AppImage is built.

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

## Building the Linux AppImage

```sh
scripts/package-linux.sh --version 0.1.0-rc1   # dry run: any tree
scripts/package-linux.sh --release --version 0.1.0-rc1   # clean tree, pinned inputs
```

It needs PowerShell 7, Xvfb, squashfs-tools, desktop-file-utils and a
gnustep-cli-new install (`GNUSTEP_CLI_ROOT`, default
`~/.local/share/gnustep-cli`). The pieces, adapted from LinDirStat's:

- `packaging/package.manifest.json`: the gnustep-packager manifest.
- `scripts/package-build.sh`, `scripts/package-stage.sh`: the build and
  stage commands the packager runs. The stage holds the app (with the
  recording agent, gstrace-helper and its polkit policy), `gstrace`, the
  GNUstep runtime, the patched libs-back and the Adwaita theme, a relocatable
  `GNUstep.conf` and the license notices.
- `packaging/release-inputs.json`, `packaging/linux/libs-back/`: the pinned
  inputs (Adwaita, gnustep-packager, appimagetool; libs-back with its
  patches), checked out by `scripts/pinned-checkout.sh` into `out/`.
- `scripts/check-appimage-record.sh`: the release check that the AppImage
  records a program (Leaks template, a fixture with ten known leaks) and
  quits on SIGTERM.

The output goes to `dist/packages`: the AppImage, the packager's metadata,
diagnostics and provenance files, and our provenance JSON (commit, pins,
build IDs, checks).

Not done yet: the Windows MSI (it needs a Windows host or CI runner), the
update feed and in-app updates (`updates` is disabled in the manifest), and a
release workflow.

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
