# Draft OpenTrace target

This development target lives on `draft/open-trace-signpost-target`, based on
the frozen v0.1.2 source `7ddc66368a17d273100f1ffc63662787fd094876`. It is
separate from both qualified recorder candidates and their packages. It is
not release acceptance evidence. The client layout follow-up is also separate.

The app emits a uniquely identified `OpenTrace` interval for the synchronous
`initWithTracePath:error:` operation, using the public signpost API. Its log
subsystem is `org.gnustep.PerformanceDashboard.OpenTraceDraft` and its category
is Points of Interest. `@finally` closes the interval on success, a returned
error or an exception. Alerts, file selection, showing the window and user
waits occur outside the interval. The payload does not contain trace paths.
No artificial delay is introduced.

Build from a shell with GNUstep.sh sourced using `make`. The app now links the
signpost API library. The Linux build-tree run path includes `Runtime/obj`;
the existing packaged runtime path remains available. Windows builds copy
`gsperf.dll` beside the app executable; native Windows validation is pending.
Do not substitute this target for a qualified recorder or rebuild a frozen
package with it. Identify any future target by source commit and executable
sha256, together with its loaded API library identity.

Until Dan selects this route, validation is limited to building and normal
unrecorded operation. A later approved recording would use the unchanged
frozen recorder, open real traces through the UI and check completed intervals
and their stacks. One instrumented app cannot establish a two-application
gate, and an interval does not establish a natural 250 ms main-thread hang.
