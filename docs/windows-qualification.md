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

## Clean producer result and host availability

The clean producer completed successfully at
`2b25780aa0e1a3a9a81d0be4904bd624c3e46d78`, version
`0.1.1-qualification.2`. Provenance records clean application and packager
trees. A fresh toolchain extraction and clean build were used. The final
runtime inventory mapped 1,029 files after theme provisioning; package
owners remained 41. Install, sanitized launch, runtime audit, uninstall and
strict MSI-backend release assembly passed. Nothing was published.

Artifacts are in `dist/ci/windows`; the validated copy and assembly receipt
are in `dist/ci/windows-validated`. SHA256 values:

| Artifact suffix after `PerformanceDashboard-0.1.1-qualification.2` | SHA256 |
|---|---|
| `-win64.msi` | `0d12df36946b3a957b92d5b0053e572eff87cc62f2205be3e41ac1acfe5b0d97` |
| `-win64-portable.zip` | `a4817764123be8f6c7b285fa8fd269bbd2d5ee06d532689430d75c42a783fc56` |
| `-windows-sources.tar.gz` | `4adda51ee0c9f80301f06a975072b3def4d68bad40a7bf2a15853ff2715beae7` |
| `-win64.provenance.json` | `fc6f850bd1668f0265e35cc52fd4abae9e1d57833140ec5387a5f6b84129eeab` |
| `-win64.update-feed.json` | `fcc756e4971305e2c973c48f7aa46bf7d483e0a27e296c0b904f8f5eaad73d84` |

The packaged updater helper passed six preparation/recovery cases using
disposable local plans: bad digest, retry, refused HTTP download, interrupted
download, retry, and missing payload. Applying an intentionally invalid MSI
reported Windows Installer exit code 1620 in the updater's failed state.
Evidence is in `Tests/out/windows-updater-failures` and
`Tests/out/windows-installer-failure`; installer policy was not changed.

Dan answered the client availability question: **"No client available;
record the gate as blocked"**. Clean Windows client distribution and update
acceptance are therefore blocked, not passed. The integration agent received
the result and exact artifact hashes through the mailbox.

The first hosted workflow dispatch returned HTTP 404 because the new
workflow is absent from the default branch. A push trigger limited to the
Windows qualification branch allows hosted validation without merging or
publishing. Hosted results must be recorded separately from this clean local
producer result.

## Exact RC1 candidates, October 21

Dan authorized building, fixing, validating and preparing review artifacts for
both release tracks. Tags, publication and feed deployment still require
separate approval. The original checkout was preserved; clean detached
worktrees produced these unpublished candidates:

| Package version | Full application source commit | Local worktree |
|---|---|---|
| `0.1.1-rc1` | `ee730c6b919d474e462584a6f78661daf68db1df` | `out/candidates/v011` |
| `0.1.2-rc1` | `7ddc66368a17d273100f1ffc63662787fd094876` | `out/candidates/v012` |

Both producers used fresh toolchain extractions and clean pinned dependency
sources. Locked toolchain digests and the manifest signature were verified.
Each producer completed MSI install, sanitized launch, runtime audit,
uninstall and strict MSI-backend assembly. Each final runtime inventory maps
1,029 files to 41 package owners. These are Windows Server 2022 developer
environment results; they do not establish clean Windows 10/11 acceptance.
No application source fix was needed during this qualification.

### Exact artifact hashes

Each worktree retains five transferable files under `dist/ci/windows`, plus
an independent assembly receipt under `dist/ci/windows-validated`.
Artifact names below have the prefix `PerformanceDashboard-<package version>`.

| Version | Artifact suffix | SHA256 |
|---|---|---|
| `0.1.1-rc1` | `-win64.msi` | `089b57e50f222dbf8dde87b9d0e73ac7428854b607e538d25d813efd3a7c9f78` |
| `0.1.1-rc1` | `-win64-portable.zip` | `cc3f05422c47d87f83583d16f2e6c1a405bd9061b6fe5c9e170884b34a182910` |
| `0.1.1-rc1` | `-windows-sources.tar.gz` | `5d02706fe97e8969d18b34e324f0a575c3df8ae22d82ca05fe9aa154a864b6ab` |
| `0.1.1-rc1` | `-win64.provenance.json` | `f971a40410a5d215fc08639418eb43e3db7e8e681a63d9fc0b3072625ab297be` |
| `0.1.1-rc1` | `-win64.update-feed.json` | `a68685a4c66f005e555495834c0cc5c436eedfdb9aad26e45c119a3c37add8ee` |
| `0.1.2-rc1` | `-win64.msi` | `d4dda1bc89fc6c0775c240bae3b19991037bc8fd5391b96ea58489be68c4fa1a` |
| `0.1.2-rc1` | `-win64-portable.zip` | `03c44ada29abb2460658e70d96af10a7b80275349289d5227d4e82ae7340af7a` |
| `0.1.2-rc1` | `-windows-sources.tar.gz` | `65f376bb236a8b744271383f96ba8cc437442c65107d5e0d58eb2b348263316e` |
| `0.1.2-rc1` | `-win64.provenance.json` | `badfe73e5bb4dea8aa48e6e0756f791e55670f3ac0e080fc5336023d2f36ec56` |
| `0.1.2-rc1` | `-win64.update-feed.json` | `f8d3595840d86587463764c08ac65854528d4438fa849d86dfccea6f03935057` |

Dan explicitly approved private transfer to the Linux coordinator. All ten
files arrived with matching independently checked remote SHA256 values;
native fixture captures were transferred separately. This was a private
review handoff, not publication. Matching Linux producers are runs
`39678830470` and `39678834584`, respectively. The Linux coordinator reported
in mailbox message 92 that both strict combined AppImage/MSI assemblies passed
at the same source revisions, all source-archive checksum entries passed, and
its packaged readers verified both transferred native Windows captures.

### Checks performed

| Check | v0.1.1 | v0.1.2 |
|---|---:|---:|
| Applicable framework unit tests | 18 passed | 23 passed |
| Assembly / runtime ownership / source-integrity tooling tests | 12 / 6 / 4 passed | 12 / 6 / 4 passed |
| Exact portable viewer / synthetic portability / recording checks | 10 / 6 / 25 passed | 10 / 6 / 25 passed |
| Exact packaged reader verifies matching native Linux summary and exports | Passed | Passed |
| Packaged native Windows capture, embedded symbols, reopen and exports | Passed | Passed |
| Updater preparation, rejected digest/download, interruption and recovery | 6 passed | 6 passed |
| Invalid MSI apply failure propagated as exit 1620 | Passed | Passed |
| Real Dashboard and ScreenshotTool recordings, all five requested instruments | Both clean | Both clean |
| Native AppKit fixture: three hangs and three `Block` signpost intervals | Passed | Passed |
| Native investigation-controller assertions | Not applicable | 14 passed |

The installed `0.1.1-rc1` helper also prepared and applied the exact
`0.1.2-rc1` MSI, reported `completed`, and relaunched the updated app. There
was exactly one product entry before and after, changing from MSI version
`0.1.1.1` to `0.1.2.1`; installed application bytes matched the respective
portable packages. Windows Installer reported the initial installation as
`MSIINSTALLCONTEXT_USERUNMANAGED` (context 2). The test product was uninstalled
afterward. Evidence is `dist/rc1-local-upgrade-resumed/result.json`,
`state.json`, `msiexec.log` and `cleanup.json` in the original workspace.
This tests the cross-version RC1 transition on the developer environment;
it does not qualify same-version RC ordering, final-package updates or a
clean client. The initial HKCU-only product lookup and UTF-16 log parsing
assumptions failed in the temporary harness; the exact known test product
was verified before cleanup, and those failed logs were retained.

The exact ZIPs were extracted under `dist/RC portable café` in their respective
worktrees. Each extraction had all 1,255 original files byte-matched against
its ZIP. Package checks used those packaged executables; framework tests used
the existing tools-xctest installation. Matching native Linux inputs came from
candidate CI runs `39678772273` and `39678773175`. The generated native Windows
captures are under `Tests/out/native-windows-rc1`.

Both real GUI targets had CPU and allocation data, wall samples, two leak
scans and a clean stop. Only their owned windows were captured. The
ScreenshotTool revision and input remain those identified above. These
workloads produced no signposts or induced hangs. Positive event evidence
comes from the separate `hangapp.m` fixture, not those two applications.
That fixture uses a separate copy of the packaged runtime plus its own
target-side `gsperf.dll` and verified pthread dependency. Its three observed
hangs fall near the expected 0.3, 0.7 and 2.2 seconds.

The v0.1.2 investigation gate reports the exact clean source revision and exit
zero in `Tests/out/investigations-rc1/result.json`. Its generations,
comparison, hang drill-down and source screenshots were inspected. This is
AppKit-event/controller evidence; physical file-picker interaction and a
full client-display layout were not accepted by this run.

Producer logs are `dist/v011-rc1-producer*` and `dist/v012-rc1-producer*` in the
original workspace. Per-candidate packaged logs, updater results, GUI
screenshots and integrity receipts are under `dist/qualification`; framework
logs are `dist/v011-rc1-framework*` and `dist/v012-rc1-framework*` in the original
workspace. Initial temporary-harness failures are retained: MSYS path
conversion, an incorrect updater test path, missing target-side pthread,
standalone fixture backend lookup and native-menu discovery. They were not
product fixes or passing acceptance evidence. In particular, recorder exit
zero alone was insufficient: an aborted fixture's trace was explicitly
rejected until `finished cleanly: yes`, three hangs and three signposts were
observed.

### Subsequent exact-package GUI acceptance

Both RC1 portable packages subsequently passed actual foreground menu and
control interaction: Record, Stop, Record again, Stop, Save As, reopen and
JSON export. Saved trace files byte-matched their inputs; exported CPU counts
matched the packaged reader. Both also attached to their own disposable
fixture process through the process picker, stopped cleanly while leaving the
target running, saved the attached trace with the exact selected PID, and
showed the visible refusal to record the same process a second time.
Evidence is each candidate's `dist/qualification/package-ui-result.json`,
`live-ui-result.json` and `attach-ui/result.json`, with owned-window captures.
These checks used the production packaged executables, pointer/keyboard input
and native dialogs, without controller-selector substitutes.

The v0.1.2 packaged comparison window accepted `objleaks.gstrace` through the
actual directory picker and displayed the expected baseline/current caption.
Allocated Bytes was selected and Compare invoked. The inspected screenshot
showed zero changed rows; this is picker/metric interaction evidence, not a
positive allocation-difference result. Generations and comparison default
windows fit the current 1100 by 1332 desktop. At a requested width of 1008,
controls and the detail inspector remained visible, while some table headings
were truncated. This does not establish acceptance at every supported display
size. Evidence is `dist/qualification/layout-ui-comparison-1008-baseline-native-backslashes`
and the generations/comparison layout captures.

Temporary input-driver failures were retained: hidden windows, absent native
menu handles for custom menus, unsupported text-entry approaches and forward
slashes rejected by the native folder picker. Native Windows paths corrected
the last failure. No product change was made to accommodate the driver.

### RC2 and numeric-final review sequence

Four additional unpublished review sets were produced: `0.1.1-rc2`, `0.1.1`,
`0.1.2-rc2` and `0.1.2`. They use the unchanged pinned packager backend and
verified RC1 staging, not fresh application rebuilds. Application binaries
are byte-identical to their respective RC1 binaries; the corresponding-source
archives are also byte-identical to the respective RC1 closures. Source
worktrees and packager were clean. RC2 uses prerelease configuration and each
numeric final retains its original stable configuration. Each set passed MSI
install, sanitized launch, uninstall and strict assembly. Artifacts and their
validation logs are under each candidate's `dist/review-sequence/<version>`;
assembly receipts are in the adjacent `<version>-validated` directory.

Each track passed both installed transitions, RC1 to RC2 and RC2 to numeric
final. The installed updater selected the private prerelease final feed in
an API probe, downloaded and hash-checked the exact MSI, applied it, reported
completed and relaunched the replacement. Each transition retained exactly
one per-user unmanaged product entry; installed application and updater
configuration bytes matched the target portable package. The final installed
stable configuration reported up-to-date. All known disposable test products
were uninstalled. Evidence is `dist/review-sequence-acceptance/results.json`
and its per-track receipts, state, plans, selection logs and cleanup records
in the original workspace. Feed URL substitution was in memory in the API
probe; this was not an in-app updater GUI check. The loopback server was
stopped, and no public feed was deployed.

The exact review hashes below are also recorded with staging/source provenance
in `dist/review-sequence-artifacts.json` in the original workspace.

| Version | Artifact | SHA256 |
|---|---|---|
| `0.1.1-rc2` | `PerformanceDashboard-0.1.1-rc2-win64-portable.zip` | `7d0a07c248f912a51adf59a15a43d30453e2138ca7d64f451c891198dd41b60f` |
| `0.1.1-rc2` | `PerformanceDashboard-0.1.1-rc2-win64.msi` | `ed81e856fe2ee471a0b9533fe73f4974df7e83dcf926850fa890509befaf934d` |
| `0.1.1-rc2` | `PerformanceDashboard-0.1.1-rc2-win64.provenance.json` | `1f28f28ddb8677b0e179e6190ce1982f035bb63db337c9f247f9bb58606c9e47` |
| `0.1.1-rc2` | `PerformanceDashboard-0.1.1-rc2-win64.update-feed.json` | `9d100c7b2d8669c6428529debdf0e0c7abcfdfab0cffd552111bc7178c900756` |
| `0.1.1-rc2` | `PerformanceDashboard-0.1.1-rc2-windows-sources.tar.gz` | `5d02706fe97e8969d18b34e324f0a575c3df8ae22d82ca05fe9aa154a864b6ab` |
| `0.1.1` | `PerformanceDashboard-0.1.1-win64-portable.zip` | `af1bc71032eecc25eadda82aad4b5ab57d35924c7e623231f52be862b7a4e57f` |
| `0.1.1` | `PerformanceDashboard-0.1.1-win64.msi` | `81634b2007bddedb2f88830a22ee51f710f54e2b9f0f59ca87ba35d292561b73` |
| `0.1.1` | `PerformanceDashboard-0.1.1-win64.provenance.json` | `7e15b575291479dd5bdcb01e0d904e1bc11851cb1bc8a69159fc666fbba99c64` |
| `0.1.1` | `PerformanceDashboard-0.1.1-win64.update-feed.json` | `bd639536f2e464cca1210c6fb05090b3befefc5b640c2ed029aa0573792e8a50` |
| `0.1.1` | `PerformanceDashboard-0.1.1-windows-sources.tar.gz` | `5d02706fe97e8969d18b34e324f0a575c3df8ae22d82ca05fe9aa154a864b6ab` |
| `0.1.2-rc2` | `PerformanceDashboard-0.1.2-rc2-win64-portable.zip` | `eddd367383377e1c42c33e5d147bd3300d267b66c9df31f5603e92ffceeb851d` |
| `0.1.2-rc2` | `PerformanceDashboard-0.1.2-rc2-win64.msi` | `76ddf406d2147378e814ee72026d90c3c7e6816d2b8fdb0e15fd4f5b051c40b5` |
| `0.1.2-rc2` | `PerformanceDashboard-0.1.2-rc2-win64.provenance.json` | `5d0d4c5ef75760088d9cafd37a9a707c605bfce9259743ee2aef9fb7906f984d` |
| `0.1.2-rc2` | `PerformanceDashboard-0.1.2-rc2-win64.update-feed.json` | `a250160b34249f3f277291abc4bf5e3b7967419f33823ce743b89046962de138` |
| `0.1.2-rc2` | `PerformanceDashboard-0.1.2-rc2-windows-sources.tar.gz` | `65f376bb236a8b744271383f96ba8cc437442c65107d5e0d58eb2b348263316e` |
| `0.1.2` | `PerformanceDashboard-0.1.2-win64-portable.zip` | `1373936d669bc0fd258b0c1b5fdd6efdbfeff5e6d7bd5340685e6253e76b33e8` |
| `0.1.2` | `PerformanceDashboard-0.1.2-win64.msi` | `7d80e633541906eda5074b9279877aadddb5c1d6b90d2bf980dd3f8e74f5f229` |
| `0.1.2` | `PerformanceDashboard-0.1.2-win64.provenance.json` | `f77fef5909ffda0b8329ed48c90def13761c3b1d1356cc5dd510ed3eca84069e` |
| `0.1.2` | `PerformanceDashboard-0.1.2-win64.update-feed.json` | `97ba476ec427ddfd03769efc738ca6e0f2726fe5029a6bfa43a8dc6c613b01e9` |
| `0.1.2` | `PerformanceDashboard-0.1.2-windows-sources.tar.gz` | `65f376bb236a8b744271383f96ba8cc437442c65107d5e0d58eb2b348263316e` |

The numeric-final ZIPs were additionally checked in separate clean source
worktrees `out/candidates/v011-final-checks` and `v012-final-checks` using the
same portable viewer, synthetic, recording, native interchange and positive
AppKit fixture checks. Per-worktree `dist/qualification/integrity.json`
records the archive digest and all 1,255 original package files unchanged.
These are targeted exact-package checks on the developer host, not blanket
final release qualification or a new source build.

### Exact numeric-final follow-up

Both exact final portable packages passed physical Record/Stop/Record again,
Save As/reopen/export and Attach/Stop/save, including a visible once-per-process
refusal. Saved captures were clean, with 7,700 and 7,708 CPU samples matching
the packaged reader and GUI JSON. Attach used visually verified owned PIDs;
Stop preserved each target and saved traces retained the exact selected PID.
Receipts are `dist/qualification/final-live-ui-result.json` and
`attach-ui/result.json` under `out/candidates/v011-final-checks` and
`v012-final-checks`.

The exact v0.1.2 final UI selected the real Dashboard baseline and ScreenshotTool
current capture through its actual folder picker, then displayed 604 changed
Allocated Bytes rows. Malloc 264 Bytes changed from 830,016 to 6,799,056 bytes,
delta 5,969,040, agreeing with the exact CLI. Different workloads do not
establish a performance regression. The receipt and image are under
`dist/qualification/layout-ui-comparison-1008-baseline-real-app-delta-corrected`
in the final v0.1.2 check worktree. Each final extraction's 1,255 original files
were reverified unchanged after live GUI checks.

The approved private transfer of all 20 additional files and the 297-entry
receipt archive completed. The Linux owner independently checked all digests,
all four combined AppImage/MSI assemblies, the four portable inventories and
both source closures (mailbox 137). These are independently reported Linux
results, not locally executed Windows checks.


## October 22 applicability and documented limitations

ReleaseCoordinator relayed Dan's decisions from user-edited QUESTIONS.md in
messages 176/179. The original file was not independently read by the Windows
agent. This provenance does not authorize tags, pushes or publication.

There was no Windows v0.1.0 release, so its Windows upgrade to v0.1.1 is not
applicable. It is not a passed upgrade. Both RC1-to-RC2-to-final chains and
v0.1.1-to-v0.1.2 remain required on the clean client.

Positive hangs and signposts were verified in test programs. The two unchanged
real GNUstep apps recorded for Windows supplied CPU/allocation/leak and
clean-stop evidence, but not positive hang/signpost intervals. Dan accepted
fixture evidence with this explicit limitation. This is a release-scope
decision, not a claim that real-application positive events were observed.
The OpenTrace signpost draft `59d752f` remains a v0.1.3 candidate.

Some table headings truncate around a 1008-pixel window width. Dan selected
shipping the frozen versions with this known limitation; the layout fix is
reserved for v0.1.3 (`4f0092e`). No layout or signposting draft is in these packages.
This does not claim successful testing on every client display.

The remaining execution gate is the clean Windows client run. A separate
Windows 11 evaluation guest is reportedly being prepared but has not been
accessed or qualified by this Windows agent. Kit preparation and developer-
host results do not replace its install/launch/record, portable Unicode/space
paths, per-user identity, upgrades, uninstall and cleanup acceptance.
