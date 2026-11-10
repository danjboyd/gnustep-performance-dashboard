# Window A input review checklist

This checklist is source review only. It requests review from the project lead
before the proposed 2026-11-11 SDK/package windows. It does not start a build,
fetch sources, dispatch CI, run an app or reserve a machine. Unchecked boxes
are open gates, not successful tests. Record the final input-review decision
and source/lock identity before the lead sends a start-now message.

The current draft lock SHA-256 is
`ef07d0a12412db63e8225ade46c99163bfce48ca9f06054a3bb1ae5204476848`.
Changing its domain, flags, patches or source pins requires a new digest and
review. The lock-only LOCAL correction is c692d8a (after the input checklist f78c84b).
The recorder input is c23c087; no combined candidate has been created.

## 1. Exact source and patch identity

- [ ] Review a clean combined local candidate and its full diff against frozen
  3a115fb. Confirm only intended CSD, SDK, recorder and necessary packaging
  changes; no release ref, Windows, arm64, stable feed or upstream modification.
- [ ] Compare every full source revision/public URL in the lock to the reviewed
  seven-component inventory: libobjc2 b67709a, dispatch 4ce4012, make 50cf9619,
  Base d898f70, corebase e598349, GUI 7892137 and back bf3b3ced. No branch-head
  substitution and no libobjc2 patch. Fetch fallback refs may locate a commit;
  they must never change the required resolved commit.
- [ ] Check every patch SHA from the lock and the backport manifest, including
  all eight Base TLS originals. Review provenance/attribution and ChangeLogs.
  Keep old test messages labelled historical. Expected counts: Base8, GUI1,
  back6, total15. Backend order is old zero-extents, old WM-delete, 0003,
  0004a, 0004, 0005. Do not sort filenames lexically.
- [ ] Inspect the strict-apply/source-byte receipts already available for CSD;
  retain the same strict, non-three-way behavior for final resolved sources.
  Any context adaptation changes a patch hash and must return to review.

## 2. Builder, container and dependency inventory

- [ ] Select a public builder commit. The current inspection basis is
  gnustep-cli-new `4d5504bbedf076f824c952f4ab198d09547c8c3c`, not an implicit
  floating HEAD. Review `custom_toolchain.py`, its runtime-path helper,
  `build_infra.py` entry point, the container wrapper and Dockerfile together.
  Check the exact validator is used and no fixture libobjc2 patch is copied.
- [ ] Record hashes for those builder files and the resolved container image
  ID/digest when the authorized build occurs. The inspected Dockerfile says
  `FROM debian:13` and uses unversioned apt packages: that is a compatibility
  baseline, not a reproducibility pin. Review whether to pin an image digest
  and Debian snapshot/package versions; otherwise explicitly classify the
  result as dependency-inventory-attested, not bit-reproducible.
- [ ] Review the full Dockerfile dependency list plus draft `libxrender-dev`.
  Inspect clang/lld, libc/ICU, TLS, Cairo/X11/font and optional-feature versions
  in the actual container inventory. No dependency from an unrelated host
  installation may silently satisfy configure. Record compiler and tools.
- [ ] Inspect the wrapper's mounts and ownership cleanup: lock directory and
  builder read-only, only a new dedicated prefix parent writable. Its chown
  acts on prefix/build directories, so that parent must contain only this
  owned build. Confirm prefix guard rejects managed/system roots. Use at most
  two compile jobs; no privileged install or managed-prefix replacement.
- [ ] No hosted job is dispatched by this checklist. If a later consuming CI
  job is reviewed, pin action commits and its actual container inputs and
  obtain its exact execution authority separately.

## 3. Domain and staging: confirmed source mismatch

- [x] Source mismatch identified and domain choice made: the initial SYSTEM
  draft did not match `scripts/package-stage.sh`'s Local/Library and Local/Tools
  paths. The lead selected LOCAL in message21959; lock-only c692d8a changes
  the domain and review note, without stager domain changes.
- [ ] Review the new lock digest above and confirm the complete header, tool,
  library, resource and GNUstep configuration search paths. The builder's
  Objective-C/Blocks header links are Local too. Relocation remains unrun;
  selecting a compatible directory layout is not runtime qualification.
- [ ] Inspect `package-build.sh`, theme build, linker/include search paths,
  GNUstep.sh and generated configuration as one same-SDK path. Remove stale
  objects in an isolated owned checkout at the authorized build, not the
  shared working tree. Never reuse a host-built theme/app merely because
  sonames match.

## 4. Backend feature and linker parity

- [ ] Review the actual pinned backend configure options (`--enable-server=x11`,
  `--enable-graphics=cairo`) and their generated feature output. Keep explicit
  GLX/RandR/Xcursor/Xfixes/Xmu exclusions visible. Inspect CSD source requirements
  for Cairo alpha, XRender, XShape/ARGB and frame extents; if an exclusion
  prevents them, change/review the lock rather than hiding a fallback.
- [ ] Decide the old backend make argument
  `ADDITIONAL_LDFLAGS=-Wl,--as-needed`. The inspected custom recipe accepts
  configure args and invokes plain make; there is no per-component make-arg
  field. Its `pd_review` note is not executed. Either review a builder extension
  and pin that exact builder, or explicitly accept the first comparison without
  this flag and require linked-closure inspection. Never insert ignored schema
  keys or overwrite the prefix's LDFLAGS with a guessed configure assignment.
- [x] Added source/unit-level opt-in staging safeguards described below. The
  static old-payload rejection is expected; no custom CSD payload passed yet.
- [ ] **Review and use backend binding:** the legacy package stage defaults to
  `build-libs-back.sh`, then overwrites the staged backend with that result.
  That script consumes the old two-patch lock, not these CSD backports. Bind
  `LIBS_BACK_BUNDLE` explicitly to the reviewed custom SDK's exact built bundle,
  verify provenance/build ID, and refuse the old fallback for this candidate.
- [ ] Bind `ADWAITA_THEME` to a fresh theme build from its reviewed source pin
  using the same custom SDK. The existing helper uses nproc; review a bounded
  two-job invocation instead for the shared-machine window. Preserve the
  feature/compile command and theme SHA/build ID, not just a directory name.

## 5. Provenance and promotion into window B

- [ ] Require custom provenance `official=false`, exact lock copy/digest,
  seven resolved commits, all15 applied hashes/order, install domain,
  configure flags, build/container/compiler inventory and ELF SHA/build IDs.
  Review cache identity before use; no old official SDK cache substitutes.
- [ ] **Resolve provenance writer mismatch before packaging:** current
  `package-linux.sh` reports managed `release-inputs.json`, the old two-patch
  backend lock and three managed metadata filenames. It does not consume
  `gnustep-toolchain-provenance.json` as the custom input identity. Review a
  custom-aware writer/input route; do not ship metadata naming the old recipe
  while bundling the new SDK. An environment boolean is not payload verification.
- [ ] At the authorized runtime/package phase, compare pre-strip SHA/build IDs
  to custom provenance, then retain the stripping/relocation transformation
  ledger and final payload hashes. Require actual loaded maps for GUI/CLI,
  backend and theme. Add gsp-launch mode/hash/NEEDED checks to both package
  copies and ensure only libc is needed.
- [ ] Record each component/build step's exit status. Any failed source,
  configure, build or identity gate stops promotion; keep its log. Only after
  review of successful window-A evidence may window B use the new prefix.

## 6. Owned compositor window and reservation boundary

The lead will request A+B, C and D for 2026-11-11, with separate start-now
messages. None is started or booked by this document. For C, use a new owned
Xvfb display with an owned compositing WM (`gnome-shell --x11` or
`mutter --x11`) in its own private D-Bus session. Exact supported invocation
and compositor capability are checks for that window, not assumptions here.
Never reuse the shared desktop or another application's display/session.

- [ ] Before screenshots, inspect root `_NET_SUPPORTED` for
  `_GTK_FRAME_EXTENTS` as requested by the lead, and record actual client
  frame-extents/ARGB/window properties. If the advertisement/capability gate
  is absent, stop and report it; do not substitute bare Xvfb as a positive test.
- [ ] Capture normal windowed Adwaita and Sombre, menus/popovers and focus/close/
  move/resize/restore states with exact loaded binaries. Keep maximized views
  separate from the corner/shadow acceptance images.
- [ ] Ledger display/WM/compositor/D-Bus/server/target identities and start
  times. Stop/reap only owned processes; audit actual host and explicitly
  release the window to the lead and waiting machine owners. No timing study
  overlaps any correctness/build window.

## Custom CSD staging interface (source/unit checked only)

Set `PD_CSD_TOOLCHAIN_LOCK` to the exact reviewed LOCAL lock to select this mode.
A prefix with `gnustep-toolchain-provenance.json` cannot fall back to legacy
staging if this variable is absent. Before GNUstep activation, a fallback build
or stage mutation, custom mode requires all of:

- `LIBS_BACK_BUNDLE`: the exact custom SDK Local backend bundle;
- `PD_CSD_BACKEND_SHA256`: its unstripped executable's approved digest, also
  matched to the custom SDK ELF provenance;
- `ADWAITA_THEME` and `PD_CSD_ADWAITA_SHA256`: exact fresh theme bundle/binary;
- `PD_CSD_ADWAITA_BUILD_RECEIPT`: a build-produced JSON identity receipt.

The theme receipt has `schemaVersion: 1`, `themeBinarySHA256`,
`toolchainLockSHA256`, `toolchainProvenanceSHA256` and `themeSourceRevision`.
It must bind the theme bytes and reviewed theme source pin to this exact lock
and SDK provenance. The future reviewed theme build job must produce it from
its actual build and retain the compile log; manually matching JSON identities
alone cannot prove compilation origin. This receipt is not present for a new
SDK yet, so current custom staging correctly stops rather than reusing a theme.

The input checker also verifies official=false, LOCAL domain, the component
URLs/resolved revisions/configuration/applied patches and local patch digests.
Explicit bundle variables prevent the two legacy build helpers from running.
After final stage copies/stripping, the backend must contain both
`GSBackWindowShadows` and `GSBackWindowCornerRadius`; `nm -D --defined-only`
must show the exact GUI export `GSThemeInstallBackendDefaults`. Any missing
input, digest, identity, command or capability fails packaging.

Nine static unit methods exercise missing keys/export, nm failure, input
identity mismatches, wrong backend provenance path and early failure before
stage mutation/fallback. Their positive fixtures are synthetic parser tests,
not a compiled custom SDK. The existing v0.1.6 AppDir is rejected for missing
backend CSD keys, as required. No positive custom ELF or compositor/runtime
qualification is claimed. The AppImage entry point now refuses custom inputs before any work, closing
the old managed-provenance mislabelling route. A custom-aware writer remains
an open gate before window-B package assembly. See
`v017-builder-and-theme-recommendations.md` for the builder/container/linker
recommendations, exact inspected file digests and same-SDK theme receipt recipe.
