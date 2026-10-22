# Release review handoff

Updated October 22, 2026. ReleaseCoordinator owns release coordination and
cross-platform assignments. The Linux development agent owns Linux changes
and validation. No new feature work is assigned while the frozen releases
are under review; fixes for demonstrated blockers use isolated follow-up
branches. Tags and publication require Dan's separate in-session approval.

## Source identities

| Review version | Candidate branch | Application source commit |
|---|---|---|
| `0.1.1` | `work/v0.1.1-candidate` | `ee730c6b919d474e462584a6f78661daf68db1df` |
| `0.1.2` | `work/v0.1.2-candidate` | `7ddc66368a17d273100f1ffc63662787fd094876` |

The shared work branch was at documentation-only head `33e17d7` before the
current evidence update. Later documentation commits do not change package
source identity. The candidate branches share base `7a6cae1`; the v0.1.1
version-alignment commit is not an ancestor of the v0.1.2 candidate. Preserve
sources when planning tags or merges. A new implementation, merge or package
input requires applicable qualification rather than inheriting exact-package
evidence automatically.

## Evidence and review artifacts

Read [the v0.1.1 ledger](v0.1.1-validation.md),
[the v0.1.2 plan](v0.1.2-plan.md),
[the Windows ledger](windows-qualification.md), and the
[v0.1.1](releases/v0.1.1.md) and [v0.1.2](releases/v0.1.2.md) draft notes.
The release process remains [release.md](release.md).

Both frozen sources passed their strict Linux gates, including Adwaita and
Sombre. Both exact numeric-final AppImages additionally passed disposable
Debian acceptance, isolated helper VM attachment, viewer/synthetic/native
trace checks, updater failure/recovery, real GUI recording, Save As/reopen
and GUI/CLI JSON parity. The final v0.1.2 GUI also preserved a named
allocation generation and its sidecar through Save As and reopening.

Windows reports passing exact-final live and attach workflows, complete
installed RC update sequences and positive allocation comparison evidence.
Those developer-host receipts and selected screenshots were independently
reviewed on Linux. They do not constitute clean Windows client acceptance.

All twenty additional Windows RC2/numeric-final review artifacts were
privately transferred with Dan's approval and matched the recorded hashes.
The 297-entry acceptance bundle matched its hash. Runtime, source, notice
and provenance audits passed. Strict combined AppImage/MSI assembly and all
output checksums passed for both RC2 and both numeric-final review versions.

Retained local evidence is under `Tests/out/final-review-20261022`, including
per-version `acceptance.json`, `combined-review-receipts.json` and independent
Windows audit receipts. Combined review trees are under
`dist/review-20261022/combined/VERSION`. Earlier exact RC1 evidence remains in
`Tests/out/candidate-acceptance`; Linux update-sequence evidence is in
`Tests/out/update-sequence-review`. These generated directories are not
source-controlled. Do not repeat completed suites without a new defect,
changed input or missing acceptance case.

## Remaining decisions and gates

- Clean Windows client installation/update acceptance is blocked because Dan
  confirmed no client is available. Developer-host and hosted-runner results
  do not waive it.
- Positive hangs/signposts in two real GUI applications remain open under
  the Windows acceptance plan. The existing unchanged real workloads emitted
  none; fixture positives establish feature behavior separately.
- Supported Windows client layout remains open. Current developer-desktop
  evidence and forced narrow-window checks do not establish client coverage.
- Existing qualified toolchain and packager pins remain unchanged. New input
  versions have not been qualified for these frozen package identities.
- No tag, publication or feed deployment is approved by the development work
  or private artifact-transfer approval. A previously blocked Windows
  documentation push remains separate from the application candidate sources.

Detailed local listener recovery and operational history is retained outside
the repository. Both current listener bindings were verified, including an
actual automatic wake in each direction; no listener change is needed for
the role handover.
