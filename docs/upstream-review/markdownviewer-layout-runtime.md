# Markdown Viewer layout: host runtime guard and published-package scope

Prepared locally for review on 2026-10-29; not sent. This is not a new
upstream proposal. The original 31-second glyph-check finding applies to
the host GNUstep runtime used by our local source build, while published
Markdown Viewer already carries a targeted fix.

## Exact inputs and the existing fix

The local unchanged MV source is
`8178c1e5009a2673d14feb5ae7049cb0ccc31434`, executable SHA-256
`745433d92c6cfdce567febfbd2d8e4321009f8fedac415d028b004a1bb139757`.
Its host GUI library SHA-256 is
`0947aa7e261dbdc7fc4f1bcb589f96e74786dc9d06831c883a5d45df7ff5bc5f`.
The original Adwaita capture attributed 31.022 seconds of self CPU to
`GSLayoutManager _sanityChecks`; this is not a measurement of a shipped MV
AppImage.

[Upstream GSLayoutManager.m at the packaged source revision](https://github.com/gnustep/libs-gui/blob/549f639137a600936acde4cd618f0e4b858d883d/Source/GSLayoutManager.m#L319)
walks the entire glyph-run chain and checks the links. Calls at lines 625,
1220 and 1570 are unconditional in that unpatched source. Repeating a full
walk during incremental glyph work explains the observed hot path; it does
not by itself establish the time complexity of every document. The host
library retains the corresponding assertion string.

MV's [existing package patch](https://github.com/danjboyd/ObjcMarkdown/blob/4744c73bec8bc58d1e3562588be9144b98422ebb/packaging/patches/libs-gui/0001-GSLayoutManager-compile-out-the-glyph-run-sanity-che.patch#L25)
guards the method body with **`GSLAYOUTMANAGER_SANITY_CHECKS`**, so the walk
only exists when that explicit diagnostic macro is defined. This is separate
from global `NS_BLOCK_ASSERTIONS`. The [patch ledger](https://github.com/danjboyd/ObjcMarkdown/blob/4744c73bec8bc58d1e3562588be9144b98422ebb/packaging/patches/README.md)
already records MV #94 and GNUstep libs-gui #992; it says the patch itself has
not been sent. No duplicate issue or patch should be proposed from this work.

The [v0.2.5 build recipe](https://github.com/danjboyd/ObjcMarkdown/blob/4744c73bec8bc58d1e3562588be9144b98422ebb/ci/linux/Dockerfile#L88)
applies `packaging/patches/libs-gui/*.patch` before configuring. Its exact
GUI configure arguments are `--enable-png --enable-jpeg --enable-libgif
--enable-icu --disable-cups --disable-sound --disable-movie
--disable-imagemagick --disable-aspell --disable-speech
--disable-speech-recognizer`, followed by
`make -j"$(nproc)" GNUSTEP_INSTALLATION_DOMAIN=SYSTEM`. It does not pass either
of the two assertion/check macros above. The matching debug unit identifies
Debian clang 19.1.7; its DWARF producer does not retain the complete compiler
invocation. The original host-library invocation is also unavailable. Current
host `gnustep-config --objc-flags` reports `-g -O2` and no
`NS_BLOCK_ASSERTIONS`; that is current-tool evidence, not retrospective proof
of every flag used to build the installed library.

## Method-only isolated experiment on the host runtime

A local C preload diagnostic replaces only `_sanityChecks` with a no-op.
Control and disabled runs load the same probe, retain the same app and library
bytes, open the same 460,726-byte/400-section document, scroll, edit and verify
Save, then enter Split and scroll. Both saved files have identical SHA-256
`7d8a1bf5f0228c2012c7dc52fa05a4d9f02645bc8979119282bf638689be5daa`.
The probe is an experiment, not a production patch or a recommendation to
disable unrelated assertions. No host library was changed.

Exact diagnostic build flags: `clang -O2 -fPIC -shared
-I/usr/GNUstep/System/Library/Headers -L/usr/GNUstep/System/Library/Libraries
-lobjc`, with the source/output paths retained in the receipt. The control
keeps the original implementation; the disabled case is selected by
`PD_DIAG_SKIP_LAYOUT_SANITY=1`. The recorder places its libc-only agent before
the probe in LD_PRELOAD. Its log confirms the target method replacement.

| One sequential CPU-only pair | Control | Check disabled |
| --- | ---: | ---: |
| Sampled CPU | 63.694 s | 49.533 s |
| `_sanityChecks` self CPU | 11.394 s | absent |
| Largest opening stall | 11.460 s | 5.130 s |
| Editing-phase stall | 11.250 s | 11.720 s |
| Split-phase stall | 28.190 s | 26.450 s |

The check contributes measured host-runtime cost, while editing and split
still have substantial stalls. Operation timestamps bracket the phases; CPU
samples and wall stalls are different quantities. These are warmed-cache,
profiled runs on a loaded host, not a general speedup claim. A missing-probe
control attempt was retained and excluded. Evidence is
`out/layout-sanity-probe/comparison.json` and
`out/markdown-layout-{control,disabled}/Adwaita/`.

## Read-only inspection of published v0.2.5

The public [v0.2.5 AppImage release](https://github.com/danjboyd/ObjcMarkdown/releases/tag/v0.2.5)
provided `ObjcMarkdown-0.2.5-linux-x86_64.AppImage`, 68,336,120 bytes, SHA-256
`aca281062bec06406092933bb85dec5860d1b48b517000ea147b352feb394cdc`.
It was downloaded into our scratch directory and checked against its public
release digest and metadata. The bundled GUI SHA-256 is
`fa959ac39942d6cdace92186d02675198b8a7c142837254641a8fe116f95a5df`;
build ID `c115541dcea2caebb34b78a8e25c2a739cbaebc2`. The release's matching
debug bundle identifies `_i_GSLayoutManager_GlyphsHelpers__sanityChecks` at
ELF offset `0x49c110`, size **one byte**. Raw disassembly is `c3` / `ret`.
The glyph-chain assertion string is absent. Another NSAssert message from
the same source unit remains, so the targeted check was removed without
preprocessing away every assertion in that unit. This confirms the dedicated
guard rather than a global assertion-disable explanation.

The affected input for the original finding is therefore the **unpatched
host `/usr/GNUstep` build**. MV's packaging already owns and carries its
workaround; GNUstep libs-gui is the implementation owner. Aligning a host
runtime to that fix is separate work and is not performed here. The published
package must be measured independently for any remaining MV finding.

Scratch identities, debug-unit evidence, source references and disassembly:
`out/mv-published/`. No system installation or running owner instance was
changed.

## Published-package workflow: remaining multi-second stalls

The extracted v0.2.5 native executable has SHA-256
`cfdde5811fcaf64f7b84917ea1a3f7108a5278cea478e6ac29706aab8eb5f665`.
Its actual `/proc` maps confirm the bundled GNUstep base/gui, libobjc, backend
and Adwaita theme, with no host GNUstep libraries. It ran on a private display
and passwd home. A mode-0600 relocated GNUstep config reproduces its launcher
paths. The private extracted updater metadata postpones its startup timer to
86,400 seconds; no binary or library was modified. The unchanged AppImage
and original metadata remain retained.

On the same 460,726-byte generated input, the logical sequence was Read/open,
scroll, Edit, insert/save a verified marker, then Split and scroll. The release's
toolbar layout requires different coordinates. The saved edit occurs at a
different caret location from the host run, so this is an independent shipped
workload observation, not a byte-identical host/package speed comparison.
The saved file SHA-256 is
`707894108dda281278935d6b6779e19c48a6a3b5a04b71d975a2488cef04880f`.
Recording used Time Profiler with its Hangs/Points of Interest tracks and no
allocation or leak instrumentation. It finished cleanly, with zero dropped
samples, no quality warnings and **14.313 sampled CPU seconds**. The final
Split screenshot was inspected and has no updater dialog.

| Observed stall | Duration | Representative sampled path |
| --- | ---: | --- |
| Opening | 2.170 s and 3.650 s | `renderCurrentMarkdown → OMDApplyRenderedString → replaceCharactersInRange:withAttributedString: → GSTextStorage setAttributes:range: → cacheAttributes → GSMutableDictionary isEqualToDictionary:` |
| Edit/highlighting | 1.030 s | `sourceSyntaxHighlightTimerFired → applySourceSyntaxHighlightingNow → OMDSourceHighlighter highlightAttributedString → omdApplyRegex → addAttribute:value:range: → cacheAttributes → dictionary equality` |
| Entering Split | 5.730 s | `setViewerMode:persistPreference: → renderCurrentMarkdown → OMDApplyRenderedString → GSTextStorage setAttributes:range: → cacheAttributes → dictionary equality` |

Other stalls were about 470 ms during layout and 340 ms around insertion-point
layout. In the longest Split interval, a weighted main-thread wall tree puts
544 samples (94.8%) under `setViewerMode:persistPreference:`, including 350
(61.0%) under `layoutDocumentViews`. These inclusive groups overlap and are
not independent durations. Representative stacks above are the most frequent
individual stacks, not complete distributions or proof of scheduler/lock
causality. The full weighted wall trees are retained alongside CPU trees.

This confirms a **remaining shipped layout/attributed-text workload finding**.
It does not revive the already-fixed glyph sanity-check defect. The first
owner for review is MV's rendering/mode-change integration; the stack also
provides a concrete GNUstep text-storage/attribute-cache investigation boundary.
No new root cause or fix is established, and no blame is assigned to a theme
or Objective-C dispatcher based solely on sampled symbol names. The published
package also carries a separate attributed-string hash patch, so its numbers
cannot isolate the effect of the glyph guard relative to host builds.

Excluded attempts remain available: rejected group-writable generated config,
missed development-toolbar coordinates, and an updater-interference capture
(13.343 CPU seconds/6.370-second Split stall). The latter displayed an update
offer but no update was installed. The supported timer setting, rather than
the unrecognized `updates.enabled` fixture key, suppresses that background
activity in the accepted capture. No running owner instance or installed app
was touched. Evidence: `out/markdown-published-v025/Adwaita/` and
`out/mv-published/published-workflow-receipt.json`.
