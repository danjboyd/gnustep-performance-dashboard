# v0.1.7 slot corrections proposed for local review

This branch starts at frozen candidate
`95dcc66f9dc77b919d1b3f87f0532c8b237f3f51`. The lead approved its direction, and it now carries combined proposed inputs
and the CSD-only application defaults change. It does not change frozen
branches or any built payload.
No new SDK/app/theme build, GUI session, release or publication is authorized
by this document. The November 11 artifact is **LOCAL REVIEW — dependency
delta unresolved, NOT a release candidate**.

## XFixes is a necessary missing input

The actual backend configured with `HAVE_XFIXES` undefined. The lock forces
`ac_cv_lib_Xfixes_XFixesSelectSelectionInput=no`. In the patched backend:

- `configure.ac:192` defines `HAVE_XFIXES` and adds `-lXfixes` only when its
  library check succeeds.
- `Source/x11/XGServer.m:526` starts `xfixesEventBase` at -1. The compiled-in
  XFixes branch must successfully query the server and register compositor
  selection notifications to give it a nonnegative value.
- `Source/x11/XGServerWindow.m:759` requires both a nonnegative event base
  and `_compositorShowsAlpha` for `_compositorShowsMargin`.
- Alpha in turn requires a live compositing-manager selection and an ARGB
  visual. Styled shadow eligibility additionally requires theme defaults and
  WM `_GTK_FRAME_EXTENTS` support.

Thus the accepted lock makes margins impossible, even on the private GNOME
compositor that advertised `_GTK_FRAME_EXTENTS`. Enabling the build feature
removes that unconditional failure. It cannot prove the remaining runtime
conditions: those must be measured in the next slot.

The sibling `v017-custom-toolchain.lock.proposed.json` removes the forced XFixes-negative cache answer, adds `libxfixes-dev` to the
explicit Debian13 inputs, and carries the approved Cairo link patch after
the original six backend patches. All seven source revisions, the original
fifteen patch hashes/order, LOCAL domain and other exclusions are preserved.
The combined SDK count is16: Base8, GUI1, backend7. A separate application
defaults patch makes17 reviewed patch entries; the SDK builder never applies
that application patch. The pinned
builder validator accepts the proposal and patch bytes. No configure or SDK
build was run for it. Capture the new exact lock digest, resolved image and
package inventory before any separately reviewed build. A new direct
`libXfixes.so.3` dependency is expected and must be explicitly reviewed; never
silently widen the dependency baseline.

## The package suppresses the early theme preference

This is confirmed by a headless probe of the exact packaged GUI library,
not just inferred from source. `Tests/probes/theme-backend-defaults.m` calls
only defaults and the exported hook; it never creates NSApplication or a
display. Four sequential fresh private homes produced:

| Configuration | Adwaita early preference | Sombre early preference |
| --- | --- | --- |
| Packaged global legacy override | absent | absent |
| Same config, legacy override removed | NO | YES |

The JSON results are in `docs/proposals/theme-defaults-probe-results.json`.
The source guard deliberately respects explicit user choices above the
registration domain. The package places its legacy NO in that search list,
so the guard returns before installing either theme's preference. Backend
`initialize` then caches legacy NO; later theme activation is too late.

Propose the small `docs/proposals/csd-theme-defaults.patch`: remove the
legacy setting **only in explicit custom CSD staging**, where the reviewed
GUI hook exists. Keep GSTheme=Adwaita and key mappings. Preserve the managed
SDK path's legacy behavior. Do not change the hook to override user or
command-line choices. The approved patch is now applied to scripts/package-stage.sh in this isolated
branch and its exact source digest is bound in v017-review-inputs.json. No new
package has been built. The probe tested a private copy of its effect.

The first diagnostic attempt was invalid because group-writable config
copies were ignored and NSArgumentDomain already existed. Config mode0644
and removal/reinsertion of that volatile domain corrected the harness;
the next attempt passed all four cases. Raw logs remain in the review packet.

## Sombre: confirmed WM configuration failure, menu still inconclusive

Sombre's pinned Info dictionary requests `GSBackHandlesWindowDecorations=YES`.
The global legacy NO prevents the early hook from installing it, leaving
backend `handlesWindowDecorations=NO`. In `XGServerWindow.m`'s Motif-hint
routine, that path sets functions and decorations to zero. C's actual
Sombre property dump has `_MOTIF_WM_HINTS = 0x3,0x0,0x0,...`, and no WM close,
move or maximize actions. Super+Up did not maximize and Alt-F4 did not close.
These observations agree with the confirmed defaults-probe result; they are
not grounds for a Sombre source patch yet.

Adwaita's adapter independently writes allowed Motif functions, explaining
its observed 0x3e function mask and working maximize/close despite the same
cached backend choice. Removing the CSD-only global override should let
Sombre's YES establish the right backend mode before any window is created.
That prediction still needs a new exact-build GUI test.

The File menu evidence is weaker. C clicked hard-coded root coordinates on
Sombre's separate Macintosh-style menu, released, then captured. It did not
prove that the intended menu view received the event or capture mouse-down
tracking. `NSMenuView` tracks mouse-up and submenu state in its own event
loop. A screenshot without a dropdown cannot distinguish an input/placement
mistake from a menu bug. D separately demonstrated that short automated
clicks were insufficient for a control that worked with a full press/release.
Treat Sombre menu opening as **inconclusive**, not a proven theme defect.
Next slot must discover actual menu-window bounds, hold/capture press,
release, select one command, and verify its resulting window. No laptop GUI
was reopened for this source analysis.

## Choose a Cairo-only link-input trim

Recommend `docs/proposals/cairo-link-inputs.patch` for a separately reviewed
backend carry patch. It filters exactly `-lXft` and `-lXt` from GRAPHIC_LIBS
only when BUILD_SERVER=x11 and BUILD_GRAPHICS=cairo. It changes the generated
make-variable input, not the builder's prefix LDFLAGS, and needs no ignored
schema key or new builder API. Other graphics backends retain their inputs.
The approved backend patch is now the last of seven backend carry patches in
the combined proposed lock. Its digest and full16-patch SDK order are bound by
v017-review-inputs.json; the application defaults patch is bound separately.

The retained `config.make` contains both flags. Configure's Xt check adds Xt
to LIBS; Cairo's Xlib branch also appends XFT_LIBS, and config.make.in exports
LIBS as GRAPHIC_LIBS. That explains the observed direct dependencies. The
current Cairo backend has **no undefined symbol satisfied by either DSO**,
checked against all dynamic exports from the actual build image, not just
symbols whose names start with Xft/Xt. The static audit JSON records this.
Xft calls exist in the unselected xlib graphics implementation; the proposal
must remain conditional so that backend is unaffected.

Prefer this trim over reintroducing `--as-needed` for now. The inspected
builder has no per-component make-argument API; adding one changes builder
identity, validation and provenance. Global LDFLAGS replacement would discard
required prefix search paths, and broad as-needed also changes retention of
other DSOs. The narrow source patch adds a carried input, which is its cost;
it keeps the intended library decision explicit.

This is a static direct-symbol proof, **not** a claim that a future linked
closure already passed. Dynamic loading/initializers and transitive link
order cannot be qualified from that intersection alone. The next reviewed
build must print the real link command, show the two direct entries gone,
retain newly required libXfixes with a reviewed updated baseline, resolve
all transitive libraries, and pass package/GUI gates. No current ELF or SDK
was relinked. The dependency gate returns to hard failure; no local-review
waiver carries forward automatically.

## Combined input validation for the next slot

`packaging/linux/v017-review-inputs.json` binds the exact combined lock, all16
SDK patch entries in order, the separate applied application patch/source,
and the strict backend-needed policy. Run the `review-inputs` subcommand of
check-csd-package.py before building. The pinned builder also validates the
SDK lock independently. Custom input checks automatically revalidate this
manifest; both production package entry points explicitly bind it, preventing
the historical draft lock from bypassing the gate. They require PD_CSD_BACKEND_LINK_LOG plus exact backend DT_NEEDED.
The hard policy is the retained12-library set plus libXfixes.so.3, with no
Xft/Xt. It is not a transitive-resolution waiver.

Seven new static mutation tests cover order changes, changed patch bytes,
applied-source drift, a forced XFixes-negative cache answer extra/missing direct libraries refusal of a missing link-log binding and historical/foreign-lock bypass. They are included in Tests/run.sh. The existing nine CSD
input/stage tests and nine provenance tests also passed (25 total). No full
product regression or new binary build was run. The unrendered next-slot
receipt template explicitly marks every runtime result UNRUN.
