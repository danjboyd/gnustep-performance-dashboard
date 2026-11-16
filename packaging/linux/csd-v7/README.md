# PD v0.1.7 CSD backports (source preparation)

These are local backports of the public v7 Adwaita CSD changes. They are not
an official GNUstep toolchain and have not been compiled or run. The v0.1.6
release inputs are unchanged. `backports.json` pins original public URLs,
original file hashes, final backport file hashes, authors and source commits.

The GUI base is `7892137bdedd007eba8425f766e41481ddb4fda6`. Apply
`libs-gui/0001-pd-backport.patch` to it.

The backend base is `bf3b3ced525f08415a20d109f05be1f91492414c`. First apply the
two existing patches from `../libs-back/libs-back.lock.json`, in their listed
order. Then apply this series in exactly this order:

1. `libs-back/0003-pd-backport.patch`: borderless ARGB windows.
2. `libs-back/0004a-pd-backport.patch`: focusless window stacking and its test.
3. `libs-back/0004-pd-backport.patch`: window shadows and rounded corners.
4. `libs-back/0005-pd-backport.patch`: optional menu/popover shadows.

Use the explicit order above; lexicographic ordering puts 0004 before 0004a.
The standalone public 0002 menu-types patch is not part of this v7 series.

Original authorship, original AI assistance credit and regression sources
are preserved. Each commit distinguishes the original upstream description
and historical test results from the PD backport's source-only validation.
PD preparation used OpenAI Codex. ChangeLog entries describe the backport;
none claims a new runtime test result or new human sign-off.

`source-application-receipt.json` records strict `git apply --check` and
application in fresh source trees, without three-way fallback. Every
Source/Headers/Tests file matched the inspected public-v7 merge result; the
only additional source-tree file changes are the PD ChangeLog entries.
The initial preparation script's mail parser did not handle the existing
plain-diff zero-extents bootstrap; it was corrected before verification.
The original zero-extents attribution to Todd White is retained.

A reviewed custom toolchain lock, build and runtime qualification are still
required. Keep PD's coherent Base plus TLS patches, libobjc2, make and compiler
inputs explicit. Use only the public sources pinned in the manifest. Do not
mix headers and runtime across the NSTextAlignment renumbering boundary or
reuse another installation's qualification for this stack. The v7 0004a test's pending
upstream review is not approval of these new backport hashes.

No build, installation, publication, workflow dispatch, push, tag or feed
change is authorized by these files. The planned custom lock and consuming
build job will be reviewed separately.
