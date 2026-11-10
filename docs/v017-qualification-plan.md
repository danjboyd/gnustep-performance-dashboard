# v0.1.7 qualification plan (local review draft)

This is a plan, not a build or runtime result. The current release candidate
remains frozen at `3a115fbd475387d29814c590f54dd7146f196e55`. No v0.1.7 SDK,
AppImage, hosted run, tag or release is qualified by the work listed below.

## Review inputs before execution

The source-only CSD branch has strict-application receipts for the five public
v7 backports. Its custom-lock/build design is commit
`8a938a380dfc99cb550aa7526cc49df83f9bb3a3`. The independent recorder fix is
`1dffe8663e328b023d280b030a002c65906efac0`, based directly on the frozen release,
with review follow-up `c23c087d08d0037e9f8d8e29c021de3e567a306c`.
Neither branch is an approved shipping input. Review both and define a new
combined local candidate before calling any package a v0.1.7 candidate.

The custom lock pins seven components, including Base d898f70 plus its eight
TLS patches, unpatched libobjc2 b67709a, GUI 7892137 plus one CSD backport and
backend bf3b3ced plus two existing PD patches and four CSD backports. Keep the
explicit backend order 0003, 0004a, 0004, 0005. No private fork or installed
host binary substitutes for these inputs. Preserve exact patch SHA identities.

Before a build, review the corrected LOCAL-domain relocation path, retained
backend feature exclusions, unsupported per-component `--as-needed` make
argument, public builder commit and container/action/dependency identities.
The fixture-only Custom Toolchain workflow does not consume this PD lock.
No hosted workflow dispatch is part of this plan.

## Evidence matrix

| Area | Required evidence and acceptance | Existing evidence | New custom candidate |
| --- | --- | --- | --- |
| Source inputs | Exact commits, patch hashes/order, preserved authors/ChangeLogs; strict apply without three-way fallback | CSD exports strictly apply to retained PD pins | Recheck final combined tree and lock |
| Lock/build recipe | Validate schema and every local patch; record all feature/configure choices and resolve review items above | Draft schema/digests pass inspected validator | Review gates open; SDK build unrun |
| SDK build | Fresh prefix, no managed install replacement; all components built from the lock; official=false provenance, actual commits/applied hashes/compiler/container identity | No custom SDK build | Unrun |
| SDK payload | Match provenance to staged ELF SHA/build IDs and loaded maps; inspect dependencies, backend bundle, resource/config discovery and relocation | Earlier SDK payloads are a baseline only | Unrun |
| API/ABI | Build all dependants with the same SDK; exercise Foundation/AppKit selectors, archives and basic rendering | Retained GUI pin avoids alignment renumbering boundary 3237efda | Build/runtime compatibility unqualified |
| Recorder ownership | Registered task retains normal/signal status when Foundation reaps first and another task completes; no raw waiter competes; startup errors are launch failures | Recorder branch: 47 unit methods pass on existing native runtime, including a real headless recorder/agent completion | Rerun against new SDK and staged payload |
| CLI compatibility | Direct posix_spawn default unchanged; exits 0, 3, 139, 143, requested orderly stop 0, escalation 137; raw core-bit storage and terminal/session behavior retained | Six CLI cases pass; direct method byte-identical except selector; core-bit API/metadata unit passes | Rerun with final packaged CLI |
| Agent and thresholds | Valid END/receipt/epoch/bytes/done tie-out; EFBIG and deterministic ENOSPC/finalization errors remain incomplete; minimum-free/max-size crossings stop gracefully, not hard quota | Earlier qualified capture tests and current headless regression baseline | Rerun bounded cases, no disk filling |
| Environment/FDs | Caller GNUstep config set/unset/empty and explicit override; argv/cwd/preload; intended stdio/status only; no leaked descriptors | Nine bounded helper child-process cases pass, including FD300 closure, malformed/partial rights and ignored-signal restoration | Verify actual AppRun and CLI, both helper paths, stable agent copy and target maps |
| Package assembly | Full same-SDK unsigned review package; required gsp-launch in app Resources and runtime/lib; executable modes, source/provenance/licenses; no stale overlay described as full build | Required-path wiring and script syntax checked; no new package assembled | Unrun |
| TLS/update checks | Actual packaged updater: OS-root real feed positive; OS+fixture-root both positives in one process; untrusted issuer and wrong DNS/IP SAN negatives | v0.1.6 earlier payload tests are historical | Rerun on final package, no apply/deploy |
| CSD positive visuals | Compositor-capable owned X11 session; loaded Cairo/X11/ARGB stack, theme defaults, actual GTK frame extents; visible round corners/shadows on normal windows | Bare Xvfb and older unpatched backend cannot prove corners | Unrun |
| Themes/interactions | Adwaita and Sombre; close/Alt-F4, move/resize, first click/focus, menus/popovers/dialogs/tooltips, maximized/restored states | CSD public patch test claims are historical only | Unrun |
| GUI recording outcomes | Natural exit/nonzero/signal, requested stop and forced kill; fresh and retained homes with active NSTask; source-line lookup off/on; save/reopen retains outcome | Headless ownership checks pass; no AppKit runtime for this branch | Unrun; inspect screenshots/status and recorded metadata |
| Cleanup | Owned identities gone, all children reaped, startup channel closed, owned display/WM/compositor/servers down; actual-host audit; foreign processes preserved | Current headless processes completed | Required for every future slot |

Windows and arm64 stay separate workstreams. No result from this x86_64 Linux
matrix qualifies either platform. A source-level Foundation header check also
does not prove runtime semantics or an ABI-compatible custom SDK.

## Proposed shared-machine windows

These are requests to schedule after review, not reservations. The lead plans
A+B, C and D for 2026-11-11, with separate start-now messages. Today remains
source-only. See `v017-window-a-input-review.md` for concrete unresolved input
checks, including the reviewed LOCAL correction of the earlier SYSTEM mismatch,
explicit backend/theme binding and the static CSD capability assertion. The lead must
announce each start after the previous owner releases the machine. A refusal
or failed gate stops that phase; retain logs and do not silently change inputs.
No competing recorder, application build or timing study may overlap a window.

| Window | Proposed cap | Work and prerequisites | End condition |
| --- | --- | --- | --- |
| A: custom SDK | Initial budget 45 minutes, at most 2 build jobs | Exact reviewed lock, builder/container pins and fresh private prefix; capture configure/build/provenance logs; no GUI or performance study | Report completed components or failed gate; do not overrun without lead rescheduling |
| B: headless/package | 15 minutes including cleanup | New SDK accepted; combined source reviewed; unit/regression, bounded capture/config tests, full unsigned AppImage assembly and payload/hash tie-out | Package and receipts or first failing gate; owned recording targets gone |
| C: compositor visuals | 10 minutes including cleanup | Final payload from B; new owned Xvfb plus gnome-shell --x11 or mutter --x11 in private D-Bus; inspect _NET_SUPPORTED for _GTK_FRAME_EXTENTS and actual client properties before windowed-theme screenshots | Adwaita/Sombre matrix evidence or explicit unsupported visual gate; owned display stack gone |
| D: GUI lifecycle/TLS | 10 minutes including cleanup | Exact same payload; fresh and retained private homes; finite target outcome list and strict TLS controls | Saved/reopened outcomes and TLS results; all owned processes/listeners gone |

If a phase cannot fit the cap, split its finite case list and ask the lead for
a new window before continuing. A toolchain build duration is unknown; 45
minutes is a scheduling budget, not a promised completion or measured speed.
Keep performance/timing experiments out of these correctness windows.

Each window needs an identity ledger: reviewed source/lock and actual executable
hashes, parent/child PIDs plus process start identity, target session/group,
display ownership, homes and temporary paths, listener identities, start/end
UTC times and cleanup result. Account for NSTask's independent GUI target
session when cleaning up; never infer ownership from an arbitrary process
name or signal a broad process list. Preserve the shared desktop and foreign
recordings. Audit actual host state, not only a sandbox's process view, then
send an explicit release to the lead and other waiting machine owners.

## Promotion boundary

A failed matrix row leaves that scope unqualified; do not generalize another
SDK's or another source version's result. Archive exact logs and screenshots,
including initial command/test-harness mistakes and corrected runs. Report
which checks ran and which did not. Any future push, hosted dispatch, tag,
publish, feed deployment or upstream send needs its own applicable authority;
this local plan grants none of those actions.
