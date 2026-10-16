#!/usr/bin/env bash
# Builds the Adwaita GNUstep theme the Linux AppImage ships, from
# its pin in packaging/release-inputs.json (scripts/pinned-checkout.sh),
# against the gnustep-cli-new install.
#
#   scripts/build-adwaita.sh        # prints the built Adwaita.theme's path
#
# Inputs (environment): GNUSTEP_CLI_ROOT (~/.local/share/gnustep-cli) and
# ADWAITA_BUILD_DIR, where the checkout lives (out/adwaita). Each run resets
# the checkout to the pinned revision. package-stage.sh uses ADWAITA_THEME
# instead when it is set.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
gnustep_root="${GNUSTEP_CLI_ROOT:-$HOME/.local/share/gnustep-cli}"
build_dir="${ADWAITA_BUILD_DIR:-$repo_root/out/adwaita}"

die() { printf 'build-adwaita: %s\n' "$*" >&2; exit 1; }

[[ -f "$gnustep_root/System/Library/Makefiles/GNUstep.sh" ]] || die "no gnustep-cli-new install at $gnustep_root (set GNUSTEP_CLI_ROOT)"
"$repo_root/scripts/pinned-checkout.sh" adwaita "$build_dir" >/dev/null

(
  cd "$build_dir"
  set +u
  # shellcheck disable=SC1091
  . "$gnustep_root/System/Library/Makefiles/GNUstep.sh"
  set -u
  # As in build-libs-back.sh: no install path from the headers' assertions
  # in the binary, so builds on different machines are identical.
  prefix_map="-fmacro-prefix-map=$gnustep_root=/gnustep-cli"
  make -j"$(nproc)" AUXILIARY_OBJCFLAGS="$prefix_map" AUXILIARY_CFLAGS="$prefix_map" > "$build_dir/make.out" 2>&1 || { tail -20 "$build_dir/make.out" >&2; exit 1; }
) || die "the build failed (log in $build_dir/make.out)"

theme="$build_dir/Adwaita.theme"
[[ -x "$theme/Adwaita" ]] || die "no theme at $theme"
printf '%s\n' "$theme"
