# Draft for gnustep-cli-new agent — Linux v0.1.0

Prepared with Codex assistance for Dan's review. Do not publish or send before
Dan approves the exact draft hash under docs/upstream-policy.md.

Performance Dashboard's first release now targets Linux x86_64/glibc only.
Dashboard/framework/gstrace use Clang/ARC/libobjc2; the injected C agent stays
independent of GNUstep/libobjc. Local C target checks passed with GCC 14 and
Clang 19, at -O0/-O2 without frame pointers, with host libunwind.

Our CI currently invokes the v0.1.0 gnustep-bootstrap.sh release asset with
SHA-256 3bdfa7a29a6442ce1bb994b027bfcba78beec649ae820391f009ac9eeb40ba63,
using `setup --user --yes`. Our AppImage provenance records bundled GNUstep
library build IDs. Please establish the missing toolchain contract:

1. Does that bootstrap select immutable payload versions and verify their
   digests? Supply the manifest/lock/provenance path and the exact command
   to export payload revisions, compiler versions, ABI and minimum glibc.
2. Which immutable toolchain revision should we freeze for a Linux candidate,
   and which distributions have actually passed clean-machine launch tests?
   We intend to test Debian 13 and Ubuntu 24.04 or narrow the support claim.
3. Is there an existing isolated GCC Objective-C/legacy GNU runtime fixture
   environment we can use? We do not need Dashboard itself to build with GCC;
   we need to test profiling a legacy-runtime target without mixing runtimes.

Please return exact revisions, commands and actual evidence. Do not publish,
retag or modify releases on our behalf. No upstream code changes are requested.
