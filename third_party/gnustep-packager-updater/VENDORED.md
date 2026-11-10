# Vendored gnustep-packager updater

`objc/` is a copy of `updater/objc` from
[danjboyd/gnustep-packager](https://github.com/danjboyd/gnustep-packager)
at the revision the release build pins (`packaging/release-inputs.json`),
with one local change:

- `OBJCFLAGS += -DHAVE_MODE_T` in the three `Makefile`s, as ScreenshotTool
  has: the Windows toolchain (gnustep-cli-new) otherwise defines `mode_t`
  twice, in libdispatch's `os/generic_win_base.h` and in the CRT. Re-apply
  it after a sync until the packager has it.

- Source commit: `a5c384b1fb6b252dc414b5420f4301cd32a181da` (v0.1.10).
- The **whole** `objc/` source tree has been compared byte for byte with
  `updater/objc` at that commit. Every file matches after removing exactly
  `OBJCFLAGS += -DHAVE_MODE_T` from each of the three Makefiles. There are no
  deliberately omitted upstream changes. `VENDORED.sha256` records the full
  upstream file inventory and normalized content hashes.
- `Tests/vendored-updater-checks.py` preserves that check after builds by
  checking source files and ignoring generated objects/binaries. The four
  shared source/header changes were the only upstream content changes since
  the previous vendored copy; all other source bytes already matched.
- Windows-specific files and Windows inputs/workflows were not edited.
  Shared updater behavior still needs separate Windows qualification.
- Source preparation only: builds and runtime acceptance are pending.

`Dashboard/GNUmakefile` builds GPUpdaterCore, GPUpdaterUI and
gp-update-helper from this copy and puts the helper in the app bundle. A
fix merged in gnustep-packager reaches Performance Dashboard only when this
copy is synced:

```sh
rm -rf third_party/gnustep-packager-updater/objc
git -C <gnustep-packager> archive <revision> updater/objc |
  tar -x -C third_party/gnustep-packager-updater --strip-components=1
# then re-apply the local change above and update the source commit here
```
