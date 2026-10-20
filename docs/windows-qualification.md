# Windows qualification work, October 20

These are developer-host results, not clean-client release acceptance. The
host reports Windows Server 2022 Standard, build 20348.4893, and already has
a GNUstep developer installation. No installer policy, signing setting,
release tag or deployed feed was changed.

## Native runtime

The integration baseline was `1b44d99f13e4728c1571029efb595d8b0a8124fb`.
Both Windows v0.1.1 ZIPs and metadata were downloaded through
`scripts/fetch-toolchain.py --platform windows dist/toolchain-windows`.
Every locked SHA256 and the manifest's OpenSSL signature verification passed.
The toolchain was extracted into the workspace, rather than changing the
existing developer installation. Packager source matched
`23f17080e37ef73e786aed9d34f65abd07eeb97e`; the Windows theme matched
`906e462ca6f3c42d4463cc2f22277888436cda21`.

The native build succeeded. Framework tests passed 18 applicable cases
(the Windows symlink-alias subcheck was unavailable), viewer checks passed
10, and synthetic portability checks passed six. Logs are retained locally
in `dist/native-build*` and `dist/native-checks*`.

Real GUI recording exposed an access violation reading address `0x20`
inside `ntdll!RtlVirtualUnwind`, called by the agent's sampler. Dashboard
launched without recording but crashed before its window appeared when
recorded. A temporary debugger captured the second-chance exception stack
in `dist/debug-gui.log`; it is diagnostic evidence, not shipped code.

Commit `94d017730f0b64c5f64b84f06f18e5b6763f5986` handles unwind access
faults, preserves truncated samples and resumes the target. Its assembly
fixture temporarily clears the frame register while retaining unwind
metadata. The fixture produced an unfinished trace before the fix and a
clean 1.2-second recording with wall samples afterwards. All **25 Windows
recording checks** passed after the fix. The suite also resolves the attach
fixture's native PID after startup: an earlier run caught a race attaching
to its transient `sh.exe` instead of `spin.exe`.

## Real GUI observations

The first exploratory portable ZIP was extracted to
`dist/GUI qualification café`. Its agent was then replaced by the fixed
local agent for diagnosis; these recordings do not qualify the original
ZIP's hashes.

- Dashboard: template chooser startup, 12-second recording, CPU,
  allocations, leaks, hangs and points of interest enabled. Recording
  finished cleanly; two leak checks completed. Screenshot
  `dist/gui-dashboard-fixed.png` was inspected.
- ScreenshotTool: unmodified source revision
  `beaa38bc0c5580fe5e4e417d564ae118199afde0`, with its pinned libs-sharing
  submodule. Opened `Dashboard/Resources/PerformanceDashboard.png` and
  recorded for 12 seconds with the same recording types. Its own
  libc++, libdispatch, BlocksRuntime and winpthread DLLs were supplied beside
  the target executable from the verified toolchain. Recording finished
  cleanly; two leak checks completed. The rendered image and toolbar in
  `dist/gui-screenshottool-rendered.png` were inspected.

The image input SHA256 is
`d2328a5fff06639c254c8e9c313415110487153973a782939d9632653b96169a`.
ScreenshotTool executable SHA256 is
`8ef471d6535123b584405c452e348407863447638acf954db269fece047081ab`.
Traces are in `Tests/out/gui-dashboard-fixed.gstrace` and
`Tests/out/gui-screenshottool-rendered.gstrace`; command output and screenshots
are under `dist/gui-*`. Developer toolchain paths were removed from the
recording processes' PATH. These workloads emitted no signposts and induced
no hangs: positive GUI signpost/hang cases remain unverified.

## Windows package producer

Run with PowerShell 7, Python 3.14, Git, OpenSSL and native Windows tar:

```powershell
./scripts/package-windows.ps1 -Version 0.1.1-qualification.2 -Release
```

The producer requires a clean application checkout and a new toolchain
extraction for `-Release`, verifies downloaded inputs, checks out clean pinned
packager/toolchain/theme sources, builds, stages, provisions and validates.
It does not change the shared packaging manifest. It uses an ignored
prerelease copy, preserving the Windows prerelease feed and channel.
Existing `dist/packages` and `dist/ci/windows` must be archived before another
run. The manual `windows-package.yml` workflow runs the same entry point and
uploads a flat `windows-packages` artifact; it has read-only repository
permissions and no publishing steps.

`windows-runtime-inventory.py` byte-matches every staged runtime file to its
pacman owner or the project's own build output, then rechecks after theme
provisioning. Theme files must match the clean pinned theme's build output.
The preliminary stage mapped 1,023 files to 41 package owners. Package-owned
license texts, including ICU's nonstandard location, are preserved. Source
license texts are also copied, including GNUstep Base's GPLv2 text for its
tools. The theme notice uses its own pinned `COPYING.LIB`.

`prepare-windows-sources.py` maps owners through the toolchain's hash-checked
sync databases and downloads only their source packages. All 41 source
archives (361,076,132 bytes) were acquired; every declared SHA256 recipe
input was checked, without executing recipes. Their archive digests and
versions are pinned in `packaging/windows-runtime-sources.json`. Downloaded
archive signatures were not independently verified; the digest pins are
from this acquisition. Source archives retain upstream tarballs, recipes
and patches. The outer corresponding-source archive also carries application,
theme, packager and toolchain-assembly Git archives, and ownership metadata.

Six ownership/license guard tests, four source-integrity tests, six toolchain
fetch tests, five source-inventory tests and 12 release-assembly tests passed
locally. The source/ownership tests cover modified or unowned dependencies,
missing licenses, altered extracted notices, altered source archives,
missing recipe inputs and recipe digest mismatches.

An exploratory dirty-tree `0.1.1-qualification.1` MSI and ZIP were produced.
The MSI passed install, launch with toolchain PATH/environment removed,
runtime audit and uninstall on this host. Logs are in
`dist/logs/validate-msi` before the next run archives them. This does not
qualify clean-client installation, the in-app update flow, or a final source
commit. Exact clean-build artifacts and hashes must be reported separately.

## Outstanding acceptance

The integration agent owns the shared acceptance ledger. Clean Windows
client installation, positive real GUI hangs/signposts, interactive
save/reopen/export, RC-to-RC-to-final updates and failure recovery remain
independent acceptance cases. Native fixture coverage and a server-host
MSI smoke result do not substitute for those gates. Tags, publication and
update-feed deployment require Dan's separate in-session approval.
