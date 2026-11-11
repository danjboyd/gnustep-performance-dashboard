# Proposed next local v0.1.7 qualification slot

No slot is booked by this document. The lead approved the proposal direction; require exact-head sign-off on the combined source
commit, lock hash, patch set and builder identity, then an explicit START and
hard cut. Do not reuse the November11 local-review waiver or artifact as a
corrected candidate. No push, tag, signing, publication or upstream send is
included. Stop/reap owned processes and report release inside every window.

## Review before booking

1. Review the XFixes proposal and the separate Cairo link-input patch. If
   accepted, make one exact combined lock with its new patch digest/order;
   the sibling proposed lock currently contains only the XFixes change.
   Keep libobjc2 unpatched and preserve the other source pins.
2. Review the CSD-only defaults patch, preserving managed-SDK behavior and
   explicit user/command-line preferences. Repeat the four headless probes
   in private homes if any hook/default bytes change. Config copies must be
   mode0644. Never create NSApplication or a display in that probe.
3. Require the exact direct DT_NEEDED set in v017-backend-needed.json: original
   retained12 entries plus libXfixes.so.3, without Xft/Xt. No other delta is
   permitted by the current review. Restore a HARD closure gate:
   any unexpected direct library, missing transitive library, or external
   library absent from the explicit exclusion policy stops promotion.
4. Prepare immutable Debian13 image identity with explicit libxrender-dev and
   libxfixes-dev, full package inventory, and two-job limit. Verify every
   builder file, source/patch hash and fresh prefix; no installed SDK or theme
   can substitute. Confirm the combined candidate and working tree are exact.

## SDK, theme, app and package window

- Configure must detect XFixes and define HAVE_XFIXES=1. Keep the actual
  configure summary and full commands, with all other disabled features
  visible. A positive configure answer alone is insufficient.
- Export PD_CSD_BACKEND_LINK_LOG to the actual backend build log before any
  custom package input check. The checker refuses it if missing and enforces
  the exact direct-library set. Retain an expanded executed backend link command (GNUstep messages=yes or
  equivalent reviewed verbosity); the previous quiet make log was insufficient.
  Check DT_NEEDED against the reviewed baseline and resolve the entire closure.
- Build pinned Adwaita with the same SDK and its real receipt; build the pinned
  Sombre test theme in that SDK. Respect two total compiler jobs. Build the
  xctest runner serially because its host library raced XCTest under -j2.
- Build/test integrated app/framework/CLI/helper. Require unit count, suite exit
  status and final check line; keep GUI-skipped headless evidence separate.
- Assemble the unsigned artifact with complete custom CSD provenance. Do not use
  --release. Require source/payload SHA and build-ID ties, both launch helpers,
  CSD keys/export, smoke and recording checks.
- Audit every external ldd entry against the project's AppImage exclusion
  policy: packager strict mode with an empty allowlist can merely observe host
  libraries. Keep this independent comparison and no-unresolved assertion.
- If a gate fails, stop and label the result honestly. AppDir fallback requires
  an actual exact-input AppDir/AppRun; a raw stage is not that artifact.

## Private compositor/window window

Use a new owned display number, never :0/:120, with a private passwd home,
GNUSTEP_USER_ROOT, runtime directory and D-Bus. Configure welcome-dialog state
only inside that profile before starting its own GNOME Shell --x11. Prevent
welcome/overview overlays from invalidating captures. Preserve all foreign
sessions. Capture root _NET_SUPPORTED and require _GTK_FRAME_EXTENTS.

For each theme, discover actual named client and menu windows; GNUstep may not
provide _NET_WM_PID. Verify loaded app/backend/GUI/Base/theme identities.
Capture a normal resized, unmaximized window with clear desktop margins,
properties, depth/ARGB visual, compositor selection owner and WM actions.
Adwaita should have its requested CSD margins/radius and client extents.
Sombre requests backend/WM decorations, so judge its expected WM-decorated
behavior separately; do not require an Adwaita CSD property on Sombre.

Verify move/resize, maximize AND restore via actual EWMH transitions, close and
Alt-F4, first-click/focus, menu/popover opening and one invoked command. For
Sombre's separate Macintosh-style menubar, discover actual window bounds,
press/hold and capture while tracking, release, then invoke a known command.
Do not infer a menu defect from a hard-coded click and a post-release image.
Keep raw failed attempts; no hidden coordinate retry counts as a pass.

Stop new cases with cleanup time remaining. Stop only owned PID/start identities,
then scan the exact private-home marker for detached services. Verify owned X
sockets gone and report explicit release to project and tools leads.

## Packaged lifecycle and strict TLS window

Use unique fixture basenames for every attempt; retained global temp traces
must never satisfy a new run's completion predicate. Parse GNUstep typed plist
integers. Run actual packaged GUI natural0/nonzero, SIGSEGV/SIGTERM, requested
stop and escalation. Check process status separately from capture completion:
SIGSEGV can correctly have known signal status and incomplete trace data.
Verify NSTask source, unknown core bit and actual independent target SID.
Cover fresh and retained homes. Deliberately overlap an unrelated NSTask and
active Foundation runloop in a reviewed diagnostic; unit evidence alone does
not replace this packaged case. Keep the CLI's waitpid/core-known path separate.

Select an actual frame, hold/release source-line control, visually verify both
states and observe a debug-bearing fixture's source result. Save through the
GUI panel using explicit field selection (Ctrl+A previously inserted SOH),
confirm a normal filename, compare persisted exit/source/core/session/capture
metadata, then reopen those exact saved bytes in a fresh home and verify its
named window plus actual executable/maps. Snapshot before bounded cleanup.

Repeat six strict TLS controls without applying an update: real feed with OS
trust; fixture and real feed in one combined-store process; same fixture leaf
refused by default OS trust; unrelated issuer; wrong DNS SAN; wrong IP SAN.
Both verification env vars and TLS user defaults must remain absent. Fixture
CA is a per-process private copy only. Confirm exact packaged Base/AppRun and
adapter/core identities. Review issuer/hostname diagnostics and server events;
arbitrary failure is not TLS proof. Close all owned listeners/threads.

## Final review packet

Include exact source/lock/builder/image/package identities, executed commands,
all pass/fail/unrun cases, screenshots visually reviewed in both themes,
loaded maps/properties, raw and decoded status, saved-trace tie-out, TLS proof,
UTC/load snapshots, PID/start identities and final empty-owned-process/socket
audit. A source prediction is not a runtime pass. No release acceptance is
established until the lead reviews this exact corrected-build packet.

## Receipt identities to render after sign-off

Copy docs/proposals/v017-next-slot-receipt.template.json and fill only the
reviewed candidate commit before execution. Verify its lock/manifest/order
identities against source; leave runtime results UNRUN until supported by
actual evidence. Rendered source must remain unchanged through qualification.
No previous local-review dependency waiver applies.
