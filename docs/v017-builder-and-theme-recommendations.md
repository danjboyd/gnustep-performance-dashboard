# v0.1.7 builder inputs and theme recipe for lead review

Source/unit work only. No SDK/theme/container build or product runtime has
been started. The lead decides these local build inputs before window A;
its start-now message and the reviewed identities are still required. The
confirmed 2026-11-11 windows are15:00–16:00Z SDK/headless/package,
16:00–16:10Z compositor and16:10–16:20Z GUI/TLS, cleanup included. Other
approved workloads may overlap; these are not exclusive-CPU reservations.

## Recommended first review SDK

| Input | Recommendation | Reason and acceptance boundary |
| --- | --- | --- |
| Builder | Use public gnustep-cli-new 4d5504bbedf076f824c952f4ab198d09547c8c3c, whose wrapper/validator/recipe were inspected; record file digests too | Avoid changing the builder and SDK sources together; do not dispatch its fixture-only workflow |
| Source/domain | LOCAL lock c692d8a, SHA ef07d0a12412db63e8225ade46c99163bfce48ca9f06054a3bb1ae5204476848; seven exact revisions and15 hashes | Matches current staging directories and keeps libobjc2 unpatched; no pin or patch substitution |
| Container | Debian13 linux-amd64-clang recipe plus explicit libxrender-dev; inspect/record the resolved base-image and final-image IDs/digests and full package versions before compilation | The inspected Dockerfile uses a mutable debian:13 tag and unversioned apt packages; classify this first SDK as inventory-attested, not bit-reproducible |
| Dependency policy | Keep the inspected Dockerfile dependency set unchanged beyond reviewed libxrender-dev; retain actual clang/lld, libc/ICU, TLS, Cairo/X11/font and optional-feature inventory | Do not guess package versions now or claim an unobserved image digest. If exact reproducibility is required for this first build, stop for a separately reviewed digest/snapshot recipe instead |
| Backend linker flag | Explicitly accept omitting the old per-backend make argument ADDITIONAL_LDFLAGS=-Wl,--as-needed for the first unsigned review SDK | Current builder has no supported make-arg interface. This avoids an unreviewed builder extension or silently ignored key. It is a deliberate difference, not parity |
| Linker acceptance | Inspect source linker commands and final DT_NEEDED closure against the retained backend; reject unexpected or unbundled dependencies | A successful compile does not settle the omission. Failure means revise the recipe, not borrow host libraries or overwrite prefix LDFLAGS |
| Feature flags | Keep X11/cairo and the visible legacy exclusions for the first comparison; check generated configure macros/logs against CSD requirements | If CSD needs a disabled facility, stop and propose the exact lock change rather than accepting a no-corners fallback |
| Resource limit | At most two compile jobs, new dedicated prefix/build directory, owned checkout; record any concurrent approved workload | The SDK build duration is unknown; request an extension/new window before the agreed cap |

The lead approved the first-SDK inventory policy, inspected builder/LOCAL lock,
deliberate linker-flag omission and theme recipe in message22079. The linker
command/DT_NEEDED closure comparison is a hard promotion gate; reject unexpected
dependencies. These local choices do not start a build. Neither is a release approval. Capturing an image
ID after a build does not retroactively pin future builds: subsequent builds
must reuse the reviewed immutable image or return to input review.

The inspected Dockerfile includes base build tools; clang/lld; BlocksRuntime;
OpenSSL/GnuTLS/curl; zlib; FreeType; XML/XSLT; ICU; Avahi; libffi; JPEG/TIFF/PNG;
Cairo and Xft/Xt/X11/Xext development libraries. Optional configure choices must
be tied to the actual resolved versions, not this prose list. The source-file
digest inventory accompanying this document identifies the exact inspected
recipe bytes; no resolved image/package inventory is fabricated today.

## Same-SDK Adwaita build recipe (unrun)

Use the existing reviewed public theme pin from `packaging/release-inputs.json`:
`b74231f84bc139a50ad50459acfaed10a07a4642`. Do not use an installed theme or
an earlier SDK's Adwaita binary. A bounded future build job should:

1. Verify the completed custom prefix's provenance is official=false, LOCAL,
   with the exact lock digest, resolved sources and all15 applied hashes.
   Freeze the accepted provenance JSON and its SHA before the theme build.
2. Allocate a new owned theme checkout/build directory. Fetch the pinned public
   revision through the existing pinned-checkout identity path, then verify its
   actual HEAD equals the full revision above. No unreviewed patch or dirty
   source is allowed. Record HEAD and source diff status in its log.
3. Start a fresh shell for this one build, source only this custom prefix's
   System/Library/Makefiles/GNUstep.sh, and verify compiler/include/library paths
   name the custom prefix. Remove inherited host GNUstep search/compile flags;
   capture the actual resolved build environment. Keep the existing prefix-map
   behavior for assertion paths. Never install into a host/managed prefix.
4. Build only in that owned tree, with make -j2 and the reviewed auxiliary
   prefix-map flags. The existing build-adwaita.sh uses nproc, so do not call it
   unchanged under the two-job slot cap. Preserve the complete compile/link
   log, exit status and theme binary SHA/build ID. No GUI launch belongs here.
5. Only after successful build and source/input checks, generate the theme
   receipt from actual files. Required schema fields are listed below. Keep
   its build log, source status and SDK identity as review evidence. An unsigned
   JSON assertion alone does not prove compilation origin.
6. Bind ADWAITA_THEME to that exact bundle; derive PD_CSD_ADWAITA_SHA256 from its
   Adwaita binary and PD_CSD_ADWAITA_BUILD_RECEIPT from the generated receipt.
   Bind LIBS_BACK_BUNDLE and PD_CSD_BACKEND_SHA256 to the accepted SDK's own
   Local backend, and set PD_CSD_TOOLCHAIN_LOCK to the reviewed lock. The
   staging checker independently compares those identities before any fallback.

Required receipt fields:

| Field | Derivation |
| --- | --- |
| schemaVersion | Integer1 |
| themeSourceRevision | Exact checked-out b74231f84bc139a50ad50459acfaed10a07a4642 |
| themeBinarySHA256 | SHA-256 of the successful build's Adwaita binary |
| toolchainLockSHA256 | SHA-256 of the exact reviewed lock consumed by the SDK |
| toolchainProvenanceSHA256 | SHA-256 of the completed SDK provenance JSON |

Also retain build-log SHA, actual build command/compiler, UTC start/end,
source-clean status and theme build ID in the evidence packet. If provenance or
source bytes change between build and stage, regenerate/review the appropriate
build, never edit a receipt to fit another binary. Staging copies the accepted
lock, SDK provenance and theme receipt into metadata for later tie-out.

## AppImage provenance boundary

The CSD-only unsigned review path now calls `write-csd-provenance.py`, which
constructs a fresh custom schema. It embeds the exact reviewed lock, SDK
provenance and theme receipt, an explicit per-component patch SHA list and
actual selected payload identities. It never merges the managed recipe's
inputs, two-patch backend list or managed metadata fields. The managed path
continues to use its existing writer.

Before fetch/build/stage/runtime, CSD mode requires the same complete explicit
SDK/backend/theme/receipt inputs as staging. An unselected custom SDK is refused;
custom mode with `--release` is also refused. Before writing the sidecar, the
writer repeats input/capability checks, requires embedded metadata bytes to
match those inputs and verifies selected SDK ELF SHA/build IDs against SDK
provenance. It resolves library symlinks because the builder inventories real
files only. Staged backend, GUI, Base, libobjc2 and dispatch must retain their
source build IDs; the theme must match its source build ID and receipt hash.
Pre/post transformation hashes are recorded separately. App, agent and both
launcher copies also receive final identity records. A missing input or failed
identity refuses the new sidecar; no old managed identity is substituted.

This is a selected-file identity check, not a claim that every SDK file or any
runtime behavior has been qualified. Nine static writer tests use synthetic
payloads and mocked ELF-tool output, covering source/receipt retention, missing
and changed inputs, SDK mutation, build-ID mismatch, missing helper and resolved
symlink identities. The staging gate has its own nine static unit tests.
There is no positive custom SDK/AppImage or GUI runtime result today.

The lead must review this CSD-only path before its future execution. If it is
not reviewed in time, window B is stage-only: an AppDir, not an AppImage.
Windows C/D must then use that exact staged AppDir through AppRun and label all
results accordingly. AppImage qualification moves to a later slot. No tag,
release, feed change or hosted dispatch is part of this recipe or local review.
