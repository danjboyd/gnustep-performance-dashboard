# Diagnostic trace-load benchmark

Run the unchanged recorder and app from a Linux Performance Dashboard
AppImage against an existing, finished real recording:

```sh
python3 scripts/benchmark-trace-load.py /path/to/PerformanceDashboard.AppImage \
  /path/to/workload.gstrace /tmp/pd-load-results --runs 3
```

To keep the recorder fixed while comparing app builds, add
`--recorder-appimage /path/to/frozen-recorder.AppImage`. The runner extracts
that package separately and retains both package identities, the actual
recorder/framework/agent hashes and the target API-library hash when present.
The recorded target uses its own packaged libraries.

The output directory must be unused, under `/tmp` or this checkout, and outside
the input trace. Other home paths are hidden by isolation. Dependencies
are Python 3, `bwrap`, Xvfb, xdotool and ImageMagick's `import` and `identify`. Keep the repository's
small sample trace available. The invocation allocates a private 1280×900 Xvfb
display and private temporary directory. It reexecutes under the shared
`scripts/with-private-home.py` helper, binding a retained `OUTPUT-sandbox/home`
over the passwd home and isolating the user runtime directory. Each run uses separate preferences
and the packaged Adwaita theme, with automatic updater checks disabled. No
user display or session bus is used. This also isolates packaged CLI wrappers
that override `GNUSTEP_CONFIG_FILE`; setting `HOME` alone does not.
With `GITHUB_ACTIONS=true` or `CI=true` and a passwd home other than
`/home/danboyd`, the helper logs that it uses the existing ephemeral runner
home and runs directly. The receipt labels that mode; it does not claim a
bind-mounted home. The development home always requires `bwrap`, even with
CI markers set, and missing namespace support never silently falls back there.
The existing `PDOpenTrace` launch option
opens the small startup sample after menus are built, so its addition to
recent files cannot change which submenu entry selects the measured input.
The tool assumes the standard
Performance Dashboard File → Open Recent menu arrangement, confirms a new
trace window and waits for the main thread to return to kernel poll before
stopping. It requires Linux `/proc` access; an incompatible UI or wait-state
layout fails with a timeout rather than inventing a measurement.

`receipt.json` records SHA256 and sizes for the AppImage, actual app/recorder/
framework/agent and every input file; per-run signpost summaries, hang count, longest hang in
seconds, CPU/wall sample counts and dropped samples; and a final unchanged-hash
check. Raw captures, recorder commands/logs, JSON exports and loaded-window
screenshots, loaded-library maps and individual signpost CSV intervals remain
in the output. Failed runtime attempts retain an error
receipt. CPU sample counts use the recorder's weighted definition. Counts
cover the full capture, including startup and menu dispatch, rather than an
instrumented load interval. A zero hang count is a valid diagnostic outcome.

Hashing warms the input cache. These are profiled, sequential runs on the
current host; they are not an unprofiled latency measurement, a statistically
controlled performance comparison or release acceptance. The runner injects
no target delays, does not change the input, and creates no tags or packages.
