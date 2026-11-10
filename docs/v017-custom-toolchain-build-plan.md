# v0.1.7 custom CSD toolchain: draft consuming job

This is a source-only design. No workflow is enabled, dispatched or published,
and no toolchain or app has been built with this lock. The output will be an
unofficial, application-owned SDK, separate from managed gnustep-cli artifacts.

## Inputs and current validation

The candidate lock is `packaging/linux/v017-custom-toolchain.lock.draft.json`.
Its seven source revisions come from the released CLI v0.1.5 SDK identities:
Base `d898f70` plus its eight hash-checked TLS patches, libobjc2 `b67709a`,
libdispatch `4ce4012`, make `50cf9619`, corebase `e598349`, GUI `7892137` and
backend `bf3b3ced`. Full commits and public URLs are in the lock.

GUI adds the reviewed PD backport of public v7 0001. Backend applies PD's
existing zero-extents and WM-delete patches, then CSD 0003, 0004a, 0004 and
optional menu/popover 0005, in that explicit order. All 15 patches are inside
the lock directory and have SHA-256 identities. No libobjc2 patch is added.
The Base carry patches are explicit; an empty historical metadata list is
not treated as evidence that they were absent.

Schema and local patch-digest validation passed using the custom-toolchain
validator source inspected at gnustep-cli-new commit
`4d5504bbedf076f824c952f4ab198d09547c8c3c`. This did not fetch sources, compile,
install or run a program. CSD exported-series application was separately
checked strictly in fresh source trees; that also is not runtime validation.
The original upstream test results in patch messages are labelled historical.

## Proposed consuming job

Use the documented builder from `docs/custom-toolchains.md` in gnustep-cli-new.
The source inspection above identifies an implementation, not permission to
run it or a finalized build-input decision. Before implementation, review a
public builder commit and pin it, its container recipe and action revisions.

The existing gnustep-cli `Custom Toolchain` workflow is a useful example, but
its current dispatch has no project-lock input and always generates a fixture
lock. That fixture adds a libobjc2 test patch and disables CUPS. Do not dispatch
that fixture workflow as though it builds the PD lock, or copy its test patch.
A consuming PD job needs these concrete steps:

1. Check out the reviewed PD source and exact reviewed gnustep-cli builder.
   Verify the lock and every patch before a cache lookup or source fetch.
2. Allocate a fresh runner-temporary prefix and work directory. Never use a
   managed prefix or replace a developer's installed GNUstep libraries.
3. Build in the Debian 13 `linux-amd64-clang` image through the documented
   wrapper. The proposed invocation, **not run here**, is:

   ```sh
   scripts/dev/build-custom-toolchain-in-container.sh "$PD_LOCK" "$PD_PREFIX" 2
   ```

   These variables belong to the consuming CI job. This is not a command for
   a user to run now. The wrapper validates first, builds the selected image,
   then applies verified component patches and builds into the private prefix.
4. Inspect provenance before building PD. Require `official: false`, exactly
   the reviewed seven resolved source commits, all applied patch paths and
   hashes, target/compiler/container identity, and every ELF SHA/build ID.
   Compare against the lock itself, not the example workflow's fixture counts.
   Refuse a cache with different source or patch bytes.
5. Build the theme, runtime, framework, CLI, helper and GUI with this same SDK.
   Use its GNUstep.sh and private homes. Do not combine host headers or an old
   prebuilt theme/app with newly compiled GUI libraries.
6. Run the reviewed qualification matrix against the actual payload, then
   assemble an unsigned local/CI review artifact and its source/provenance
   packet. Inspect the final AppDir's loaded maps and ELF hashes as well as
   its source inputs. A successful SDK build alone is not app qualification.
7. Upload only internal review artifacts if that exact job is authorized.
   Tag, release, signing, publish and stable-feed actions remain separately
   approved steps. No publishing step belongs in this draft job.

A proposed cache key includes the complete lock and patch-set digest, builder
commit, container recipe/image digest, target and compiler identity. Record
resolved package versions and optional-feature choices; Debian image tags and
unversioned package names alone are not bit-reproducible inputs.

## Layout and feature choices to review before a build

The reviewed follow-up selects `LOCAL`, matching the current PD stager's
Local/Library and Local/Tools input layout. The original SYSTEM draft was
incompatible with those hardcoded paths; the lead selected the smaller LOCAL
change rather than a new stager domain. Lock-only commit c692d8a has SHA-256
`ef07d0a12412db63e8225ade46c99163bfce48ca9f06054a3bb1ae5204476848`.
Schema/patch-digest validation passed again; no build has run. Verify headers,
libraries, backend bundle, tools and configuration discovery after relocation.
The input-review checklist describes the custom staging mode and remaining
builder/link-flag/provenance gates.

The backend explicitly selects X11/cairo with the base's supported
`--enable-server=x11` and `--enable-graphics=cairo` options. It retains the
existing PD disabled-extension flags for a controlled first comparison.
`libxrender-dev` is an explicit container dependency in addition to the base
recipe's cairo/X11/font dependencies. Configure output and linked closure
must prove the actual feature selection; flag names alone are not proof.
Revisit any disabled feature that the CSD code actually needs.

The old backend lock also supplies
`ADDITIONAL_LDFLAGS=-Wl,--as-needed` as a make argument. The current custom
builder schema/recipe exposes configure arguments, but no per-component make
arguments. The draft records this as **non-executable review metadata**;
it does not pretend that the make setting was applied. Before approving a
build, either extend/review the builder's supported make-argument mechanism,
or accept and record the deliberate link-flag difference and check ELF
closure. Do not insert a silently ignored `make_args` field or overwrite
prefix library flags with a guessed configure environment assignment.

The retained GUI base is before the NSTextAlignment renumbering boundary
`3237efda`, avoiding that additional ABI change. Any later move across it must
rebuild all dependent code with matching headers/runtime and add value,
rendering and archival compatibility checks despite unchanged sonames.

## Qualification and review limits

The next matrix must cover custom SDK configure/API/ABI and provenance, PD
unit/regression and six CLI exit results, agent storage/finalization errors,
caller environment set/unset/empty, actual AppRun/updater compatibility and
strict TLS positive/issuer/hostname controls. It must also cover ownership of
child status with an active Foundation run loop; these CSD patches do not fix
that recorder problem.

Corner/shadow acceptance requires a compositor-capable private X11 session,
ARGB/cairo support, normal unmaximized windows, theme defaults and actual
`_GTK_FRAME_EXTENTS`, plus close/Alt-F4, move/resize, menus/popovers, first-click
and tooltip checks. Bare Xvfb is not a positive corner test. Record exact
loaded binaries, preserve foreign sessions, and include owned cleanup in the
reserved window. Windows and arm64 remain separate qualification work.

The public v7 0004a test and the new backport hashes retain their review gates;
prior approval of another patch version is not approval of these files. No
new source lock, SDK artifact or app is approved to ship by this design.
