# Release process

The first release, v0.1.0, targets Debian 13 amd64 only. No release has
been published. [The release plan](v0.1.0-plan.md) defines the acceptance
gates; [the validation ledger](v0.1.0-validation.md) records their evidence.
Windows remains experimental and its existing CI/build scripts are retained.

## Approval and artifacts

Tags use `vX.Y.Z`, with `vX.Y.Z-rcN` for candidates. Every tag and every
publication requires Dan's approval in-session. Scripts and workflows only
build and validate; they do not create tags or publish releases or feeds.
Commits use Daniel Boyd <danieljboyd@icloud.com>.

Linux assets are `PerformanceDashboard-<version>-x86_64.AppImage`, its
`.zsync`, `SHA256SUMS`, provenance JSON and update-feed JSON. Checksums cover
both AppImage and zsync. Preserve the exact package hashes with acceptance
results. The download documentation must name tested distributions and
recording prerequisites, including host libunwind and binutils.

## Local gates and packaging

In a shell with GNUstep.sh sourced:

```sh
scripts/check-linux-release.sh
scripts/package-linux.sh --version 0.1.0-rc1
# After review and commit, from a clean tree with pinned inputs:
scripts/package-linux.sh --release --version 0.1.0-rc1
```

The first command requires tools-xctest, Xvfb, xdotool, ImageMagick,
Adwaita and Sombre, and rejects skipped checks. Packaging additionally needs
PowerShell 7, squashfs-tools, desktop-file-utils and a gnustep-cli-new install
(`GNUSTEP_CLI_ROOT`, default `~/.local/share/gnustep-cli`).

`packaging/package.manifest.json` describes the package. `package-build.sh`
and `package-stage.sh` build and stage the app, gstrace, the helper and polkit
policy, GNUstep, patched libs-back, Adwaita, configuration and notices.
`packaging/release-inputs.json` and `packaging/linux/libs-back/` pin the other
inputs; `pinned-checkout.sh` checks them out under `out/`.

`check-appimage-record.sh` launches a private Xvfb and verifies that the app
and its bundled gstrace record a fixture's ten known leaks and finish cleanly.
This is a package smoke test, not the entire real-application acceptance gate.
Results and provenance (source commit, pins, library build IDs and checks)
are written to `dist/packages/`. A dirty-tree dry run is never release evidence
for an exact committed candidate.

## CI

Ordinary CI builds/tests Linux and continues exercising experimental Windows.
The Linux compiler check separately builds agents with GCC and Clang and
profiles optimized C targets. It does not establish legacy GNU Objective-C
runtime support.

`.github/workflows/release.yml` accepts `v*` tags, `release/**` branches or
manual dispatch with a candidate version. It builds the Linux AppImage in
Debian 13 using `scripts/ci-release-linux.sh`, then assembles the `release`
workflow artifact with checksums and Linux update feeds. No Windows job or
MSI is required for v0.1.0. A successful workflow still needs the independent
acceptance evidence in the release plan before approval.

The bootstrap, signed release manifest and both payload archives are locked by
SHA256 in `packaging/release-inputs.json`. `fetch-toolchain.py` verifies the
cache on every use; changed upstream assets fail closed. The bootstrap uses
its local `--manifest` mode and still verifies the signature and payloads.
CI refuses an existing toolchain installation. Provenance includes the input
lock, embedded component inventory and compiler version. Debian package
versions are recorded; this is not a bit-for-bit reproducibility claim.

## Updates

The app uses the vendored gnustep-packager updater (GPUpdaterCore,
GPUpdaterUI and gp-update-helper). Packaged builds check after launch and
at most daily; source builds without packaged configuration leave it off.
The manual action is **Performance Dashboard ▸ Check for Updates…**.

Linux feeds are at
`https://danjboyd.github.io/gnustep-performance-dashboard/updates/linux/{stable,prerelease}.json`.
Suffix versions use the prerelease channel through `prerelease-manifest.py`.
The release artifact holds feeds under `site/updates/linux/`.

Publish approved assets first, then the approved feed. Test an RC1-to-RC2
update against a local feed, restart and record with RC2 before candidate
publication. An earlier local AppImage update succeeded on 2026-10-17; repeat
it for the actual release inputs. No package or feed signing is configured;
SHA-256 validation trusts the HTTPS feed. Document that limitation honestly.

## Packaging boundaries

The injected library is `libgsperf-agent.so` (not the signpost API
`libgsperf.so`). It must not link GNUstep, libobjc or a C++ runtime. It is
copied to a stable per-user path before injection. The target's environment
is scrubbed of packaged GNUstep/library overrides so it uses its own runtime.
Host libunwind is dynamically loaded for optimized stacks; missing support
is a recording warning. Source-line lookup currently uses host addr2line.

The privileged helper cannot live only inside an ephemeral AppImage mount.
Install Profiling Helper installs the root-owned helper and polkit policy
through pkexec. Helper installation, permission denials, attach and removal
must be verified on a disposable machine before release. Do not weaken the
helper policy to make an acceptance test pass.
