# ScreenshotTool: defer hidden recent-image thumbnails

Draft for Dan's review; **not sent**. Target source:
`4b65100875716c32b0c1b314fc7326874eb7ab68`. Local prototype:
`aa5b52abbbee5af693b9c14e73ec32bfef5b336b` (two files, 40 additions,
one deletion). No upstream sign-off is recorded or implied.

Opening an image updates Recent files, including cards in the hidden empty
state. A delayed thumbnail callback checks whether the card has a window,
but hidden cards still have one. Saving the image can schedule more of that
invisible work.

I reproduced this with Performance Dashboard v0.1.3 source `ea576ea`, using
ScreenshotTool's synthetic settings image on a private Xvfb display. The
workload captures a 1920 x 1080 image, opens it, draws a highlight and arrow,
and exports a PNG, with fresh private defaults. Both Adwaita and Sombre
completed the workflow with clean recordings and zero dropped samples.

The CPU-only call tree attributed **289 ms (10.6% of 2.731 s sampled CPU)**
to the delayed `loadEmptyStateThumbnailForCard:path:key:` callback. Another
52 ms was under `refreshEmptyStateRecents` on the image-open path. Combined
CPU/allocation/leak runs corroborated the thumbnail path; their totals are
not app-only CPU or a baseline for a speedup claim.

The prototype changes `Source/AppDelegate.m` to defer recent-card refresh
while the canvas has an image, mark cards stale for the next empty state,
and skip queued loads when a card or ancestor has become hidden. It adds
two focused tests in `Tests/LaunchCostProbe_test.m`: no hidden thumbnail
requests, and thumbnails returning when the last image closes.

The hidden-recents test fails on the original implementation (one failure
among seven launch-cost tests). After the change, seven launch-cost and
four empty-state tests pass under **each** of Adwaita and Sombre. On the
identical CPU-only workload, the callback had no sampled work and total
sampled CPU was 2.508 s. The 223 ms reduction is one before/after pair, not
a general performance claim. Input and exported PNG bytes were identical;
export SHA256 is
`fb08caf27abf94f7e4131809e98498cae64e86af1c2e696c945097f33ad0fb7f`.

Review the exact diff in our isolated clone:

```sh
git -C out/linux-development-20261029/screenshottool-dogfood show aa5b52a
```

Retained evidence is `out/linux-development-20261029/`: `thumbnail-tests-before2.log`,
`thumbnail-tests-after.log`, `thumbnail-tests-after-Sombre.log`, and
`dogfood/{Adwaita-cpu-baseline,Adwaita-cpu-prototype,cpu-comparison.json}`.
The prototype's `provenance.json` is its authoritative source/binary receipt;
the shared driver's result source literal still names the original source.

The main remaining checks are repeated runs, other image/project sizes,
macOS/Windows behavior, and an explicit check of a queued thumbnail becoming
hidden before its callback executes. The existing tests cover scheduling
suppression and the return to visible recent cards. No application-wide leak
fix or elapsed UI-latency improvement is claimed.

Investigated, reproduced and written up with AI assistance (Codex, OpenAI).
Dan must review the exact diff and this draft under `docs/upstream-policy.md`
before any submission; preparing this draft authorizes no send.
