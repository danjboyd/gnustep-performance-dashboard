# v0.1.7 qualification runbook template

Render this template after the final local candidate commit, replacing the two
identity placeholders below. Use the rendered copy in the private review packet;
this source file cannot contain its own future commit hash. Do not execute a
copy that still has placeholders or differs from the lead-reviewed candidate.

Candidate: `{{CANDIDATE_HEAD}}`
Main baseline: `ff0ad3578ce4853794a8500f0c1bd7d6ec1ecf03`
Main-to-candidate diff SHA-256: `{{CANDIDATE_MAIN_DIFF_SHA256}}`
Lock SHA-256: `ef07d0a12412db63e8225ade46c99163bfce48ca9f06054a3bb1ae5204476848`
Builder: public gnustep-cli-new `4d5504bbedf076f824c952f4ab198d09547c8c3c`
Theme: `b74231f84bc139a50ad50459acfaed10a07a4642`

The lead approved these local inputs, the inventory-attested Debian13 recipe
plus libxrender-dev, deliberate first-review omission of backend --as-needed,
CSD unsigned-review provenance and theme receipt recipe. Nothing starts merely
because the clock reaches a window: require the lead's explicit START mail on
2026-11-11 at15:00Z. No push, tag, release, feed or upstream action is included.
Other approved work may overlap; record load and make no timing claims.

## Before START

Verify the candidate worktree is clean at the exact hash above. Verify the lock,
all15 patch hashes/order, inspected builder file digests and theme pin. No source
edit, moving branch head, old SDK cache or installed host binary substitution is
allowed. A changed input returns to lead review and gets a new rendered runbook.
Have the accepted managed-SDK DT_NEEDED baseline ready for the closure comparison.
Allocate only owned output/prefix/home/display identities and log UTC times.

## A+B:15:00–16:00Z, cleanup included

A budget:15:00–15:45Z. At most two compile jobs.

1. Record resolved base/final container image IDs/digests and complete package
   versions before compiling. Classify inventory-attested, not reproducible.
   Use the exact LOCAL lock and a fresh dedicated custom prefix, never a managed
   install. Require schema/patch checks before source fetch or cache use.
2. Build the seven SDK components with the inspected builder. Preserve configure,
   compile and linker logs plus official=false provenance and resolved sources/
   applied patch identities. Any failure stops promotion; no guessed flags.
3. Compare backend linker commands and DT_NEEDED closure against the accepted
   baseline. Identify reviewed feature dependencies explicitly, including any
   intended XRender addition; unreviewed/unbundled dependencies stop the phase.
4. Build the pinned theme in a fresh owned tree using only the custom SDK shell,
   make-j2 and the reviewed prefix maps. Generate the actual theme receipt and
   retain its log/source status. The old helper's nproc invocation is not allowed.

If A cannot complete by15:45Z, stop and report; do not compress B or overrun.

B budget:15:45–15:55Z;15:55–16:00Z is cleanup/reporting.

5. Verify the integrated source head again. Build/test the app/framework/CLI/helper
   with this same SDK, including unit/headless and the six CLI exit cases. Keep
   this result separate from the earlier managed-toolchain headless baseline.
6. Bind the exact SDK backend and freshly built theme, their SHA values and theme
   receipt through PD_CSD_TOOLCHAIN_LOCK/LIBS_BACK_BUNDLE/ADWAITA_THEME and the
   documented PD_CSD_* identity variables. The selected custom path must reject
   missing inputs and the legacy backend fallback.
7. Assemble an unsigned CSD review AppImage through the accepted custom-aware
   provenance path. Do not use --release. Require final CSD key/export assertions,
   package helper paths and the custom lock/SDK/theme/patch identity record.
   Compare selected source/payload ELF identities, final hashes and loaded maps.
8. Preserve the exact artifact hash and evidence. If a gate fails, stop and report.
   Use the lead's AppDir-only fallback only with an actual staged AppDir/AppRun
   from these exact inputs; label it AppDir, not AppImage, and defer AppImage
   qualification. A raw stage directory or older AppImage is not that fallback.
9. Stop/reap owned targets/processes and audit actual host state before16:00Z;
   preserve every foreign process/session. Explicitly report A+B release to the
   lead and waiting machine owners, including failures and unrun work.

## C:16:00–16:10Z, cleanup included

Use the exact artifact accepted from B. Start a new owned Xvfb display with its
own gnome-shell --x11 (or reviewed mutter --x11) and private D-Bus session. Never
reuse the shared desktop or another application's display/session. Verify root
_NET_SUPPORTED advertises _GTK_FRAME_EXTENTS as requested and capture actual
client extents, ARGB/cairo/theme defaults and loaded binary identities. If the
capability gate fails, report it; bare Xvfb is not positive corners evidence.

Capture normal windowed Adwaita and Sombre, corners/shadows, menus/popovers,
first-click/focus, close/Alt-F4, move/resize and maximized/restored behavior.
Keep screenshots and property dumps. Stop new cases at16:08Z; finish owned
compositor/WM/display/D-Bus cleanup and actual-host audit by16:10Z. Report release.

## D:16:10–16:20Z, cleanup included

Use the same artifact in fresh and retained private homes. Cover GUI natural
exit/nonzero/signal, requested stop and forced kill, an unrelated task/runloop,
source-line lookup off/on, save/reopen and persisted status/capture validity.
Confirm independent GUI target session and explicit unavailable core-bit metadata;
CLI raw status remains separate. Audit app/target/helper identities and stdio/
writer channel behavior; a complete trace is not proof of known process status.

Run strict packaged TLS controls without applying an update: OS-root real-feed
positive; OS+fixture-root both positive in one process; unrelated issuer and
wrong DNS/IP SAN negatives. No trust-store edits or verification-off toggles.
Stop new cases at16:18Z and finish owned cleanup/audit/release by16:20Z. If the
finite matrix does not fit, report the unrun cases and request a later window.

## Final packet

Record exact source/lock/builder/container/dependency identities, artifact and
final ELF hashes/build IDs, real logs/screenshots, target/display/server PIDs
plus start identity, load and UTC start/end, passed/failed/unrun cases and owned
cleanup. Preserve initial command or harness mistakes with corrected evidence.
No result from a different SDK, source head or AppDir qualifies this artifact.
