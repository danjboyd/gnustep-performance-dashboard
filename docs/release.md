# Release process

The first release, v0.1.0, targets Debian 13 amd64 only. [The release plan](v0.1.0-plan.md) defines the acceptance
gates; [the validation ledger](v0.1.0-validation.md) records their evidence.
Windows remains experimental and its existing CI/build scripts are retained.

## Approval and artifacts

Tags use `vX.Y.Z`, with `vX.Y.Z-rcN` for candidates. Every tag and every
publication requires Dan's approval in-session. Scripts and workflows only
build and validate; they do not create tags or publish releases or feeds.
Commits use Daniel Boyd <danieljboyd@icloud.com>.

Linux assets are `PerformanceDashboard-<version>-x86_64.AppImage`, its
`.zsync`, `SHA256SUMS`, provenance JSON, update-feed JSON, and the corresponding-source archive
`PerformanceDashboard-<version>-sources.tar.gz`. Checksums cover the
AppImage, zsync, provenance and source archive. Preserve the exact package hashes with acceptance
results. The download documentation must name tested distributions and
recording prerequisites, including host libunwind and binutils.

## Local gates and packaging

The v0.1.8 welcome-window work adds the pinned `gnustep-trellis` checkout from
`packaging/release-inputs.json`. `package-build.sh` builds it separately with
ARC and `hot_reload=no`, and writes a receipt for both shared libraries.
`package-stage.sh` copies their dependency closure, the welcome resource and
the LGPL notice, then compares source and staged build IDs and resource bytes.
Provenance records both library identities and the receipt. The custom Linux
corresponding-source inventory now requires fifteen Git sources, including
Trellis; omitting it or substituting its revision fails verification.
The current application binding is `packaging/linux/v018-review-inputs.json`;
the published v0.1.7 review record and SDK lock remain unchanged. Source
verification uses each application's archived dependency pins, so the older
fourteen-source v0.1.7 archive remains verifiable.
Before any release, verify that every exact source archive is accessible
without credentials through the existing public-codeload verifier. Adding
this dependency does not waive that gate or authorize publication.

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
It also inspects the actual CLI-launched target's `/proc/PID/environ` for
caller config set, unset and empty values, explicit overrides, nested launches
and packager host-snapshot precedence, with no transport markers left behind.
Known v0.1.6 preparation limitation: the legacy packager AppRun does not save
the caller's original `GNUSTEP_CONFIG_FILE` before replacing it. The CLI wrapper
saves its caller's value, but cannot recover a value already lost by AppRun.
The config fix alone retained the old packager pin. This adoption selects
v0.1.10, whose host snapshot takes precedence over the CLI fallback, but it
still requires actual generated-AppRun qualification before release.
The local adoption branch supplies that gate in
`Tests/target-config-gui-checks.py`; its three cases use their own Xvfb and
inspect only the verified target's config and transport fields. The source
is prepared; runtime qualification is still required.
AppImage smoke and update checks require `bwrap`. The shared
`scripts/with-private-home.py` helper binds a scratch directory over the
passwd home and isolates its runtime directory. A private `HOME` or caller
`GNUSTEP_CONFIG_FILE` alone is insufficient: AppRun sets its own config.
With `GITHUB_ACTIONS=true` or `CI=true` and a passwd home other than
`/home/danboyd`, the helper logs that it uses the existing ephemeral runner
isolation and runs directly. The development home always requires `bwrap`,
even with CI markers set; namespace failure stops the check there. CI keeps
its existing seccomp/AppArmor settings. `Tests/private-home-checks.py` covers
both paths and the development-home veto.
This is a package smoke test, not the entire real-application acceptance gate.
Results and provenance (source commit, pins, library build IDs and checks)
are written to `dist/packages/`. A dirty-tree dry run is never release evidence
for an exact committed candidate.

## CI

Ordinary CI builds/tests Linux and continues exercising experimental Windows.
The Linux compiler check separately builds agents with GCC and Clang and
profiles optimized C targets. The separate clean-Debian package check covers CPU profiling of GCC
Objective-C targets with the distro’s legacy runtime at -O0 and -O2.

`.github/workflows/release.yml` accepts `v*` tags, `release/**` branches or
manual dispatch with a candidate version. It builds the Linux AppImage in
Debian 13 using `scripts/ci-release-linux.sh`, then assembles the `release`
workflow artifact with checksums and Linux update feeds. No Windows job or
MSI is required for v0.1.0. A successful workflow still needs the independent
acceptance evidence in the release plan before approval.

For the v0.1.1 integration work, `assemble-candidate.yml` can collect successful
Linux and Windows producer runs at the same commit. It verifies provenance,
payload checksums, channel URLs and application source-archive identity before
creating a combined review artifact. See [the assembly contract](v0.1.1-plan.md#release-assembly-contract).
It does not replace native acceptance or publish anything.

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

Since v0.1.5, the package embeds an Ed25519 public key and its in-app updater
requires a matching signature over downloaded payload bytes. Release assembly
verifies the signatures before producing the final feed. See the
[key procedure](update-signing-keys.md) and
[v0.1.5 release ledger](v0.1.5-validation.md#published-v015--2026-11-06)
for provisioning guidance and the released artifact identities.

The v0.1.4 client has no public key, so its first update to v0.1.5 follows
the legacy path and cannot enforce the new signature. Independent
AppImageUpdate/zsync updates also bypass the in-app signature verification.
Signatures cover payload bytes, not feed metadata or the advertised version:
v0.1.5 can accept an older signed payload advertised as a newer release.
Rollback protection is planned for v0.1.6; it is not present in v0.1.5.

Publish approved assets first, then the approved feed. Test an RC1-to-RC2
update against a local feed, restart and record with RC2 before candidate
publication. The v0.1.0 validation ledger records local replacement/relaunch and
failed-download acceptance; the v0.1.5 ledger records the exact hosted
AppImage's old-client update/relaunch and recovery checks. Keep the legacy,
zsync and metadata/rollback limits distinct from payload authentication.

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

## Corresponding sources

`collect-release-sources.py` collects the application commit, pinned GNUstep
components, theme, packaging tools, AppImage runtime and the exact source
versions of staged Debian libraries. The archive includes a source inventory,
checksums and build instructions. Publish it alongside every binary release.

Custom-SDK candidates must use the reviewed lock and the actual SDK provenance;
the generic collector refuses staged custom metadata or `PD_CSD_TOOLCHAIN_LOCK`.
From a clean, committed application checkout and clean builder checkout at the
reviewed revision, use fresh work and output paths:

```sh
python3 scripts/collect-release-sources.py 0.1.7 \
  --custom-lock packaging/linux/v017-custom-toolchain.lock.proposed.json \
  --sdk-provenance "$PD_SDK/gnustep-toolchain-provenance.json" \
  --builder-source "$PD_BUILDER_SOURCE" \
  --work "$PD_NEW_SOURCE_WORK" --output "$PD_NEW_SOURCE_ARCHIVE"
```

This performs source acquisition in the disposable Debian builder, including
Debian sources; it is not an offline check. The custom bundle includes ordered
SDK patches, the application patch/applied-source tie, SDK provenance, and the
reviewed builder source. Follow `custom-sdk/APPLYING-PATCHES.txt`; the CSD
application patch is already applied. SDK provenance currently does not record
a builder revision: the bundled recipe is checked against the reviewed lock's
builder identity. Inspect the resulting archive and compare its inventory and
hashes to the candidate before publication.

Additional package acceptance commands:

```sh
# In a disposable Debian 13 container: see mounts in the script header.
bash scripts/check-debian-package.sh
# On a host with QEMU, busybox, cpio, gcc and a readable Linux kernel:
bash scripts/check-helper-vm.sh /path/to/candidate.AppImage /path/to/vmlinuz
# As an ordinary user, with loopback networking available:
python3 scripts/check-update-failures.py /path/to/candidate.AppImage
```
