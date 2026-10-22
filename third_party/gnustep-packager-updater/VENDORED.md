# Vendored gnustep-packager updater

`objc/` is a copy of `updater/objc` from
[danjboyd/gnustep-packager](https://github.com/danjboyd/gnustep-packager)
at the revision the release build pins (`packaging/release-inputs.json`),
with one local change:

- `OBJCFLAGS += -DHAVE_MODE_T` in the three `Makefile`s, as ScreenshotTool
  has: the Windows toolchain (gnustep-cli-new) otherwise defines `mode_t`
  twice, in libdispatch's `os/generic_win_base.h` and in the CRT. Re-apply
  it after a sync until the packager has it.

- Source commit: `211d9136ca2359fdb91af8245b5c86b497e07220` (gnustep-packager
  v0.1.4, 2026-10-22)

This sync includes the install-failed alert punctuation fix. The three local
compatibility lines above remain for the currently pinned Windows toolchain;
remove them only after validating the replacement input.

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
