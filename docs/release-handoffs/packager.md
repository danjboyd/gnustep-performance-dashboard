# Draft for gnustep-packager agent — Linux v0.1.0

Prepared with Codex assistance for Dan's review. Do not publish or send before
Dan approves the exact draft hash under docs/upstream-policy.md.

Performance Dashboard's v0.1.0 is Linux-only. Its local AppImage build,
package validation, GUI recording and bundled-CLI recording passed on
2026-10-19 using gnustep-packager commit
362f270baf442c57f0736522530b82dd6a164e2e. Nothing has been tagged or published.

Please return information, not a release or deployment:

1. Which immutable packager revision/tag should we freeze for this release?
   Identify any updater/AppImage fixes since our pin that should be included.
2. What clean-machine Linux baseline and runtime-dependency report should we
   use? Our staging deliberately leaves glibc/display/GTK dependencies to the
   host. The injected agent separately dlopens host libunwind and the viewer
   uses host addr2line, so DT_NEEDED closure does not establish those features.
3. Is the local RC1-to-RC2 AppImage updater test sufficient for your updater
   contract? Please give a reproducible failure/rollback test and identify
   the matching GPUpdaterCore/UI/helper revision if our vendor needs updating.

Please include commit IDs, relevant local documentation paths, test commands
and actual results. We are not requesting changes in your repository yet.
Our outstanding release gates are clean-machine validation, real GUI workload
acceptance, helper lifecycle, candidate update and exact toolchain provenance.
