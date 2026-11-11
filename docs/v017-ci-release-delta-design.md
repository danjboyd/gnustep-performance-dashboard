# Custom CSD CI and release workflow delta design

Design only. No workflow is enabled, modified, dispatched or published by
this document. The earlier hosted-CI working draft remains unfinished and
unqualified. The slot-fix proposals are not a reviewed combined input yet.
No corrected SDK/AppImage or corresponding-source bundle exists.

## Separate review production from release promotion

Keep a future CSD review producer manual-only initially, contents/actions read,
with pinned action commits and an exact application ref. It consumes a reviewed
combined custom lock and builder identity, not the example builder fixture lock.
It emits unsigned review artifacts, logs and corresponding sources. It must
never create a tag, release, feed deployment or upstream post. A branch push
and hosted dispatch each retain their explicit session authorization boundary.

A future release.yml delta should select an explicit producer flavor rather
than infer custom mode from a stray environment variable. Keep the managed
producer unchanged. Add a CSD path only after source/SDK/package/GUI acceptance
of the same combined candidate. Review-only versions remain visibly suffixed;
no review artifact silently becomes a numeric release by renaming it.

## Producer and cache contract

1. Verify application source, complete lock/patch order, builder commit and file
   hashes before any fetch/cache use. The current XFixes proposal preserves15
   patches; the separate link patch would make a different combined lock.
   Counts come from that reviewed lock, never a hard-coded historical15.
2. Resolve the Debian13 base image immutably and record final image ID, recipe,
   compiler and complete package inventory before compilation. Explicitly add
   Xrender and Xfixes development packages. Bound total compiler jobs to two.
   Match this same image for downstream theme/app compilation.
3. Key an SDK cache by the complete lock/patch digest, exact builder source,
   resolved image and package inventory, target/architecture and configuration.
   A matching cache key is insufficient: verify official=false, LOCAL domain,
   exact prefix binding, seven resolved sources, applied hashes/order, every
   inventoried real ELF's bytes/build ID and required symlink targets. Retain
   actual fallback source checkout receipts and the real backend link log.
4. Reject partial prefixes, dirty sources, mismatched provenance or changed
   patch bytes. Preserve one fresh build workspace; never overwrite a managed
   install. Compile theme from its exact pin against that SDK and generate a
   real log-bound theme receipt. Do not accept an old installed theme.
5. Require HAVE_XFIXES and runtime-necessary features, reviewed direct library
   set, hard no-missing/no-unreviewed closure, input/payload identities and CSD
   keys/export. Printed real link commands replace the old quiet-log gap.
6. Run meaningful unit/headless/package/recording gates. Hosted headless/Xvfb
   results do not replace compositor-dependent corners/WM/menu acceptance or
   an independently booked GUI lifecycle slot on the exact artifact.

Cache saves must be limited to a trusted producer context. Untrusted PR output
cannot overwrite a cache later promoted to signing. Never store signing keys,
credential files or private passwd homes in the SDK/cache artifact.

## Corresponding sources are a hard producer gate

The earlier source draft must incorporate the reviewed robin-map correction:
the pinned libobjc2 CMake fallback selects v1.4.0, resolved
`4ec1bf19c6a96125ea22062f38c2cf5b958e448e`, rather than the inherited collector's
v1.2.1 label. Carry the verified archive hash and exact CMake evidence from the
separate accepted source-fix commit. Check actual build checkout identity; a
manifest assertion does not prove which fallback was compiled.

Collect exact app source, all seven SDK source archives, every applied patch,
combined lock, builder source, Adwaita source, packager/AppImage/runtime source
identities, license texts and the exact staged Debian-library source versions.
Archive paths, checksums and source inventory must be independently verified.
Reject path escapes, links to uncollected sources and byte/hash mismatch.

Do not remove the only matching APT indexes and later expect apt-get source to
reproduce the installed binary versions. Preserve the matching package/source
indexes or a separately reviewed immutable source-fetch input, and fail if
those exact Debian source versions cannot be retrieved. A later apt update is
not evidence of source equivalence. Label the first inventory-attested build
honestly; immutable identities alone do not establish bit reproducibility.

## Release.yml delta after producer qualification

- Require successful producer run, exact application SHA, accepted lock/builder/
  image/theme identities and an independent acceptance ledger referring to its
  final artifact SHA. Verify downloaded artifacts and corresponding-source
  coverage before assembly. Do not merge managed-SDK metadata into custom CSD
  provenance or trust the artifact's filename as its identity.
- Feed the custom producer's explicit provenance schema into assembly. Keep
  raw source/build identities and post-strip/package identities distinct;
  verify expected transformations and final payload bytes/build IDs.
- Make signing a distinct reviewed stage with no SDK compilation and no
  source fetch. Keep private-key access out of untrusted producer jobs. Bind
  package ID, version/channel, payload hashes and corresponding sources using
  the existing signing contract. Require refusal tests for missing keys,
  changed identities and invalid signatures before real promotion.
- Produce a review assembly artifact first. Tag creation, GitHub release asset
  upload and the approved feed deployment remain separate exact session
  approvals. Neither a successful workflow nor a lead's source review is Dan's
  publication approval. No new automatic publish-on-tag step is proposed.

## Checks required before any future dispatch

Static contracts should cover mode selection/fail-closed custom inputs,
patch-set identity/order, cache prefix/ELF/source drift, fallback source and
APT inventory mismatch, missing theme receipts, new/missing direct libraries,
all transitive exclusions, no signing material in build/cache jobs and no
write/publish permissions in a review producer. Source-archive verification
must exercise actual archive bytes, not only count manifest records.

Review the producer implementation only after the combined slot fixes and
source collector correction are incorporated in a new isolated branch. Run
its static checks locally; then obtain authority for that exact branch push
and hosted dispatch. A new laptop runtime slot is booked only after the
project lead reviews the complete source packet and exact candidate identities.
