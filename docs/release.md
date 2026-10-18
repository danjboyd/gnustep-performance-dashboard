# Release process

Public releases go through the shared GNUstep release toolchain
(gnustep-packager + gnustep-cli-new). No release has been made yet. This file
records the conventions to follow so the design stays release-ready, and how
the packages are built.

## Conventions

- Tags: `vX.Y.Z` (semver, first release `v0.1.0`); release candidates
  `vX.Y.Z-rcN` published as GitHub pre-releases and tested on every platform
  (install, launch, in-app update) before the final.
- Every tag and publish is approved by Dan directly in this session.
- Assets: `PerformanceDashboard-<version>-x86_64.AppImage` and its
  `.zsync`, `PerformanceDashboard-<version>-win64.msi`, plus `SHA256SUMS`
  and the provenance files; the update feeds go to GitHub Pages (Updates,
  below).
- README leads with a download table, per-platform install steps (including
  the unsigned-binary SmartScreen workaround), real screenshots, then
  build-from-source.
- Packaging is described by `packaging/package.manifest.json`
  (gnustep-packager `docs/consumer-setup.md`): Adwaita is staged by
  `scripts/package-stage.sh` for Linux, WinUITheme comes from `themeInputs`
  for Windows (`platformOverrides.windows`).
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
  records a program (Leaks template, a fixture with ten known leaks), quits
  on SIGTERM, and that its bundled `gstrace` records the same.

The output goes to `dist/packages`: the AppImage, the packager's metadata,
diagnostics and provenance files, and our provenance JSON (commit, pins,
build IDs, checks).

## The Windows MSI

Built on GitHub's `windows-latest` runner by gnustep-packager's reusable
workflow at its pin, with the gnustep-cli-new toolchain: the manifest's
Windows overrides run `scripts/package-build-windows.ps1` and
`scripts/package-stage-windows.ps1` (adapted from ScreenshotTool's), which
stage the app, `gstrace.exe`, the recording agent, the DLLs the programs
import (by import closure from CLANG64), GNUstep's resources and tools, a
relocatable `GNUstep.conf` and the license notices. The packager adds
WinUITheme, builds the MSI and a portable zip, installs the MSI, audits its
runtime and launches it. The MSI is per-user and unsigned.

## The release workflow

`.github/workflows/release.yml` runs on `v*` tags, on `release/**` branches
and by hand (with a version such as `0.1.0-rc1`):

- `linux`: the AppImage in a Debian 13 container
  (`scripts/ci-release-linux.sh`: the pinned gnustep-cli-new bootstrap and
  PowerShell, then `scripts/package-linux.sh --release` with its checks).
- `windows`: the MSI, as above.
- `windows-record`: installs the MSI on a clean runner and records
  `defaults.exe` with the installed `gstrace.exe`.
- `release`: the AppImage and the MSI with `SHA256SUMS`, as the workflow
  artifact "release".

Nothing is signed, tagged or published by the workflow: a tag, and
publishing the artifact as a GitHub release, each need Dan's approval.

## Code signing

Nothing is signed yet: there is no certificate. The release workflow is
ready for one. gnustep-packager's MSI backend signs the launcher EXE and
the MSI (signtool) when the Windows job runs with `sign-artifacts`, which
`release.yml` sets from the repository variable `PD_SIGN_MSI` (`true` to
sign), with:

- secrets `PD_SIGN_PFX_BASE64` (the PFX, base64), `PD_SIGN_PFX_PASSWORD`,
  and optionally `PD_SIGN_CERT_SHA1`;
- variable `PD_SIGN_TIMESTAMP_URL` (the certificate authority's RFC 3161
  timestamp server).

What Dan has to decide: how to sign. Since 2023 a new code-signing
certificate's key (OV or EV) has to live on a hardware token or in a
cloud HSM, so the PFX secrets above only suit an existing exportable
certificate; with a new one, the likely route is a cloud signing service
(signtool through the provider's key storage provider, selected by
`PD_SIGN_CERT_SHA1`, or the provider's own GitHub action), which needs a
change to the Windows job once one is chosen. Open-source projects can
get signing free from some services (SignPath Foundation). The AppImage
is not signed; the update feed's SHA-256 covers its downloads.

## Updates

The packages update themselves through gnustep-packager's updater
(`third_party/gnustep-packager-updater/VENDORED.md`): the app links
GPUpdaterCore and GPUpdaterUI and carries `gp-update-helper` in its
bundle; it checks its feed 15 seconds after launch (once the template
chooser is closed) and at most daily, and **Performance Dashboard ▸ Check
for Updates…** checks by hand. A build from source has no packaged
configuration, so the updater stays off.

- Feeds, on GitHub Pages:
  `https://danjboyd.github.io/gnustep-performance-dashboard/updates/{linux,windows}/{stable,prerelease}.json`.
  A version with a suffix (`0.1.0-rc1`) is built for the prerelease
  channel and feeds (`scripts/prerelease-manifest.py`), so release
  candidates follow candidates and then the final release.
- Each package build writes the feed for its package beside it
  (`*.update-feed.json`; the AppImage also gets `.zsync` and embedded
  update information). The release workflow's `release` artifact holds
  them under `site/updates/...`, at the paths of the feed URLs.
- Publishing order: the release assets (the feeds point at them), then the
  feeds to GitHub Pages. Both need Dan's approval; GitHub Pages also
  needs the repository to be public (or a paid plan).
- Tested 2026-10-17 with the AppImage: rc1 pointed at a local test feed
  (`GP_UPDATER_FEED_URL=http://127.0.0.1:...`) offered rc2, downloaded
  it, and on **Restart and Install** replaced its own file and started
  rc2. The MSI path is not tested yet.
- Feeds are not signed (`updates.publicEDKey` is unset): the helper checks
  each download's SHA-256 from the feed, which is only as trustworthy as
  the HTTPS feed itself.

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
