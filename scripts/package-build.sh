#!/usr/bin/env bash
# Builds Performance Dashboard (runtime, framework, gstrace, helper, app)
# with GNUstep Make against the gnustep-cli-new install, for the packager's
# build step.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

gnustep_root="${GNUSTEP_CLI_ROOT:-$HOME/.local/share/gnustep-cli}"
if [[ ! -f "$gnustep_root/System/Library/Makefiles/GNUstep.sh" ]]; then
  printf 'package-build: no gnustep-cli-new install at %s; set GNUSTEP_CLI_ROOT\n' "$gnustep_root" >&2
  exit 1
fi
set +u
# shellcheck disable=SC1091
. "$gnustep_root/System/Library/Makefiles/GNUstep.sh"
set -u

# Keep Trellis outside the application source and build its ARC targets with
# the same SDK. A supplied checkout must match the reviewed revision exactly.
export TRELLIS_ROOT="${TRELLIS_ROOT:-$("$repo_root/scripts/pinned-checkout.sh" gnustep-trellis "$repo_root/out/gnustep-trellis")}"
"$repo_root/scripts/pinned-checkout.sh" --verify gnustep-trellis "$TRELLIS_ROOT"
make -C "$TRELLIS_ROOT" clean hot_reload=no
make -C "$TRELLIS_ROOT" -j"${PD_BUILD_JOBS:-2}" hot_reload=no
python3 "$repo_root/scripts/trellis-package.py" receipt "$TRELLIS_ROOT" \
  --output "$TRELLIS_ROOT/obj/pd-build-receipt.json"

# Objects made against a different GNUstep installation are not reusable:
# make does not know that the toolchain/environment changed.
make -C "$repo_root" clean
make -C "$repo_root"
