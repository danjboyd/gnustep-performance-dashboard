# OpenTrace signposts

Dan selected this feature for v0.1.3. Its integration lives on
`next/v0.1.3`, after the layout and packaging-input changes. The original
draft remains on `draft/open-trace-signpost-target`. Neither branch changes
the frozen v0.1.1/v0.1.2 sources or qualified packages.

On v0.1.4 development the app emits a uniquely identified `OpenTrace`
interval across asynchronous loading: reader parsing/indexing, initial
analyses, then installation of the completed model on the main thread. Its
log subsystem is `org.gnustep.PerformanceDashboard` and its category is
Points of Interest. The progress window is shown immediately, while a worker
owns the unpublished trace/renderer. Only the completed model is transferred
to AppKit. Closing while loading discards that result; it does not interrupt
the parser mid-record. Completion closes the interval before an error alert.
The end payload is `success`, `error` or `cancelled`, without trace paths.
Cancelling file selection emits no interval. No artificial delay is added.

This boundary differs from v0.1.3, whose interval covered synchronous reader
and window construction before showing the window. Compare the main-loop
hang evidence separately from the interval duration; asynchronous work can
keep an interval open without freezing the UI. The interval excludes file
selection and user waits. First drawing after model installation is separate.

Build from a shell with GNUstep.sh sourced using `make`. The default build
links the signpost API library; its calls are no-ops while unrecorded.
For a build without this dependency, clean the Dashboard build and use
`make PD_ENABLE_SIGNPOSTS=0`. Clean again when changing the option back.
The Linux build-tree run path includes `Runtime/obj`; Linux packaging resolves
and stages the API from that directory. Windows builds copy `gsperf.dll`
beside the app executable, and packaging stages it in `runtime/bin` with
explicit project ownership. Native Windows deployment validation is pending.
Do not substitute this target for a qualified recorder or rebuild a frozen
package with it. Identify any future target by source commit and executable
sha256, together with its loaded API library identity.

`Tests/open-trace-gui-checks.sh` runs the actual delegate against the sample
reader and a missing trace. An observer at the public API boundary checks
paired IDs, outcome payloads, closure before alerts, no emissions on chooser
cancellation, closure during exception unwinding, main-loop heartbeat during a gated
background read, and safe closure during loading, under Adwaita and Sombre. The full Linux gate includes these checks. Recorded real trace opens
must additionally check completed intervals and their relation to hang
evidence. One instrumented app cannot establish a two-application gate, and
an interval alone does not establish a natural 250 ms main-thread hang.
