# GSTextStorage cache fix: upstream preparation plan

Local documentation, October 29, 2026. No code is rebased or submitted by
this plan. Nothing in it is approved for transmission. The next assigned
implementation would belong to GNUstep **libs-gui**, starting from current
upstream `master`, not Performance Dashboard or libobjc2. The relevant
[upstream policy](../upstream-policy.md) applies to code, tests, descriptions,
issues and comments. The separate ScreenshotTool approval covers no part of
this work.

## Evidence and boundaries

The [diagnostic record](markdownviewer-layout-runtime.md#separate-gstextstorage-attribute-cache-diagnosis)
establishes the mechanism on GUI `549f639137a600936acde4cd618f0e4b858d883d`
with base `68f3d75694f0a7edf9fb1c6c7f19582e8cff1b5f`: default dictionary
hash equals count, and GUI's cache walks the resulting collision bucket with
deep equality. The published MV package's existing libs-base attributed-string
hash patch concerns a different cache. Its existing glyph sanity-check guard
is also separate and must not be bundled into a new cache submission.

The local content-hash prototype adds an identity-removal fallback because
values are shallow-copied and their hashes can change after insertion.
Ignoring that case can leave non-retained cache keys dangling. The current
fallback and missed-canonicalization trade-off need review; neither the final
design nor current-master behavior has been established. The retained diff
`dd3cbd5b…` includes diagnostics and the old glyph guard and is **not** an
upstream-ready patch. The one instrumented MV pair is not a production
speedup estimate. No Sombre overlay workflow or full GNUstep suite was run.

## Rebase and design gate

### November 3 inventory of the unfinished master port

The retained October 29 clone at
`out/linux-development-20261029/libs-gui-cache-master` is based on
`19dae207a3be9fb42a48d61ce856404295b62a06`. Its ChangeLog and
`Source/GSTextStorage.m` changes are uncommitted, and
`Tests/gui/NSTextStorage/attributeCache.m` is untracked. This is not a new
check of November 3 upstream master.

The retained control run reports **22 passed and one failed test**: doubling
distinct same-count runs violates the equality-growth bound at line 164.
The subsequent fixed build stopped in TextConverters after the test harness
leaked `GNUSTEP_LOCAL_ADDITIONAL_MAKEFILES=/src/gui.make` into the build.
There are no fixed test results, full-suite results, GCC check or fix commit.
The raw log is `out/linux-development-20261029/mv-cache-master-build.log`;
the control log and exit status are under `mv-cache-master/control/`.
Repair the harness scope and finish the gates below before preparing any
exact-hash upstream review. Repeated uninstrumented MV measurements under
both themes are still pending; nothing has been submitted.

### Required implementation gates

1. Fetch libs-gui `master` into a new owned clone/worktree and record its
   full commit, remote and retrieval date. Leave the host installation and
   other agents' checkouts alone. Check current source/history and existing
   open/closed issues and pull requests for this cache mechanism before
   preparing a proposal; it may already be fixed or discussed. If master has
   changed the cache, reproduce its behavior before carrying any hunk across.
   Record the matching base/runtime sources, compiler, configure flags and
   actual loaded libraries for every baseline/fixed run.
2. Reproduce the collision pattern on unmodified master using GNUstep's
   regression framework and a standalone attributed-text workload. Then
   prepare one focused change to `Source/GSTextStorage.m`: distribute
   same-count attribute dictionaries while preserving dictionary equality,
   cache ownership/refcounts and identity-based removal. Review whether a
   mutable-independent hash, stored insertion hash/identity lookup, or the
   prototype fallback is the smallest correct design. Do not select a
   workaround solely because the old prototype benchmark improved.
3. Keep mutable nested values, duplicate equal dictionaries, hash changes
   during the cached lifetime, table resizing and shallow-copy ownership in
   the design review. Hashes must agree for equal values and be independent
   of key enumeration order. Document worst-case removal cost and the effect
   of missed canonicalization. Do not assume arbitrary concurrent mutation
   of a single NSTextStorage is supported. Test separately owned storages
   under the library's documented threading contract if the design affects
   shared-cache locking or lifetime.
4. Remove diagnostic counters/destructor logging, test-only exported symbols,
   the packaged glyph guard and unrelated source changes from the proposed
   production diff. The existing guard may remain equally present in both
   *MV diagnostic builds* to isolate this cache, but is not a new submission.
   Never change installed GNUstep libraries to run an experiment.

## Regression test in GNUstep's framework

Add a focused `Tests/gui/NSTextStorage/attributeCache.m`, following the
existing `config.m`/`editing.m`: `Testing.h`, `START_SET`/`PASS`/`END_SET`,
manual retain/release, GNU style and declarations visible to GCC. Inspect
the **current master** `TestInfo` and harness registration requirements;
the inspected release tree's file is empty. Run with the built GUI library
using its `Tests/GNUmakefile` environment and `gnustep-tests` harness, not
PD's XCTest bundle. Initialize a private backend when fixing attributes
requires NSApplication/font services, and warm first-use global font/cache
state before counting test-owned work or lifetimes.

The regression should exercise public attributed-text behavior and the
observable collision cost without exporting private cache state:

- Use a small custom MRC attribute-value class with stable, varied hashes
  and a counted `isEqual:`. Insert N and 2N distinct same-count attribute
  dictionaries into controlled text runs. Count comparisons around the
  insertion phase, separately from font fixing/teardown. Establish a
  generous deterministic comparison-growth bound from actual master/control
  runs; avoid a wall-clock timeout or an exact implementation-specific count.
  Verify the test fails for the original collision behavior and passes with
  the fix. If current-master dispatch does not make this reliable, document
  that and choose a maintainable test-only observation seam rather than
  inventing a passing performance assertion.
- Read back every value and effective range after insertion, replacement,
  coalescing and removal. Cover equal dictionaries inserted in different
  key orders and unequal dictionaries with equal counts. Check no unrelated
  characters or attributes change; do not require internal pointer sharing
  as a public API promise.
- Mutate a nested custom value's hash while its dictionary is cached; cover
  one and multiple storages/runs, equal-after-mutation values and table
  growth. Remove in different orders, drain scoped pools, and verify expected
  object lifetimes. Then allocate/use attributes that revisit the old hash
  bucket. Run this scenario with an appropriate memory diagnostic to detect
  stale-key reads. Lifetime counts alone do not prove the map has no dangling
  keys. Where feasible, show a deliberately naive hash-only variant fails
  the safety check; it is a local negative control, not a patch to send.
- Include empty attributes, representative font/color/paragraph attributes
  and repeated edits. Record exact assertions and before/after counts from
  actual runs. Existing targeted prototype checks remain exploratory evidence
  and cannot be renamed current-master regression results.

Run the new test on pristine master and on each proposed commit. Run the
surrounding NSTextStorage and attributed-string tests, then the complete
GNUstep GUI suite at both baseline and final series head. Retain all counts,
exit statuses, skips and failures, explaining baseline differences. A lack
of suite prerequisites is an incomplete gate, not a passing result.

## ChangeLog, compiler and policy preparation

- Add a dated `ChangeLog` entry for Daniel Boyd
  `<danieljboyd@icloud.com>` naming the cache routines and regression file,
  what changed, and the ownership/mutable-value guarantee. Follow current
  master's surrounding format. One issue gets one focused commit containing
  implementation, GNUstep regression and ChangeLog; unrelated diagnostics
  stay outside the series.
- Run PD's `Tests/Scripts/gcc-syntax-check.sh <owned-series> <master-hash> HEAD`
  over the exact series, and its `--files` form for any separate reproducer.
  The planted literal/block canary must fail as designed and the check must
  exit zero with no new source diagnostics. This is syntax screening, not a
  full GCC build; record that limit and run an actual supported GCC build if
  available/required. Avoid ARC, blocks, object/collection literals, dot
  syntax and `@autoreleasepool` in material intended for GNUstep.
- The commit description must explain correctness, failing-before and
  passing-after results, test counts, limitations and AI assistance. The
  current repo policy contains historical Claude-specific disclosure/trailer
  wording. Identify the actual assistance truthfully as OpenAI Codex; do not
  falsely credit Claude or copy a `Reviewed-by`/`Signed-off-by` for Dan.
  Resolve the policy wording with Dan through AIManager before any
  transmission. This does not block preparing local code/tests later.
- Export the exact reviewed series with `git format-patch`, verify it applies
  to the recorded current master in a separate owned checkout, and update
  `docs/upstream-patches/README.md` only when an actual series exists. Record
  source, commit, patch-file and review-document identities. This plan does
  not create a fictitious patch entry or approval row.

## Measurements required on current master

Keep semantic tests separate from speed measurements. Build pristine and
fixed master with the same compiler, flags, base, backend and theme. First
collect comparison/hash/lookup/fallback counters in equally instrumented
diagnostic builds to check the mechanism. Then remove those counters for
performance runs: counting every deep comparison adds workload proportional
to the behavior being changed and can bias the measured difference.

Repeat the deterministic same-count workload at increasing sizes, measuring
unrecorded elapsed/CPU controls as well as profiled runs. Use repetitions and
alternate baseline/fixed order; preserve input hashes, hardware/load context,
raw runs and exclusions. Measure both stable immutable values and a bounded
mutable-value workload to expose fallback costs. Distinguish deep-comparison
counts, CPU time, elapsed latency and main-thread stalls.

For the real MV case, retain the published v0.2.5 native executable and the
460,726-byte input (SHA-256 `38846406…`), matched action sequence and identical
saved output hash `70789410…`. Build compatible current-master GUI overlays
and verify `/proc` maps; any required matching-base/backend changes must be
identical across the pair and disclosed, rather than claimed as an exact
shipped-runtime replacement. Keep the existing glyph guard equal in both
MV builds where needed. Use private homes/buses and private Xvfb under
**Adwaita and Sombre**, inspect screenshots, and preserve actual successful
Open/Edit/Save/Split actions and outputs. Report clean/unclean status,
dropped samples, quality warnings and weighted main-thread hang paths.
Confirm remaining stalls rather than implying this cache fixes all layout.
No master throughput or latency improvement may be claimed from today's
instrumented release-revision pair.

## Review and transmission gate

The completed future packet must give the exact master/fix hashes, explained
diff, GNUstep before/after results, complete-suite baseline differences, GCC
output, ownership/mutation risks, uninstrumented measurements and truthful
disclosure. Dan must review the exact material under stages 2/3 of
[the policy](../upstream-policy.md). Use AIManager for the review/approval
request; do not send an issue, patch, PR or comment now. A later rebase,
changed description, test or patch invalidates an earlier exact-hash review.
Approval and a specific send instruction must be recorded in
`docs/upstream-signoff.md` before transmission. No current-master checks or
future results in this plan have been run or claimed as passing.
